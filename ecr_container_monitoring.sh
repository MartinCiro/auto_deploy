#!/bin/bash
DOCKER_PRUNE_DAYS=1

# --- Configuración para softcalfut ---
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Lista de servicios
declare -a SERVICES=("softcalfut_front" "softcalfut_back")

# Configuración de Docker Compose
DOCKER_COMPOSE_FILE="$HOME/git/personal/auto_deploy/proyecto_softcalfut/docker-compose.yml"

# Directorio de logs
LOG_DIR="$HOME/git/personal/auto_deploy/logs"
mkdir -p ${LOG_DIR}
LOG_FILE="${LOG_DIR}/ecr_monitor_$(date +%Y-%m-%d).log"
LOCK_FILE="${LOG_DIR}/ecr_monitor.lock"

# --- Funciones ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a ${LOG_FILE}
}

# Verificar si ya hay una ejecución en curso
if [ -f ${LOCK_FILE} ]; then
    log "Script ya en ejecución. Saliendo."
    exit 1
fi

touch ${LOCK_FILE}
trap "rm -f ${LOCK_FILE}" EXIT

# --- Validaciones iniciales ---
if [ ! -f "${DOCKER_COMPOSE_FILE}" ]; then
    log "ERROR: No se encuentra docker-compose.yml en ${DOCKER_COMPOSE_FILE}"
    exit 1
fi

# --- Autenticación en ECR ---
log "Autenticando en ECR..."
aws ecr get-login-password --region ${AWS_REGION} | \
docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com || {
    log "ERROR: Fallo en autenticación ECR"
    exit 1
}

# --- Iterar sobre servicios ---
for SERVICE in "${SERVICES[@]}"; do
    ECR_REPOSITORY_NAME="proyecto_softcalfut_${SERVICE}"
    IMAGE_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}"
    VERSION_FILE="$HOME/git/personal/auto_deploy/version_${SERVICE}.txt"
    CURRENT_VERSION=$(cat ${VERSION_FILE} 2>/dev/null || echo "${DOCKER_IMAGE_VERSION}" || echo "1.0.0")
    export VERSION="${CURRENT_VERSION}"

    # --- Obtener última imagen en ECR por versión específica ---

    ECR_DIGEST=$(aws ecr describe-images \
        --repository-name ${ECR_REPOSITORY_NAME} \
        --image-ids imageTag=${CURRENT_VERSION} \
        --region ${AWS_REGION} \
        --query 'imageDetails[0].imageDigest' \
        --output text 2>/dev/null)

    if [ -z "$ECR_DIGEST" ]; then
        ECR_DIGEST=$(aws ecr describe-images \
            --repository-name ${ECR_REPOSITORY_NAME} \
            --image-ids imageTag=latest \
            --region ${AWS_REGION} \
            --query 'imageDetails[0].imageDigest' \
            --output text 2>/dev/null)

        if [ -z "$ECR_DIGEST" ]; then
            log "ERROR: No se encontró imagen en ECR (ni versión ni latest) para ${SERVICE}"
            continue
        fi
    fi

    # --- Obtener imagen local ---
    log "Verificando imagen local..."
    LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE_NAME}:${CURRENT_VERSION} 2>/dev/null | cut -d'@' -f2)

    if [ -z "$LOCAL_DIGEST" ]; then
        LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE_NAME}:latest 2>/dev/null | cut -d'@' -f2)

        if [ -z "$LOCAL_DIGEST" ]; then
            log "WARNING: No se encontró imagen local, forzando pull para ${SERVICE}..."
            docker-compose -f "${DOCKER_COMPOSE_FILE}" pull "${SERVICE}"
            LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE_NAME}:latest 2>/dev/null | cut -d'@' -f2)
        fi
    fi

    # --- Comparación y actualización ---
    if [ "$ECR_DIGEST" != "$LOCAL_DIGEST" ]; then
        docker-compose -f "${DOCKER_COMPOSE_FILE}" stop "${SERVICE}" || true
        docker-compose -f "${DOCKER_COMPOSE_FILE}" rm -f "${SERVICE}" || true

        log "Limpiando recursos antiguos..."
        docker system prune -af --filter "until=${DOCKER_PRUNE_DAYS}d" || true

        log "Actualizando contenedor..."
        if ! docker-compose -f "${DOCKER_COMPOSE_FILE}" pull "${SERVICE}" --ignore-pull-failures; then
            log "WARNING: Fallo al pull con versión específica, intentando con latest..."
            IMAGE_TAG_ORIGINAL=$(grep -A1 "${SERVICE}:" "${DOCKER_COMPOSE_FILE}" | grep 'image:' | awk '{print $2}' | cut -d':' -f2)
            sed -i "/${SERVICE}:/,/image:/ s|image:.*|image: ${IMAGE_NAME}:latest|" "${DOCKER_COMPOSE_FILE}"
            docker-compose -f "${DOCKER_COMPOSE_FILE}" pull "${SERVICE}"
            sed -i "/${SERVICE}:/,/image:/ s|image:.*|image: ${IMAGE_NAME}:${IMAGE_TAG_ORIGINAL}|" "${DOCKER_COMPOSE_FILE}"
        fi

        docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d --no-deps "${SERVICE}" && \
        log "Contenedor ${SERVICE} actualizado correctamente" || \
        log "ERROR: Fallo al actualizar el contenedor ${SERVICE}"

        echo "$CURRENT_VERSION" > "$VERSION_FILE"

        log "Limpiando imágenes no utilizadas..."
        docker image prune -af --filter "until=${DOCKER_PRUNE_DAYS}d" || true
    else
        log "No hay cambios para ${SERVICE} (Digest: ${ECR_DIGEST})"
    fi
done

log "Monitoreo completado"
