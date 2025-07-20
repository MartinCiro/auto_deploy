#!/bin/bash

# --- Configuración para softcalfut ---
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPOSITORY_NAME="softcalfut-front"
IMAGE_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}"
#907020542361.dkr.ecr.us-east-1.amazonaws.com/softcalfutFront/
# Configuración de Docker Compose
DOCKER_COMPOSE_FILE="/home/ciro_admin/git/personal/auto_deploy/docker-compose.yml"  # Ajusta esta ruta
DOCKER_COMPOSE_SERVICE_NAME="app"  # Nombre del servicio en tu compose

# Directorio de logs
LOG_DIR="/home/ciro_admin/git/personal/auto_deploy/softcalfutFront/logs"
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

# --- Obtener última imagen en ECR ---
log "Buscando última imagen en ECR..."
ECR_DIGEST=$(aws ecr describe-images \
    --repository-name ${ECR_REPOSITORY_NAME} \
    --image-ids imageTag=latest \
    --region ${AWS_REGION} \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null)

    
if [ -z "$ECR_DIGEST" ]; then
    log "WARNING: No se encontró imagen 'latest' en ECR"
    exit 0
fi

# --- Obtener imagen local ---
log "Verificando imagen local..."
LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE_NAME}:latest 2>/dev/null | cut -d'@' -f2)

if [ -z "$LOCAL_DIGEST" ]; then
    log "WARNING: No se encontró imagen local, forzando pull..."
    docker-compose -f "${DOCKER_COMPOSE_FILE}" pull "${DOCKER_COMPOSE_SERVICE_NAME}"
    LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE_NAME}:latest 2>/dev/null | cut -d'@' -f2)
fi

# --- Comparación y actualización ---
if [ "$ECR_DIGEST" != "$LOCAL_DIGEST" ]; then
    log "NUEVA VERSIÓN DETECTADA:"
    log "  ECR:    ${ECR_DIGEST}"
    log "  Local:  ${LOCAL_DIGEST}"
    
    log "Actualizando contenedor..."
    docker-compose -f "${DOCKER_COMPOSE_FILE}" pull "${DOCKER_COMPOSE_SERVICE_NAME}" && \
    docker-compose -f "${DOCKER_COMPOSE_FILE}" up -d --no-deps "${DOCKER_COMPOSE_SERVICE_NAME}" && \
    log "Contenedor actualizado correctamente" || \
    log "ERROR: Fallo al actualizar el contenedor"
else
    log "No hay cambios (Digest: ${ECR_DIGEST})"
fi

log "Monitoreo completado"