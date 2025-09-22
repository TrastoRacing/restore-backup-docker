#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------
# Restauración de backups Docker Completo
# Debian 12 + Docker
# Autor: TrastoTech
#
# set -Eeuo pipefail es una instrucción de Bash que activa varias opciones para hacer el script más seguro y robusto
#
# Uso:
#   sudo bash restaurar_backup_docker.sh [--dry-run] [--stop] [--compose-up] [--resume-running] [--assume-yes]
# Recomendado:
#    sudo bash restaurar_backup_docker.sh --stop --resume-running --compose-up
#
# Flags:
#   --dry-run         : Simula todo (no escribe en volúmenes ni carga imágenes) no modifica el sistema.
#   --stop            : Para contenedores antes de restaurar (coherencia de datos).
#   --compose-up      : Lanza docker compose up -d en /data/compose al final (si hay archivos).
#   --resume-running  : Reanuda SOLO los contenedores que estaban corriendo antes de --stop.
#   --assume-yes      : Omite el prompt interactivo y asume 'si'.
# ---------------------------------------------

LOG_FILE="/var/log/docker_restore.log"
BACKUP_DIR="/var/backups"
FULL_PREFIX="docker_backup_completo_"
COMPOSE_RESTORE_DIR="/data/compose"

DRY_RUN=false
STOP_CONTAINERS=false
COMPOSE_UP=false
RESUME_RUNNING=false
ASSUME_YES=false

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

run() {
  if $DRY_RUN; then
    log "(dry-run) $*"
  else
    eval "$@"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { log "ERROR: Falta comando '$1'"; exit 1; }; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { log "ERROR: Ejecuta como root"; exit 1; }; }

trap 'log "ERROR en línea $LINENO. Abortando."' ERR

# --- Parseo de flags ---
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --stop) STOP_CONTAINERS=true ;;
    --compose-up) COMPOSE_UP=true ;;
    --resume-running) RESUME_RUNNING=true ;;
    --assume-yes) ASSUME_YES=true ;;
    *) log "Flag desconocida: $arg"; exit 1 ;;
  esac
done

# --- Requisitos mínimos ---
need_root
need_cmd bash
need_cmd tar
need_cmd gzip
need_cmd df
need_cmd awk
need_cmd find
need_cmd xargs
need_cmd stat
need_cmd docker
mkdir -p "$(dirname "$LOG_FILE")"
log "Inicio de restauración"

# --- Confirmación interactiva (timeout 30s) ---
if ! $ASSUME_YES; then
  echo -n "Estás a punto de restaurar un backup completo de Docker (SIN diferenciales). ¿Estás seguro? [si/no] (30s): "
  if read -r -t 30 answer; then
    ans_norm=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]' | sed 's/[íï]/i/g; s/^[[:space:]]*//; s/[[:space:]]*$//')
    if [[ "$ans_norm" != "si" ]]; then
      log "Operación cancelada por el usuario (respuesta: '${answer:-vacía}')."; exit 0
    fi
  else
    log "Sin respuesta en 30s; operación cancelada por timeout."; exit 0
  fi
fi

# --- Docker Root Dir ---
DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo '/var/lib/docker')"

# --- Utilidades de espacio ---
estimate_targz_bytes() {
  local f="$1"; local bytes
  bytes=$(gzip -l "$f" 2>/dev/null | awk 'NR==2{print $2}')
  if [[ -n "$bytes" && "$bytes" != "-" && "$bytes" != "4294967295" ]]; then
    echo "$bytes"; return
  fi
  bytes=$(tar -tvzf "$f" 2>/dev/null | awk 'BEGIN{s=0} {if ($3 ~ /^[0-9]+$/) s+=$3} END{print s+0}')
  echo "${bytes:-0}"
}
available_kb() { df -Pk "$1" | awk 'NR==2{print $4}'; }
check_space_or_exit() {
  local target_path="$1"; local required_kb="$2"; local what="$3"
  local margin_kb=$(( (required_kb * 20 + 99) / 100 ))
  local total_kb=$(( required_kb + margin_kb ))
  local free_kb; free_kb=$(available_kb "$target_path")
  if [[ -z "$free_kb" ]]; then
    log "ADVERTENCIA: no se pudo determinar espacio libre en $target_path; continúo."; return 0
  fi
  if (( free_kb < total_kb )); then
    log "ERROR: espacio insuficiente para $what en $target_path. Necesario ~${total_kb}KB, libre ${free_kb}KB."; exit 1
  fi
  log "Espacio OK para $what en $target_path (necesario ~${total_kb}KB, libre ${free_kb}KB)."
}

# --- Fallback para docker compose ---
COMPOSE_IMPL="none"
if docker compose version >/dev/null 2>&1; then
  COMPOSE_IMPL="plugin"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_IMPL="legacy"
fi
compose_up_file() {
  local file="$1"; local dir; dir="$(dirname "$file")"
  if $DRY_RUN; then
    log "(dry-run) docker compose up -d en '$dir' (archivo $(basename "$file"))"; return 0
  fi
  case "$COMPOSE_IMPL" in
    plugin) (cd "$dir" && docker compose -f "$file" up -d) ;;
    legacy) (cd "$dir" && docker-compose -f "$file" up -d) ;;
    *) log "ADVERTENCIA: No hay docker compose ni docker-compose; se omite --compose-up." ;;
  esac
}

# --- Localizar último backup completo ---
shopt -s nullglob
mapfile -t FULL_DIRS < <(printf '%s\0' "$BACKUP_DIR/$FULL_PREFIX"* | xargs -0 -n1 basename | sort -V)
if (( ${#FULL_DIRS[@]} == 0 )); then
  log "No se encontró backup completo en $BACKUP_DIR/$FULL_PREFIX*"; exit 1
fi
LAST_FULL_BASENAME="${FULL_DIRS[-1]}"
LAST_FULL="$BACKUP_DIR/$LAST_FULL_BASENAME"
log "Backup completo seleccionado: $LAST_FULL"

# --- PREVIEW/RESUMEN DE ESPACIO (solo completo) ---
log "Preflight: estimando espacio requerido…"
required_kb_docker=0
required_kb_compose=0

# a) Volúmenes del completo 
for f in "$LAST_FULL"/*.tar.gz; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  case "$base" in
    portainer_data_*.tar.gz|docker_compose_files_*.tar.gz) continue ;;
  esac
  bytes=$(estimate_targz_bytes "$f")
  required_kb_docker=$(( required_kb_docker + ( (bytes + 1023) / 1024 ) ))
done

# b) Imágenes del completo
if [[ -d "$LAST_FULL/images" ]]; then
  for img in "$LAST_FULL/images/"*.tar; do
    [[ -f "$img" ]] || continue
    size_bytes=$(stat -c%s "$img" 2>/dev/null || echo 0)
    required_kb_docker=$(( required_kb_docker + ( (size_bytes + 1023) / 1024 ) ))
  done
fi

# c) Portainer 
PORTAINER_TAR=$(ls "$LAST_FULL"/portainer_data_*.tar.gz 2>/dev/null | head -n1 || true)
if [[ -n "${PORTAINER_TAR:-}" ]]; then
  bytes=$(estimate_targz_bytes "$PORTAINER_TAR")
  required_kb_docker=$(( required_kb_docker + ( (bytes + 1023) / 1024 ) ))
fi

# d) Paquete Docker Compose 
COMPOSE_TAR=$(ls "$LAST_FULL"/docker_compose_files_*.tar.gz 2>/dev/null | head -n1 || true)
if [[ -n "${COMPOSE_TAR:-}" ]]; then
  bytes=$(estimate_targz_bytes "$COMPOSE_TAR")
  required_kb_compose=$(( required_kb_compose + ( (bytes + 1023) / 1024 ) ))
fi

log "Espacio requerido aproximado:"
log "  - Docker Root ($DOCKER_ROOT): ~${required_kb_docker} KB (+20% margen en verificación efectiva)"
if (( required_kb_compose > 0 )); then
  log "  - /data/compose: ~${required_kb_compose} KB (+20% margen en verificación efectiva)"
fi

check_space_or_exit "$DOCKER_ROOT" "$required_kb_docker" "restauración en Docker Root"
if (( required_kb_compose > 0 )); then
  mkdir -p "$COMPOSE_RESTORE_DIR"
  check_space_or_exit "$COMPOSE_RESTORE_DIR" "$required_kb_compose" "extracción de Docker Compose"
fi

# --- Parar contenedores opcionalmente ---
PREV_RUNNING_IDS=""
if $STOP_CONTAINERS; then
  PREV_RUNNING_IDS=$(docker ps -q)
  if [[ -n "$PREV_RUNNING_IDS" ]]; then
    run "docker stop $PREV_RUNNING_IDS"; STOPPED=true
  else
    STOPPED=false
  fi
else
  STOPPED=false
fi

# --- Restaurar volúmenes del completo ---
restore_tar_into_volume() {
  local tarfile="$1"
  local base; base="$(basename "$tarfile")"
  case "$base" in
    portainer_data_*.tar.gz|docker_compose_files_*.tar.gz) return 0 ;;
  esac
  local name="${base%.tar.gz}"; name="${name%_*}"
  [[ -n "$name" ]] || { log "Saltando: no pude derivar nombre de $tarfile"; return; }

  local bytes req_kb
  bytes=$(estimate_targz_bytes "$tarfile"); req_kb=$(( (bytes + 1023) / 1024 ))
  check_space_or_exit "$DOCKER_ROOT" "$req_kb" "restaurar volumen '$name' desde $(basename "$tarfile")"

  run "docker volume create \"$name\" >/dev/null"
  if $DRY_RUN; then
    log "(dry-run) Restauraría $tarfile en volumen $name"
  else
    docker run --rm -v "$name":/data -v "$(dirname "$tarfile")":/backup alpine:3.20 \
      sh -c "tar -tzf \"/backup/$(basename "$tarfile")\" >/dev/null && \
             tar -xzf \"/backup/$(basename "$tarfile")\" -C /data"
  fi
  log "Volumen restaurado: $name"
}

log "Restaurando volúmenes del completo…"
for f in "$LAST_FULL"/*.tar.gz; do
  [[ -f "$f" ]] || continue
  restore_tar_into_volume "$f"
done

# --- Restaurar imágenes del completo ---
if [[ -d "$LAST_FULL/images" ]]; then
  log "Restaurando imágenes…"
  for img in "$LAST_FULL/images/"*.tar; do
    [[ -f "$img" ]] || continue
    size_bytes=$(stat -c%s "$img" 2>/dev/null || echo 0)
    req_kb=$(( (size_bytes + 1023) / 1024 ))
    check_space_or_exit "$DOCKER_ROOT" "$req_kb" "cargar imagen $(basename "$img")"
    run "docker load -i \"$img\""
    log "Imagen cargada: $(basename "$img")"
  done
fi

# --- Restaurar Portainer ---
if [[ -n "${PORTAINER_TAR:-}" ]]; then
  bytes=$(estimate_targz_bytes "$PORTAINER_TAR"); req_kb=$(( (bytes + 1023) / 1024 ))
  check_space_or_exit "$DOCKER_ROOT" "$req_kb" "restaurar 'portainer_data'"

  run "docker volume create portainer_data >/dev/null"
  if $DRY_RUN; then
    log "(dry-run) Restauraría $PORTAINER_TAR en volumen portainer_data"
  else
    docker run --rm -v portainer_data:/data -v "$(dirname "$PORTAINER_TAR")":/backup alpine:3.20 \
      sh -c "tar -tzf \"/backup/$(basename \"$PORTAINER_TAR\")\" >/dev/null && \
             tar -xzf \"/backup/$(basename \"$PORTAINER_TAR\")\" -C /data"
  fi
  log "Volumen 'portainer_data' restaurado."
else
  log "No se encontró backup de portainer_data en el completo."
fi

# --- Restaurar Docker Compose ---
if [[ -n "${COMPOSE_TAR:-}" ]]; then
  run "mkdir -p \"$COMPOSE_RESTORE_DIR\""
  bytes=$(estimate_targz_bytes "$COMPOSE_TAR"); req_kb=$(( (bytes + 1023) / 1024 ))
  check_space_or_exit "$COMPOSE_RESTORE_DIR" "$req_kb" "extraer Docker Compose"

  run "tar -xzf \"$COMPOSE_TAR\" -C \"$COMPOSE_RESTORE_DIR\""
  log "Archivos Docker Compose restaurados en $COMPOSE_RESTORE_DIR"
else
  log "No se encontró paquete de Docker Compose en el completo."
fi

# --- Reanudar contenedores previos y/o levantar stacks restaurados ---
if $RESUME_RUNNING && $STOP_CONTAINERS && [[ -n "${PREV_RUNNING_IDS:-}" ]]; then
  run "docker start $PREV_RUNNING_IDS"; log "Reanudados contenedores que estaban en ejecución antes de la restauración."
fi

if $COMPOSE_UP && [[ -d "$COMPOSE_RESTORE_DIR" ]]; then
  while IFS= read -r -d '' file; do
    log "docker compose up -d en $(dirname "$file")"; compose_up_file "$file"
  done < <(find "$COMPOSE_RESTORE_DIR" -type f \( -name 'docker-compose.yml' -o -name 'compose.yml' \) -print0)
fi

log "Restauración completada."
