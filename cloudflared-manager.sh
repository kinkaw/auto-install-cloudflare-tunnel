#!/usr/bin/env bash

# Cloudflare Tunnel Manager
# A production-minded helper for Docker-based cloudflared installations.

set -uo pipefail
IFS=$'\n\t'

APP_NAME="Cloudflare Tunnel Manager"
APP_VERSION="1.0.0"
CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
SCRIPT_NAME="$(basename "$0")"
BASE_DIR="${CFM_HOME:-${HOME}/cloudflared-manager}"
TUNNELS_DIR="${BASE_DIR}/tunnels"
BACKUP_DIR="${BASE_DIR}/backups"
NGINX_DIR="${BASE_DIR}/nginx-templates"
LOG_DIR="${BASE_DIR}/logs"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
RUN_UID="${CFM_UID:-$(id -u)}"
RUN_GID="${CFM_GID:-$(id -g)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

if [[ ! -t 1 || "${NO_COLOR:-}" == "1" ]]; then
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  BOLD=''
  DIM=''
  NC=''
fi

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_DIR}/manager.log" 2>/dev/null || true
}

print_color() {
  local color="$1"
  shift
  printf '%b%s%b\n' "$color" "$*" "$NC"
}

info() { print_color "$CYAN" "INFO: $*"; log "INFO: $*"; }
success() { print_color "$GREEN" "OK: $*"; log "OK: $*"; }
warn() { print_color "$YELLOW" "WARN: $*"; log "WARN: $*"; }
error() { print_color "$RED" "ERROR: $*"; log "ERROR: $*"; }

die() {
  error "$*"
  exit 1
}

pause() {
  printf '\n'
  read -r -p "Press Enter to continue..." _
}

header() {
  clear 2>/dev/null || true
  printf '%b\n' "${BOLD}${BLUE}"
  printf '  ____ _                 _  __ _                 _____                      _ \n'
  printf ' / ___| | ___  _   _  __| |/ _| | __ _ _ __ ___|_   _|   _ _ __  _ __   ___| |\n'
  printf '| |   | |/ _ \| | | |/ _` | |_| |/ _` | `__/ _ \ | || | | | `_ \| `_ \ / _ \ |\n'
  printf '| |___| | (_) | |_| | (_| |  _| | (_| | | |  __/ | || |_| | | | | | | |  __/ |\n'
  printf ' \____|_|\___/ \__,_|\__,_|_| |_|\__,_|_|  \___| |_| \__,_|_| |_|_| |_|\___|_|\n'
  printf '%b' "$NC"
  printf '%b%s%b\n' "$BOLD" "  ${APP_NAME} v${APP_VERSION}" "$NC"
  printf '%b%s%b\n\n' "$DIM" "  Workspace: ${BASE_DIR}" "$NC"
}

usage() {
  cat <<EOF
${APP_NAME} v${APP_VERSION}

Usage:
  ${SCRIPT_NAME} [command]

Commands:
  menu                 Open the interactive menu (default)
  install-docker       Install Docker and Compose plugin
  login                Run Cloudflare browser login for a tunnel workspace
  create-tunnel        Create a Cloudflare tunnel
  list                 List local and optional remote tunnels
  dns                  Create DNS routes for a tunnel
  config               Generate config.yaml for a tunnel
  compose              Generate docker-compose.yml for all configured tunnels
  start                Start all tunnel containers
  stop                 Stop all tunnel containers
  restart              Restart all tunnel containers
  logs                 View tunnel logs
  dashboard            Show local health dashboard
  backup               Create a backup archive
  restore              Restore from a backup archive
  nginx                Generate an Nginx reverse proxy template
  validate             Validate local tunnel files and ingress configs
  help                 Show this help

Environment:
  CFM_HOME             Workspace path. Default: ${HOME}/cloudflared-manager
  CFM_UID              Container runtime UID. Default: current user id
  CFM_GID              Container runtime GID. Default: current group id
  CLOUDFLARED_IMAGE    Docker image. Default: cloudflare/cloudflared:latest
  NO_COLOR=1           Disable colored output

Examples:
  CFM_HOME=/home/admin/server/cloudflared ./${SCRIPT_NAME}
  ./${SCRIPT_NAME} install-docker
  ./${SCRIPT_NAME} compose
  ./${SCRIPT_NAME} start
EOF
}

init_layout() {
  mkdir -p "$BASE_DIR" "$TUNNELS_DIR" "$BACKUP_DIR" "$NGINX_DIR" "$LOG_DIR"
  chmod 700 "$TUNNELS_DIR" 2>/dev/null || true
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

sudo_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_docker() {
  command_exists docker || die "Docker is not installed. Use the Install Docker menu first."
  docker info >/dev/null 2>&1 || die "Docker is not running or your user cannot access it."
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
  elif command_exists docker-compose; then
    printf 'docker-compose'
  else
    return 1
  fi
}

run_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command_exists docker-compose; then
    docker-compose "$@"
  else
    return 127
  fi
}

require_compose() {
  require_docker
  compose_cmd >/dev/null || die "Docker Compose is not installed. Install docker compose plugin or docker-compose."
}

pull_cloudflared_image() {
  require_docker
  info "Pulling ${CLOUDFLARED_IMAGE}..."
  docker pull "$CLOUDFLARED_IMAGE"
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

docker_tty_args() {
  if is_interactive; then
    printf -- '-it'
  else
    printf -- '-i'
  fi
}

sanitize_slug() {
  local value="$1"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "$value"
}

service_name_for_slug() {
  local slug="$1"
  slug="$(sanitize_slug "$slug")"
  slug="$(printf '%s' "$slug" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf 'cf_%s' "$slug"
}

container_name_for_slug() {
  local slug="$1"
  slug="$(sanitize_slug "$slug")"
  slug="$(printf '%s' "$slug" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf 'cloudflared_%s' "$slug"
}

validate_slug() {
  local slug="$1"
  [[ -n "$slug" ]] || return 1
  [[ "$slug" =~ ^[a-z0-9][a-z0-9._-]*$ ]]
}

validate_hostname() {
  local host="$1"
  [[ "$host" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_service_url() {
  local service="$1"
  [[ "$service" =~ ^https?://[^[:space:]]+$ ]] && return 0
  [[ "$service" =~ ^tcp://[^[:space:]]+$ ]] && return 0
  [[ "$service" =~ ^ssh://[^[:space:]]+$ ]] && return 0
  [[ "$service" =~ ^unix:[^[:space:]]+$ ]] && return 0
  [[ "$service" =~ ^http_status:[0-9]{3}$ ]] && return 0
  [[ "$service" == "hello_world" ]] && return 0
  return 1
}

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s' "$value"
  fi
}

confirm() {
  local label="$1"
  local answer
  read -r -p "${label} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$|^[Yy][Ee][Ss]$ ]]
}

confirm_danger() {
  local label="$1"
  local token="$2"
  local answer
  warn "$label"
  read -r -p "Type '${token}' to continue: " answer
  [[ "$answer" == "$token" ]]
}

tunnel_dir() {
  printf '%s/%s' "$TUNNELS_DIR" "$1"
}

ensure_tunnel_dir() {
  local slug="$1"
  validate_slug "$slug" || die "Invalid tunnel workspace name: ${slug}"
  mkdir -p "$(tunnel_dir "$slug")"
  chmod 700 "$(tunnel_dir "$slug")" 2>/dev/null || true
}

list_local_slugs() {
  local dir
  [[ -d "$TUNNELS_DIR" ]] || return 0
  for dir in "$TUNNELS_DIR"/*; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
  done
}

select_tunnel_slug() {
  local slugs=()
  local index=1
  local choice
  local slug

  while IFS= read -r slug; do
    slugs+=("$slug")
  done < <(list_local_slugs)

  if [[ "${#slugs[@]}" -eq 0 ]]; then
    warn "No local tunnel workspaces found."
    return 1
  fi

  printf '\n'
  for slug in "${slugs[@]}"; do
    printf '  %2d) %s\n' "$index" "$slug"
    index=$((index + 1))
  done
  printf '\n'
  read -r -p "Select tunnel workspace: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#slugs[@]} )); then
    printf '%s' "${slugs[$((choice - 1))]}"
    return 0
  fi
  error "Invalid selection."
  return 1
}

find_credential_file() {
  local slug="$1"
  local dir
  local file
  dir="$(tunnel_dir "$slug")"
  for file in "$dir"/*.json; do
    [[ -f "$file" ]] || continue
    basename "$file"
    return 0
  done
  return 1
}

get_tunnel_id() {
  local slug="$1"
  local cred
  local file
  cred="$(find_credential_file "$slug" 2>/dev/null || true)"
  [[ -n "$cred" ]] || return 1
  file="$(tunnel_dir "$slug")/${cred}"
  sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

meta_file() {
  printf '%s/.tunnel-meta' "$(tunnel_dir "$1")"
}

get_tunnel_name() {
  local slug="$1"
  local file
  file="$(meta_file "$slug")"
  if [[ -f "$file" ]]; then
    sed -n 's/^TUNNEL_NAME=//p' "$file" | head -n 1
  else
    printf '%s-tunnel' "$slug"
  fi
}

write_tunnel_meta() {
  local slug="$1"
  local name="$2"
  local id="$3"
  cat > "$(meta_file "$slug")" <<EOF
TUNNEL_NAME=${name}
TUNNEL_ID=${id}
UPDATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
  chmod 600 "$(meta_file "$slug")" 2>/dev/null || true
}

run_cloudflared() {
  local slug="$1"
  shift
  local dir
  local tty_args
  dir="$(tunnel_dir "$slug")"
  [[ -d "$dir" ]] || die "Tunnel workspace does not exist: ${slug}"
  require_docker
  tty_args="$(docker_tty_args)"
  # shellcheck disable=SC2086
  docker run --rm ${tty_args} \
    --user "${RUN_UID}:${RUN_GID}" \
    -v "${dir}:/home/nonroot/.cloudflared" \
    "$CLOUDFLARED_IMAGE" "$@"
}

install_docker() {
  header
  info "Installing Docker is optional. Existing Docker installations will be kept."

  if command_exists docker && docker info >/dev/null 2>&1; then
    success "Docker is already installed and running."
    docker --version || true
    if compose_cmd >/dev/null; then
      run_compose version || true
    fi
    return 0
  fi

  if ! confirm "Install Docker Engine and Docker Compose plugin now?"; then
    warn "Docker installation skipped."
    return 0
  fi

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  else
    die "Cannot detect operating system."
  fi

  case "${ID:-}" in
    ubuntu|debian)
      sudo_cmd apt-get update
      sudo_cmd apt-get install -y ca-certificates curl gnupg lsb-release
      sudo_cmd install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | sudo_cmd gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo_cmd chmod a+r /etc/apt/keyrings/docker.gpg
      local codename
      codename="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || true)}"
      [[ -n "$codename" ]] || die "Cannot detect distribution codename."
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$ID" "$codename" | sudo_cmd tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo_cmd apt-get update
      sudo_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *)
      warn "Automatic Docker installation is supported for Debian/Ubuntu only."
      warn "Install Docker manually, then run this script again."
      return 1
      ;;
  esac

  sudo_cmd systemctl enable --now docker || true
  if [[ "${EUID}" -ne 0 ]] && command_exists usermod; then
    if confirm "Add current user '${USER}' to the docker group? You must log out and back in after this."; then
      sudo_cmd usermod -aG docker "$USER"
      warn "Group membership changed. Log out and back in if Docker permission is denied."
    fi
  fi

  success "Docker installation completed."
}

cloudflare_login() {
  header
  pull_cloudflared_image

  local input
  local slug
  input="$(prompt "Tunnel workspace name, for example devth or wanyud")"
  slug="$(sanitize_slug "$input")"
  validate_slug "$slug" || die "Invalid workspace name."
  ensure_tunnel_dir "$slug"

  info "A browser login URL will be displayed. Complete the login in Cloudflare."
  info "Credentials will be stored in $(tunnel_dir "$slug")."
  run_cloudflared "$slug" tunnel login
  success "Cloudflare login completed for workspace '${slug}'."
}

create_tunnel() {
  header
  pull_cloudflared_image

  local input
  local slug
  local tunnel_name
  local tunnel_id

  input="$(prompt "Tunnel workspace name, for example devth or wanyud")"
  slug="$(sanitize_slug "$input")"
  validate_slug "$slug" || die "Invalid workspace name."
  ensure_tunnel_dir "$slug"

  if [[ ! -f "$(tunnel_dir "$slug")/cert.pem" ]]; then
    warn "No cert.pem found in this workspace."
    if confirm "Run Cloudflare login first?"; then
      run_cloudflared "$slug" tunnel login
    else
      die "Cloudflare login is required before creating a tunnel."
    fi
  fi

  tunnel_name="$(prompt "Cloudflare tunnel name" "${slug}-tunnel")"
  [[ -n "$tunnel_name" ]] || die "Tunnel name is required."

  info "Creating Cloudflare tunnel '${tunnel_name}'..."
  run_cloudflared "$slug" tunnel create "$tunnel_name"

  tunnel_id="$(get_tunnel_id "$slug" || true)"
  [[ -n "$tunnel_id" ]] || die "Tunnel was created, but no credential JSON was found."
  write_tunnel_meta "$slug" "$tunnel_name" "$tunnel_id"
  success "Tunnel '${tunnel_name}' created with id ${tunnel_id}."

  if confirm "Generate config.yaml now?"; then
    generate_config_for_slug "$slug"
  fi
  if confirm "Regenerate docker-compose.yml now?"; then
    generate_compose
  fi
}

list_tunnels() {
  header
  local slug
  local tunnel_id
  local tunnel_name
  local config_state
  local cred_state

  printf '%bLocal tunnel workspaces%b\n' "$BOLD" "$NC"
  printf '%-22s %-38s %-28s %-10s %-10s\n' "WORKSPACE" "TUNNEL_ID" "TUNNEL_NAME" "CONFIG" "CREDENTIAL"
  printf '%-22s %-38s %-28s %-10s %-10s\n' "---------" "---------" "-----------" "------" "----------"
  while IFS= read -r slug; do
    tunnel_id="$(get_tunnel_id "$slug" 2>/dev/null || true)"
    tunnel_name="$(get_tunnel_name "$slug")"
    [[ -f "$(tunnel_dir "$slug")/config.yaml" ]] && config_state="yes" || config_state="no"
    [[ -n "$(find_credential_file "$slug" 2>/dev/null || true)" ]] && cred_state="yes" || cred_state="no"
    printf '%-22s %-38s %-28s %-10s %-10s\n' "$slug" "${tunnel_id:-unknown}" "${tunnel_name:-unknown}" "$config_state" "$cred_state"
  done < <(list_local_slugs)

  printf '\n'
  if confirm "List remote Cloudflare tunnels using one local workspace certificate?"; then
    slug="$(select_tunnel_slug)" || return 1
    run_cloudflared "$slug" tunnel list
  fi
}

delete_tunnel() {
  header
  local slug
  local tunnel_name
  local service

  slug="$(select_tunnel_slug)" || return 1
  tunnel_name="$(prompt "Cloudflare tunnel name" "$(get_tunnel_name "$slug")")"
  service="$(service_name_for_slug "$slug")"

  warn "Selected workspace: ${slug}"
  warn "Cloudflare tunnel name: ${tunnel_name}"

  if [[ -f "$COMPOSE_FILE" ]] && command_exists docker; then
    if confirm "Stop compose service '${service}' before deletion?"; then
      if require_compose; then
        run_compose -f "$COMPOSE_FILE" stop "$service" || true
      fi
    fi
  fi

  if confirm "Delete the remote Cloudflare tunnel?"; then
    confirm_danger "Remote tunnel deletion cannot be undone." "delete ${tunnel_name}" || die "Deletion cancelled."
    run_cloudflared "$slug" tunnel delete -f "$tunnel_name"
    success "Remote tunnel deleted."
  fi

  if confirm "Delete the local workspace folder?"; then
    confirm_danger "Local credentials and config will be removed." "delete ${slug}" || die "Local deletion cancelled."
    rm -rf "$(tunnel_dir "$slug")"
    success "Local workspace deleted."
    if confirm "Regenerate docker-compose.yml now?"; then
      generate_compose
    fi
  fi
}

split_hosts() {
  local raw="$1"
  printf '%s' "$raw" | tr ',;' '  ' | xargs -n1
}

create_dns_routes() {
  header
  local slug
  local tunnel_name
  local raw_hosts
  local host
  local failed=0
  local tunnel_id

  slug="$(select_tunnel_slug)" || return 1
  tunnel_name="$(prompt "Cloudflare tunnel name" "$(get_tunnel_name "$slug")")"
  [[ -n "$tunnel_name" ]] || die "Cannot determine tunnel name."
  tunnel_id="$(get_tunnel_id "$slug" 2>/dev/null || true)"
  [[ -n "$tunnel_id" ]] && write_tunnel_meta "$slug" "$tunnel_name" "$tunnel_id"

  raw_hosts="$(prompt "Hostnames, separated by spaces or commas")"
  [[ -n "$raw_hosts" ]] || die "At least one hostname is required."

  while IFS= read -r host; do
    [[ -n "$host" ]] || continue
    if ! validate_hostname "$host"; then
      error "Invalid hostname: ${host}"
      failed=1
      continue
    fi
    info "Creating DNS route ${host} -> ${tunnel_name}"
    if run_cloudflared "$slug" tunnel route dns "$tunnel_name" "$host"; then
      success "DNS route created for ${host}."
    else
      error "Failed to create DNS route for ${host}."
      failed=1
    fi
  done < <(split_hosts "$raw_hosts")

  [[ "$failed" -eq 0 ]]
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp "$file" "${file}.bak.$(date '+%Y%m%d%H%M%S')"
  fi
}

generate_config_for_slug() {
  local slug="$1"
  local dir
  local tunnel_id
  local cred
  local config
  local default_service
  local hostname
  local service
  local entries=()

  dir="$(tunnel_dir "$slug")"
  [[ -d "$dir" ]] || die "Workspace does not exist: ${slug}"
  tunnel_id="$(get_tunnel_id "$slug" || true)"
  [[ -n "$tunnel_id" ]] || die "No tunnel credential JSON found in ${dir}."
  cred="$(find_credential_file "$slug")"
  default_service="$(prompt "Default origin service" "http://host.docker.internal:80")"
  validate_service_url "$default_service" || die "Invalid service URL: ${default_service}"

  info "Enter one hostname per line. Leave hostname empty to finish."
  while true; do
    hostname="$(prompt "Hostname")"
    [[ -n "$hostname" ]] || break
    if ! validate_hostname "$hostname"; then
      error "Invalid hostname: ${hostname}"
      continue
    fi
    service="$(prompt "Service for ${hostname}" "$default_service")"
    if ! validate_service_url "$service"; then
      error "Invalid service URL: ${service}"
      continue
    fi
    entries+=("${hostname}|${service}")
  done

  [[ "${#entries[@]}" -gt 0 ]] || die "At least one ingress hostname is required."

  config="${dir}/config.yaml"
  backup_file_if_exists "$config"

  {
    printf 'tunnel: %s\n' "$tunnel_id"
    printf 'credentials-file: /home/nonroot/.cloudflared/%s\n' "$cred"
    printf '\n'
    printf 'ingress:\n'
    local entry
    for entry in "${entries[@]}"; do
      printf '  - hostname: %s\n' "${entry%%|*}"
      printf '    service: %s\n' "${entry#*|}"
    done
    printf '  - service: http_status:404\n'
  } > "$config"

  chmod 600 "$config" 2>/dev/null || true
  success "Generated ${config}."
}

generate_config() {
  header
  local slug
  slug="$(select_tunnel_slug)" || return 1
  generate_config_for_slug "$slug"
}

generate_compose() {
  init_layout
  local slug
  local service
  local container
  local count=0
  local tmp

  tmp="${COMPOSE_FILE}.tmp"
  {
    printf 'services:\n'
    while IFS= read -r slug; do
      [[ -f "$(tunnel_dir "$slug")/config.yaml" ]] || continue
      service="$(service_name_for_slug "$slug")"
      container="$(container_name_for_slug "$slug")"
      count=$((count + 1))
      printf '  %s:\n' "$service"
      printf '    image: %s\n' "$CLOUDFLARED_IMAGE"
      printf '    container_name: %s\n' "$container"
      printf '    restart: unless-stopped\n'
      printf '    user: "%s:%s"\n' "$RUN_UID" "$RUN_GID"
      printf '    volumes:\n'
      printf '      - ./tunnels/%s:/home/nonroot/.cloudflared:ro\n' "$slug"
      printf '    extra_hosts:\n'
      printf '      - "host.docker.internal:host-gateway"\n'
      printf '    command: tunnel --config /home/nonroot/.cloudflared/config.yaml run\n'
      printf '    logging:\n'
      printf '      driver: json-file\n'
      printf '      options:\n'
      printf '        max-size: "10m"\n'
      printf '        max-file: "3"\n'
      printf '\n'
    done < <(list_local_slugs)
  } > "$tmp"

  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp"
    die "No tunnel config.yaml files found. Generate at least one config first."
  fi

  backup_file_if_exists "$COMPOSE_FILE"
  mv "$tmp" "$COMPOSE_FILE"
  success "Generated ${COMPOSE_FILE} with ${count} tunnel service(s)."
}

generate_compose_menu() {
  header
  generate_compose
}

compose_action() {
  local action="$1"
  local service="${2:-}"
  [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found. Generate docker-compose.yml first."
  require_compose
  case "$action" in
    start)
      if [[ -n "$service" ]]; then
        run_compose -f "$COMPOSE_FILE" up -d "$service"
      else
        run_compose -f "$COMPOSE_FILE" up -d
      fi
      ;;
    stop)
      if [[ -n "$service" ]]; then
        run_compose -f "$COMPOSE_FILE" stop "$service"
      else
        run_compose -f "$COMPOSE_FILE" stop
      fi
      ;;
    restart)
      if [[ -n "$service" ]]; then
        run_compose -f "$COMPOSE_FILE" restart "$service"
      else
        run_compose -f "$COMPOSE_FILE" restart
      fi
      ;;
    logs)
      if [[ -n "$service" ]]; then
        run_compose -f "$COMPOSE_FILE" logs --tail=200 -f "$service"
      else
        run_compose -f "$COMPOSE_FILE" logs --tail=200 -f
      fi
      ;;
    *)
      die "Unknown compose action: ${action}"
      ;;
  esac
}

select_optional_service() {
  local slug
  if confirm "Target a single tunnel service?"; then
    slug="$(select_tunnel_slug)" || return 1
    service_name_for_slug "$slug"
  else
    printf ''
  fi
}

start_tunnel() {
  header
  local service
  service="$(select_optional_service)" || return 1
  compose_action start "$service"
  success "Tunnel container(s) started."
}

stop_tunnel() {
  header
  local service
  service="$(select_optional_service)" || return 1
  compose_action stop "$service"
  success "Tunnel container(s) stopped."
}

restart_tunnel() {
  header
  local service
  service="$(select_optional_service)" || return 1
  compose_action restart "$service"
  success "Tunnel container(s) restarted."
}

view_logs() {
  header
  local service
  service="$(select_optional_service)" || return 1
  info "Press Ctrl+C to stop following logs."
  compose_action logs "$service"
}

health_dashboard() {
  header
  local docker_state="missing"
  local compose_state="missing"
  local image_state="not pulled"
  local slug
  local tunnel_id
  local config_state
  local cred_state
  local containers=()

  if command_exists docker; then
    if docker info >/dev/null 2>&1; then
      docker_state="running"
    else
      docker_state="installed, not accessible"
    fi
  fi

  if command_exists docker && compose_cmd >/dev/null; then
    compose_state="available"
  fi

  if command_exists docker && docker image inspect "$CLOUDFLARED_IMAGE" >/dev/null 2>&1; then
    image_state="present"
  fi

  printf '%bSystem%b\n' "$BOLD" "$NC"
  printf '  Docker:            %s\n' "$docker_state"
  printf '  Docker Compose:    %s\n' "$compose_state"
  printf '  cloudflared image: %s\n' "$image_state"
  printf '  Compose file:      %s\n' "$([[ -f "$COMPOSE_FILE" ]] && printf present || printf missing)"
  printf '  Workspace:         %s\n' "$BASE_DIR"
  printf '\n'

  printf '%bLocal tunnels%b\n' "$BOLD" "$NC"
  printf '%-22s %-38s %-10s %-10s\n' "WORKSPACE" "TUNNEL_ID" "CONFIG" "CREDENTIAL"
  printf '%-22s %-38s %-10s %-10s\n' "---------" "---------" "------" "----------"
  while IFS= read -r slug; do
    tunnel_id="$(get_tunnel_id "$slug" 2>/dev/null || true)"
    [[ -f "$(tunnel_dir "$slug")/config.yaml" ]] && config_state="yes" || config_state="no"
    [[ -n "$(find_credential_file "$slug" 2>/dev/null || true)" ]] && cred_state="yes" || cred_state="no"
    printf '%-22s %-38s %-10s %-10s\n' "$slug" "${tunnel_id:-unknown}" "$config_state" "$cred_state"
  done < <(list_local_slugs)

  printf '\n'
  if command_exists docker && docker info >/dev/null 2>&1; then
    printf '%bRunning containers%b\n' "$BOLD" "$NC"
    docker ps --filter "name=cloudflared_" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
    printf '\n'
    printf '%bContainer resource snapshot%b\n' "$BOLD" "$NC"
    mapfile -t containers < <(docker ps --filter "name=cloudflared_" --format "{{.Names}}")
    if [[ "${#containers[@]}" -gt 0 ]]; then
      docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" "${containers[@]}" 2>/dev/null || true
    else
      printf 'No cloudflared containers are running.\n'
    fi
  fi
}

create_backup() {
  header
  init_layout
  local stamp
  local archive
  local items=()

  stamp="$(date '+%Y%m%d-%H%M%S')"
  archive="${BACKUP_DIR}/cloudflared-manager-${stamp}.tar.gz"

  [[ -d "$TUNNELS_DIR" ]] && items+=("tunnels")
  [[ -d "$NGINX_DIR" ]] && items+=("nginx-templates")
  [[ -f "$COMPOSE_FILE" ]] && items+=("docker-compose.yml")

  [[ "${#items[@]}" -gt 0 ]] || die "Nothing to back up."

  tar -C "$BASE_DIR" -czf "$archive" "${items[@]}"
  chmod 600 "$archive" 2>/dev/null || true
  success "Backup created: ${archive}"
}

restore_backup() {
  header
  init_layout
  local archive
  archive="$(prompt "Backup archive path")"
  [[ -f "$archive" ]] || die "Backup archive not found: ${archive}"

  warn "Restore will overwrite files with the same names in ${BASE_DIR}."
  confirm_danger "Review the backup path before continuing." "restore" || die "Restore cancelled."

  create_backup
  tar -C "$BASE_DIR" -xzf "$archive"
  success "Backup restored from ${archive}."
}

backup_restore_menu() {
  header
  printf '  1) Create backup\n'
  printf '  2) Restore backup\n'
  printf '  0) Back\n\n'
  local choice
  read -r -p "Select option: " choice
  case "$choice" in
    1) create_backup ;;
    2) restore_backup ;;
    0) return 0 ;;
    *) error "Invalid option." ;;
  esac
}

generate_nginx_template() {
  header
  init_layout
  local domain
  local upstream
  local max_body
  local websocket
  local file

  domain="$(prompt "Server name / domain")"
  validate_hostname "$domain" || die "Invalid domain: ${domain}"
  upstream="$(prompt "Upstream URL" "http://127.0.0.1:3000")"
  [[ "$upstream" =~ ^https?://[^[:space:]]+$ ]] || die "Invalid upstream URL."
  max_body="$(prompt "client_max_body_size" "100m")"

  file="${NGINX_DIR}/${domain}.conf"
  backup_file_if_exists "$file"

  {
    printf 'server {\n'
    printf '    listen 80;\n'
    printf '    server_name %s;\n\n' "$domain"
    printf '    client_max_body_size %s;\n\n' "$max_body"
    printf '    location / {\n'
    printf '        proxy_pass %s;\n' "$upstream"
    printf '        proxy_http_version 1.1;\n'
    printf '        proxy_set_header Host $host;\n'
    printf '        proxy_set_header X-Real-IP $remote_addr;\n'
    printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
    printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
    printf '        proxy_set_header X-Forwarded-Host $host;\n'
  } > "$file"

  if confirm "Add WebSocket headers?"; then
    websocket="yes"
  else
    websocket="no"
  fi

  if [[ "$websocket" == "yes" ]]; then
    {
      printf '        proxy_set_header Upgrade $http_upgrade;\n'
      printf '        proxy_set_header Connection "upgrade";\n'
    } >> "$file"
  fi

  {
    printf '        proxy_read_timeout 300s;\n'
    printf '        proxy_send_timeout 300s;\n'
    printf '    }\n'
    printf '}\n'
  } >> "$file"

  success "Generated Nginx template: ${file}"
  info "Copy it to /etc/nginx/sites-available/${domain}, enable it, then run nginx -t."
}

validate_tunnels() {
  header
  local slug
  local failed=0
  local tunnel_id
  local cred
  local config

  if ! command_exists docker; then
    warn "Docker is missing. Static validation will still run."
  elif ! docker info >/dev/null 2>&1; then
    warn "Docker is not accessible. Static validation will still run."
  fi

  while IFS= read -r slug; do
    printf '\n%bValidating %s%b\n' "$BOLD" "$slug" "$NC"
    config="$(tunnel_dir "$slug")/config.yaml"
    cred="$(find_credential_file "$slug" 2>/dev/null || true)"
    tunnel_id="$(get_tunnel_id "$slug" 2>/dev/null || true)"

    if [[ -z "$cred" ]]; then
      error "Missing credential JSON."
      failed=1
    else
      success "Credential file: ${cred}"
    fi

    if [[ -z "$tunnel_id" ]]; then
      error "Cannot read TunnelID from credential JSON."
      failed=1
    else
      success "Tunnel ID: ${tunnel_id}"
    fi

    if [[ ! -f "$config" ]]; then
      error "Missing config.yaml."
      failed=1
      continue
    fi

    if ! grep -q '^ingress:' "$config"; then
      error "config.yaml is missing ingress rules."
      failed=1
    else
      success "config.yaml contains ingress rules."
    fi

    if command_exists docker && docker info >/dev/null 2>&1; then
      info "Running cloudflared ingress validation..."
      if run_cloudflared "$slug" tunnel --config /home/nonroot/.cloudflared/config.yaml ingress validate; then
        success "cloudflared ingress validation passed."
      else
        error "cloudflared ingress validation failed."
        failed=1
      fi
    fi
  done < <(list_local_slugs)

  if [[ "$failed" -eq 0 ]]; then
    success "Validation completed without errors."
  else
    die "Validation found errors."
  fi
}

main_menu() {
  init_layout
  while true; do
    header
    printf '  %bSetup%b\n' "$BOLD" "$NC"
    printf '   1) Install Docker (optional)\n'
    printf '   2) Cloudflare Login\n'
    printf '   3) Create Tunnel\n'
    printf '   4) List Tunnels\n'
    printf '   5) Delete Tunnel\n'
    printf '\n'
    printf '  %bRouting and files%b\n' "$BOLD" "$NC"
    printf '   6) Create DNS Routes\n'
    printf '   7) Generate config.yaml\n'
    printf '   8) Generate docker-compose.yml\n'
    printf '   9) Generate Nginx Template\n'
    printf '\n'
    printf '  %bOperations%b\n' "$BOLD" "$NC"
    printf '  10) Start Tunnel\n'
    printf '  11) Stop Tunnel\n'
    printf '  12) Restart Tunnel\n'
    printf '  13) View Logs\n'
    printf '  14) Health Dashboard\n'
    printf '  15) Backup/Restore\n'
    printf '  16) Validate\n'
    printf '\n'
    printf '   0) Exit\n\n'

    local choice
    read -r -p "Select option: " choice
    case "$choice" in
      1) install_docker; pause ;;
      2) cloudflare_login; pause ;;
      3) create_tunnel; pause ;;
      4) list_tunnels; pause ;;
      5) delete_tunnel; pause ;;
      6) create_dns_routes; pause ;;
      7) generate_config; pause ;;
      8) generate_compose_menu; pause ;;
      9) generate_nginx_template; pause ;;
      10) start_tunnel; pause ;;
      11) stop_tunnel; pause ;;
      12) restart_tunnel; pause ;;
      13) view_logs; pause ;;
      14) health_dashboard; pause ;;
      15) backup_restore_menu; pause ;;
      16) validate_tunnels; pause ;;
      0) success "Goodbye."; exit 0 ;;
      *) error "Invalid option."; pause ;;
    esac
  done
}

run_command() {
  local command="${1:-menu}"
  case "$command" in
    help|--help|-h) usage ;;
    version|--version|-v) printf '%s\n' "$APP_VERSION" ;;
    *)
      init_layout
      case "$command" in
        menu) main_menu ;;
        install-docker) install_docker ;;
        login) cloudflare_login ;;
        create-tunnel) create_tunnel ;;
        list) list_tunnels ;;
        dns) create_dns_routes ;;
        config) generate_config ;;
        compose) generate_compose_menu ;;
        start) compose_action start ;;
        stop) compose_action stop ;;
        restart) compose_action restart ;;
        logs) view_logs ;;
        dashboard) health_dashboard ;;
        backup) create_backup ;;
        restore) restore_backup ;;
        nginx) generate_nginx_template ;;
        validate) validate_tunnels ;;
        *) usage; die "Unknown command: ${command}" ;;
      esac
      ;;
  esac
}

run_command "${1:-menu}"
