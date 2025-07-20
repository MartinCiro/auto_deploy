#!/bin/bash

# --- Configuration ---
DIR_ROOT="/home/ciro_admin/git/personal/auto_deploy"
REPO_DIR="${DIR_ROOT}/softcalfutFront"
REPO_GIT="github.com/MartinCiro/softcalfutFront"
REPO_URL="git@${REPO_GIT}"


# Docker and AWS Configuration
ID="softcalfut-front"
REGION="us-east-1"
USER=$(aws sts get-caller-identity --query Account --output text)
DOCKER="docker"
ECR_URL="${USER}.dkr.ecr.${REGION}.amazonaws.com"
DOCKER_IMAGE_NAME="${ECR_URL}/${ID}"
DOCKERFILE_PATH="$REPO_DIR/dockerfile"

# Version and Logging
VERSION_FILE="${DIR_ROOT}/version_${ID}.txt"
LOG_FILE="${DIR_ROOT}/var/log/git_watch_${ID}.log"
TAG="latest"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# --- Functions ---

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "1.0.0"
    fi
}

increment_version() {
    local current_version=$1
    IFS='.' read -r major minor patch <<< "$current_version"
    echo "${major}.${minor}.$((patch + 1))"
}

check_ecr_repository() {
    log_message "Checking ECR repository existence..."
    if ! aws ecr describe-repositories --repository-names "$ID" --region "$REGION" >/dev/null 2>&1; then
        log_message "ECR repository not found, creating..."
        aws ecr create-repository \
            --repository-name "$ID" \
            --region "$REGION" \
            --image-scanning-configuration scanOnPush=true \
            --image-tag-mutability MUTABLE || {
                log_message "ERROR: Failed to create ECR repository"
                return 1
            }
        log_message "ECR repository created successfully"
    fi
}

check_repo() {
    log_message "Checking repository at $REPO_DIR..."
    
    # Verificar y clonar repositorio si no existe
    if [ ! -d "$REPO_DIR/.git" ]; then
        log_message "Cloning repository for the first time..."
        git clone "$REPO_URL" "$REPO_DIR" || {
            log_message "ERROR: Failed to clone repository"
            return 1
        }
        # Retornar éxito para forzar build inicial
        return 0
    fi

    cd "$REPO_DIR" || {
        log_message "ERROR: Failed to enter repository directory"
        return 1
    }

    # Configurar safe.directory para evitar problemas de permisos
    git config --global --add safe.directory "$REPO_DIR"

    # Obtener commit actual ANTES del pull
    local current_commit=$(git rev-parse HEAD)
    local current_branch=$(git rev-parse --abbrev-ref HEAD)

    log_message "Pulling latest changes from $current_branch branch..."
    git fetch origin
    git pull origin "$current_branch" || {
        log_message "WARNING: git pull failed"
        return 1
    }

    # Obtener commit DESPUÉS del pull
    local new_commit=$(git rev-parse HEAD)

    # Forzar build si es la primera vez o si hay cambios
    if [ "$current_commit" != "$new_commit" ] || [ ! -f "$VERSION_FILE" ]; then
        log_message "Changes detected in repository (or initial build)"
        return 0
    else
        log_message "No changes detected in repository."
        return 1
    fi
}

build_and_push_docker() {
    # Obtener y validar configuración
    local new_version=$(increment_version $(get_current_version))
    local image_version="${DOCKER_IMAGE_NAME}:${new_version}"
    local image_latest="${DOCKER_IMAGE_NAME}:latest"

    log_message "Iniciando construcción Docker para versión $new_version..."
    
    # Validar Dockerfile
    if [ ! -f "$DOCKERFILE_PATH" ]; then
        log_message "ERROR: Dockerfile no encontrado en $DOCKERFILE_PATH"
        return 1
    fi

    # Limpieza de imágenes antiguas (conservando espacio en disco)
    log_message "Limpiando imágenes antiguas..."
    $DOCKER system prune -af --filter "until=24h" || {
        log_message "WARNING: No se pudo limpiar completamente"
    }

    # Construir imagen con versión específica
    log_message "Construyendo imagen Docker..."
    if ! $DOCKER build \
        -t "$image_version" \
        -t "$image_latest" \
        -f "$DOCKERFILE_PATH" \
        --build-arg VERSION="$new_version" \
        .; then
        log_message "ERROR: Falló la construcción de Docker"
        return 1
    fi

    # Autenticación con ECR (con reintento)
    log_message "Autenticando con ECR..."
    if ! aws ecr get-login-password --region "$REGION" | \
        $DOCKER login --username AWS --password-stdin "$ECR_URL"; then
        log_message "ERROR: Falló autenticación con ECR. Verifica:"
        log_message "1. AWS CLI configurado (aws configure)"
        log_message "2. Permisos IAM para ECR"
        log_message "3. Red/Conectividad"
        return 1
    fi

    # Push de imágenes (con manejo de errores robusto)
    log_message "Subiendo imágenes a ECR..."
    if ! $DOCKER push "$image_version"; then
        log_message "ERROR: Falló push de versión $new_version"
        return 1
    fi

    if ! $DOCKER push "$image_latest"; then
        log_message "ERROR: Falló push de imagen latest"
        return 1
    fi

    # Actualizar versión y registrar éxito
    echo "$new_version" > "$VERSION_FILE"
    log_message "✅ Despliegue exitoso! Versión $new_version en ECR"
    
    # Opcional: Notificar a sistemas externos
    # notify_slack "Nueva versión $new_version desplegada"
    
    return 0
}

notify_production() {
    # Optional: Add notification to production server
    log_message "Deployment complete, you may now update production"
    # Example SSH command to trigger update:
    # ssh user@production-server "/path/to/ecr_container_monitoring.sh"
}

# --- Main Execution ---

log_message "=== Starting deployment process ==="

# Verify ECR repository exists
check_ecr_repository || exit 1

# Check for repository changes
if check_repo; then
    log_message "Changes detected, starting build process..."
    
    if build_and_push_docker; then
        log_message "Build and deployment successful!"
        notify_production
    else
        log_message "ERROR: Build and deployment failed"
        exit 1
    fi
else
    log_message "No changes detected in repository"
fi

log_message "=== Process completed ==="