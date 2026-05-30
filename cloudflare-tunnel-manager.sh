#!/usr/bin/env bash

set -uo pipefail

APP_NAME="Cloudflare Tunnel Manager"
APP_VERSION="1.0.0"
DEFAULT_BASE_DIR="${CFTM_HOME:-$(pwd)/cloudflared-data}"
BASE_DIR="$DEFAULT_BASE_DIR"
CLOUDFLARED_IMAGE="${CLOUDFLARED_IMAGE:-cloudflare/cloudflared:latest}"
CONTAINER_CF_DIR="/home/nonroot/.cloudflared"
STATE_FILE=""
BACKUP_DIR=""
COMPOSE_FILE=""
NGINX_TEMPLATE_DIR=""

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0 || true)"
  C_BOLD="$(tput bold || true)"
  C_DIM="$(tput dim || true)"
  C_RED="$(tput setaf 1 || true)"
  C_GREEN="$(tput setaf 2 || true)"
  C_YELLOW="$(tput setaf 3 || true)"
  C_BLUE="$(tput setaf 4 || true)"
  C_MAGENTA="$(tput setaf 5 || true)"
  C_CYAN="$(tput setaf 6 || true)"
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
fi

log_info() { printf "%b\n" "${C_BLUE}[INFO]${C_RESET} $*"; }
log_success() { printf "%b\n" "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn() { printf "%b\n" "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { printf "%b\n" "${C_RED}[ERROR]${C_RESET} $*" >&2; }
section() {
  printf "\n%b\n" "${C_BOLD}${C_CYAN}== $* ==${C_RESET}"
}

pause() {
  if [[ -t 0 ]]; then
    read -r -p "Press Enter to continue..." _
  fi
}

usage() {
  cat <<USAGE
${APP_NAME} ${APP_VERSION}

Usage:
  ./cloudflare-tunnel-manager.sh [--base-dir DIR] [--help]

Environment:
  CFTM_HOME             Default working directory for generated tunnel files.
  CLOUDFLARED_IMAGE    Docker image to use. Default: cloudflare/cloudflared:latest

Generated layout:
  cloudflared-data/
    docker-compose.yml
    tunnels.tsv
    <tunnel-slug>/
      cert.pem
      <tunnel-id>.json
      config.yaml
    backups/
    nginx-templates/

The script text is intentionally English-only so it can be used on any server.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-dir)
        [[ $# -ge 2 ]] || { log_error "--base-dir requires a directory"; exit 2; }
        BASE_DIR="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --version|-v)
        echo "$APP_VERSION"
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        exit 2
        ;;
    esac
  done
}

init_paths() {
  mkdir -p "$BASE_DIR"
  BASE_DIR="$(cd "$(dirname "$BASE_DIR")" >/dev/null 2>&1 && pwd)/$(basename "$BASE_DIR")"
  STATE_FILE="${BASE_DIR}/tunnels.tsv"
  BACKUP_DIR="${BASE_DIR}/backups"
  COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
  NGINX_TEMPLATE_DIR="${BASE_DIR}/nginx-templates"
  mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$NGINX_TEMPLATE_DIR"
  touch "$STATE_FILE"
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

sudo_cmd() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif has_command sudo; then
    sudo "$@"
  else
    log_error "This action needs root privileges and sudo is not installed."
    return 1
  fi
}

confirm() {
  local prompt="${1:-Continue?}"
  local default="${2:-N}"
  local suffix="[y/N]"
  local answer

  [[ "$default" =~ ^[Yy]$ ]] && suffix="[Y/n]"
  read -r -p "${prompt} ${suffix} " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

prompt_required() {
  local prompt="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$prompt" value
    value="$(trim "$value")"
    [[ -n "$value" ]] || log_warn "Value is required."
  done
  printf "%s" "$value"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(trim "$value")"
  printf "%s" "${value:-$default}"
}

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

slugify() {
  local value="$1"
  value="$(printf "%s" "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf "%s" "$value" | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  printf "%s" "$value"
}

valid_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]
}

valid_hostname() {
  local host="$1"
  [[ ${#host} -le 253 ]] || return 1
  [[ "$host" =~ ^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_service() {
  local service="$1"
  [[ "$service" =~ ^(http|https|tcp|ssh|rdp)://[^[:space:]]+$ || "$service" =~ ^http_status:[0-9]{3}$ || "$service" =~ ^hello_world$ ]]
}

docker_tty_args() {
  if [[ -t 0 && -t 1 ]]; then
    printf "%s\n" "-it"
  else
    printf "%s\n" "-i"
  fi
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf "docker compose"
  elif has_command docker-compose; then
    printf "docker-compose"
  else
    return 1
  fi
}

require_docker() {
  if ! has_command docker; then
    log_error "Docker is not installed. Use menu option 1 to install Docker first."
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker is installed but not available to this user."
    log_warn "Start Docker or add this user to the docker group, then log in again."
    return 1
  fi
}

require_compose() {
  require_docker || return 1
  if ! compose_cmd >/dev/null 2>&1; then
    log_error "Docker Compose is not available."
    log_warn "Install the docker compose plugin or legacy docker-compose."
    return 1
  fi
}

cloudflared() {
  local tunnel_dir="$1"
  shift
  require_docker || return 1
  mkdir -p "$tunnel_dir"
  docker run --rm "$(docker_tty_args)" \
    --user "$(id -u):$(id -g)" \
    -v "${tunnel_dir}:${CONTAINER_CF_DIR}" \
    "$CLOUDFLARED_IMAGE" "$@"
}

cloudflared_no_tty() {
  local tunnel_dir="$1"
  shift
  require_docker || return 1
  mkdir -p "$tunnel_dir"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${tunnel_dir}:${CONTAINER_CF_DIR}" \
    "$CLOUDFLARED_IMAGE" "$@"
}

tunnel_dir() {
  printf "%s/%s" "$BASE_DIR" "$1"
}

tunnel_meta_file() {
  printf "%s/.tunnel-meta" "$(tunnel_dir "$1")"
}

load_meta_value() {
  local slug="$1"
  local key="$2"
  local file
  file="$(tunnel_meta_file "$slug")"
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}

save_meta() {
  local slug="$1"
  local name="$2"
  local id="$3"
  local created_at="$4"
  local dir
  dir="$(tunnel_dir "$slug")"
  mkdir -p "$dir"
  cat >"$(tunnel_meta_file "$slug")" <<EOF_META
slug=${slug}
name=${name}
tunnel_id=${id}
created_at=${created_at}
EOF_META
}

credential_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null | sort
}

credential_file_for_slug() {
  local slug="$1"
  local dir
  local meta_id=""
  dir="$(tunnel_dir "$slug")"

  meta_id="$(load_meta_value "$slug" "tunnel_id" 2>/dev/null || true)"
  if [[ -n "$meta_id" && -f "${dir}/${meta_id}.json" ]]; then
    printf "%s/%s.json" "$dir" "$meta_id"
    return 0
  fi

  credential_files "$dir" | head -n 1
}

tunnel_id_from_credential() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  sed -n 's/.*"TunnelID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

tunnel_id_for_slug() {
  local slug="$1"
  local meta_id=""
  meta_id="$(load_meta_value "$slug" "tunnel_id" 2>/dev/null || true)"
  if [[ -n "$meta_id" ]]; then
    printf "%s" "$meta_id"
    return 0
  fi

  local credential
  credential="$(credential_file_for_slug "$slug" || true)"
  if [[ -n "$credential" ]]; then
    tunnel_id_from_credential "$credential"
  fi
}

tunnel_name_for_slug() {
  local slug="$1"
  local meta_name=""
  meta_name="$(load_meta_value "$slug" "name" 2>/dev/null || true)"
  printf "%s" "${meta_name:-$slug}"
}

refresh_registry() {
  local tmp="${STATE_FILE}.tmp"
  : >"$tmp"

  local dir slug name id created_at
  while IFS= read -r dir; do
    slug="$(basename "$dir")"
    [[ "$slug" == "backups" || "$slug" == "nginx-templates" ]] && continue
    [[ -d "$dir" ]] || continue

    name="$(tunnel_name_for_slug "$slug")"
    id="$(tunnel_id_for_slug "$slug" 2>/dev/null || true)"
    created_at="$(load_meta_value "$slug" "created_at" 2>/dev/null || true)"
    printf "%s\t%s\t%s\t%s\n" "$slug" "$name" "$id" "${created_at:-unknown}" >>"$tmp"
  done < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

  mv "$tmp" "$STATE_FILE"
}

registered_slugs() {
  refresh_registry
  awk -F '\t' 'NF >= 1 && $1 != "" {print $1}' "$STATE_FILE"
}

count_tunnels() {
  registered_slugs | wc -l | tr -d ' '
}

select_tunnel() {
  local count
  count="$(count_tunnels)"
  if [[ "$count" -eq 0 ]]; then
    log_warn "No local tunnels found in ${BASE_DIR}." >&2
    return 1
  fi

  section "Select Tunnel" >&2
  local i=1
  local slugs=()
  local slug id name
  while IFS= read -r slug; do
    id="$(tunnel_id_for_slug "$slug" 2>/dev/null || true)"
    name="$(tunnel_name_for_slug "$slug")"
    printf "%2d) %-24s %-24s %s\n" "$i" "$slug" "$name" "${id:-no-id-yet}" >&2
    slugs+=("$slug")
    ((i++))
  done < <(registered_slugs)

  local choice
  read -r -p "Choose tunnel number: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#slugs[@]} )); then
    log_error "Invalid tunnel selection."
    return 1
  fi
  printf "%s" "${slugs[$((choice - 1))]}"
}

prompt_tunnel_slug() {
  local prompt="$1"
  local suggested=""
  local value slug
  while true; do
    value="$(prompt_required "$prompt")"
    suggested="$(slugify "$value")"
    slug="$(prompt_default "Folder slug" "$suggested")"
    slug="$(slugify "$slug")"
    if valid_slug "$slug"; then
      printf "%s" "$slug"
      return 0
    fi
    log_warn "Use lowercase letters, numbers, dash, or underscore. Maximum 63 characters." >&2
  done
}

install_docker() {
  section "Install Docker"
  if has_command docker; then
    log_success "Docker is already installed: $(docker --version)"
    return 0
  fi

  if ! confirm "Install Docker using apt packages on this server?" "N"; then
    log_info "Docker installation skipped."
    return 0
  fi

  if ! has_command apt-get; then
    log_error "Automatic Docker installation currently supports apt-based Linux only."
    return 1
  fi

  sudo_cmd apt-get update
  sudo_cmd apt-get install -y ca-certificates curl gnupg docker.io docker-compose-plugin
  sudo_cmd systemctl enable --now docker || true

  if [[ "${EUID}" -ne 0 ]] && has_command usermod; then
    local current_user
    current_user="${USER:-$(id -un)}"
    if confirm "Add current user (${current_user}) to the docker group?" "Y"; then
      sudo_cmd usermod -aG docker "$current_user" || true
      log_warn "Log out and log back in for docker group membership to apply."
    fi
  fi

  log_success "Docker installation step completed."
}

cloudflare_login() {
  section "Cloudflare Login"
  require_docker || return 1

  local name slug dir
  name="$(prompt_required "Account/workspace label (example: devth): ")"
  slug="$(slugify "$name")"
  if ! valid_slug "$slug"; then
    log_error "Invalid workspace label after slug conversion: ${slug}"
    return 1
  fi
  dir="$(tunnel_dir "$slug")"
  mkdir -p "$dir"

  log_info "A Cloudflare login URL will be opened or printed by cloudflared."
  log_info "After authorizing, cert.pem will be saved in: ${dir}"
  cloudflared "$dir" tunnel login

  if [[ -f "${dir}/cert.pem" ]]; then
    log_success "Login certificate saved."
  else
    log_warn "cert.pem was not found. Login may not have completed."
  fi
}

create_tunnel() {
  section "Create Tunnel"
  require_docker || return 1

  local name slug dir cert_file credential id created_at
  name="$(prompt_required "Tunnel name in Cloudflare (example: devth-tunnel): ")"
  slug="$(prompt_tunnel_slug "Local folder label (example: devth): ")"
  dir="$(tunnel_dir "$slug")"
  mkdir -p "$dir"
  cert_file="${dir}/cert.pem"

  if [[ -n "$(credential_files "$dir" | head -n 1)" ]]; then
    log_error "This folder already contains tunnel credentials: ${dir}"
    log_warn "Use a different folder slug for each tunnel."
    return 1
  fi

  if [[ ! -f "$cert_file" ]]; then
    log_warn "No Cloudflare cert.pem found for ${slug}."
    if confirm "Run Cloudflare login for this tunnel folder now?" "Y"; then
      cloudflared "$dir" tunnel login
    fi
  fi

  [[ -f "$cert_file" ]] || {
    log_error "Cannot create a tunnel without cert.pem in ${dir}."
    return 1
  }

  log_info "Creating Cloudflare tunnel: ${name}"
  cloudflared "$dir" tunnel create "$name"

  credential="$(credential_file_for_slug "$slug" || true)"
  id=""
  if [[ -n "$credential" ]]; then
    id="$(tunnel_id_from_credential "$credential" || true)"
  fi
  created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  save_meta "$slug" "$name" "$id" "$created_at"
  refresh_registry

  log_success "Tunnel created locally as ${slug}${id:+ (${id})}."

  if confirm "Generate config.yaml for this tunnel now?" "Y"; then
    generate_config_for_slug "$slug"
  fi

  if confirm "Create DNS routes now?" "Y"; then
    create_dns_routes_for_slug "$slug"
  fi

  if confirm "Regenerate docker-compose.yml now?" "Y"; then
    generate_compose
  fi
}

list_tunnels() {
  section "Local Tunnels"
  refresh_registry
  if [[ ! -s "$STATE_FILE" ]]; then
    log_warn "No local tunnels found in ${BASE_DIR}."
  else
    printf "%-22s %-24s %-38s %-20s %-12s\n" "SLUG" "NAME" "TUNNEL ID" "CONFIG" "CONTAINER"
    printf "%-22s %-24s %-38s %-20s %-12s\n" "----" "----" "---------" "------" "---------"
    local slug name id created config_status container_status container
    while IFS=$'\t' read -r slug name id created; do
      config_status="missing"
      [[ -f "$(tunnel_dir "$slug")/config.yaml" ]] && config_status="config.yaml"
      container="cloudflared_${slug//-/_}"
      container_status="unknown"
      if has_command docker && docker info >/dev/null 2>&1; then
        container_status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || printf "not-created")"
      fi
      printf "%-22s %-24s %-38s %-20s %-12s\n" "$slug" "$name" "${id:-no-id-yet}" "$config_status" "$container_status"
    done <"$STATE_FILE"
  fi

  if confirm "Run cloudflared tunnel list from Cloudflare?" "N"; then
    local slug dir
    slug="$(select_tunnel)" || return 0
    dir="$(tunnel_dir "$slug")"
    cloudflared "$dir" tunnel list || true
  fi
}

delete_tunnel() {
  section "Delete Tunnel"
  require_docker || return 1

  local slug dir name id service container
  slug="$(select_tunnel)" || return 1
  dir="$(tunnel_dir "$slug")"
  name="$(tunnel_name_for_slug "$slug")"
  id="$(tunnel_id_for_slug "$slug" 2>/dev/null || true)"
  service="cf_${slug//-/_}"
  container="cloudflared_${slug//-/_}"

  log_warn "Selected local tunnel: ${slug} (${name}) ${id:+id=${id}}"
  confirm "Continue with delete workflow?" "N" || return 0

  if has_command docker && docker info >/dev/null 2>&1; then
    docker stop "$container" >/dev/null 2>&1 || true
    docker rm "$container" >/dev/null 2>&1 || true
  fi

  if confirm "Delete the Cloudflare tunnel remotely too?" "N"; then
    cloudflared "$dir" tunnel delete "$name" || cloudflared "$dir" tunnel delete "$id" || true
  fi

  if confirm "Archive local folder instead of permanent delete?" "Y"; then
    local archive
    archive="${BACKUP_DIR}/${slug}-deleted-$(date -u +"%Y%m%dT%H%M%SZ").tar.gz"
    tar -czf "$archive" -C "$BASE_DIR" "$slug"
    rm -rf "$dir"
    log_success "Archived to ${archive} and removed local folder."
  elif confirm "Permanently remove ${dir}?" "N"; then
    rm -rf "$dir"
    log_success "Removed ${dir}."
  fi

  refresh_registry
  generate_compose
  log_info "Service name was ${service}; compose file has been regenerated."
}

collect_ingress_rules() {
  local output_file="$1"
  : >"$output_file"

  local default_service
  default_service="$(prompt_default "Default origin service for hostnames" "http://host.docker.internal:80")"
  if ! valid_service "$default_service"; then
    log_error "Invalid service: ${default_service}"
    return 1
  fi

  log_info "Enter hostnames one by one. Leave blank when finished."
  local hostname service
  while true; do
    read -r -p "Hostname (blank to finish): " hostname
    hostname="$(trim "$hostname")"
    [[ -z "$hostname" ]] && break
    if ! valid_hostname "$hostname"; then
      log_warn "Invalid hostname skipped: ${hostname}"
      continue
    fi
    service="$(prompt_default "Service for ${hostname}" "$default_service")"
    if ! valid_service "$service"; then
      log_warn "Invalid service skipped for ${hostname}: ${service}"
      continue
    fi
    printf "%s\t%s\n" "$hostname" "$service" >>"$output_file"
  done

  [[ -s "$output_file" ]] || {
    log_error "At least one ingress hostname is required."
    return 1
  }
}

generate_config_for_slug() {
  local slug="$1"
  local dir id credential config tmp_rules
  dir="$(tunnel_dir "$slug")"
  mkdir -p "$dir"
  credential="$(credential_file_for_slug "$slug" || true)"
  id="$(tunnel_id_for_slug "$slug" 2>/dev/null || true)"

  if [[ -z "$credential" || -z "$id" ]]; then
    log_error "No tunnel credential JSON found for ${slug}. Create the tunnel first."
    return 1
  fi

  tmp_rules="$(mktemp)"
  collect_ingress_rules "$tmp_rules" || {
    rm -f "$tmp_rules"
    return 1
  }

  config="${dir}/config.yaml"
  if [[ -f "$config" ]]; then
    cp "$config" "${config}.bak.$(date -u +"%Y%m%dT%H%M%SZ")"
  fi

  {
    printf "tunnel: %s\n" "$id"
    printf "credentials-file: %s/%s\n\n" "$CONTAINER_CF_DIR" "$(basename "$credential")"
    printf "ingress:\n"
    while IFS=$'\t' read -r hostname service; do
      printf "  - hostname: %s\n" "$hostname"
      printf "    service: %s\n" "$service"
    done <"$tmp_rules"
    printf "  - service: http_status:404\n"
  } >"$config"

  rm -f "$tmp_rules"
  log_success "Generated ${config}."

  if confirm "Validate this config with cloudflared?" "Y"; then
    cloudflared_no_tty "$dir" tunnel --config "${CONTAINER_CF_DIR}/config.yaml" ingress validate
  fi
}

generate_config() {
  section "Generate config.yaml"
  local slug
  slug="$(select_tunnel)" || return 1
  generate_config_for_slug "$slug"
}

create_dns_routes_for_slug() {
  local slug="$1"
  local dir name route_input hostnames hostname
  dir="$(tunnel_dir "$slug")"
  name="$(tunnel_name_for_slug "$slug")"

  if [[ ! -f "${dir}/cert.pem" ]]; then
    log_warn "No cert.pem found in ${dir}."
    if confirm "Run Cloudflare login for this tunnel folder now?" "Y"; then
      cloudflared "$dir" tunnel login
    fi
  fi

  read -r -p "Hostnames for DNS routes (space or comma separated): " route_input
  route_input="${route_input//,/ }"
  read -r -a hostnames <<<"$route_input"

  if [[ "${#hostnames[@]}" -eq 0 ]]; then
    log_error "No hostnames entered."
    return 1
  fi

  for hostname in "${hostnames[@]}"; do
    hostname="$(trim "$hostname")"
    [[ -z "$hostname" ]] && continue
    if ! valid_hostname "$hostname"; then
      log_warn "Skipping invalid hostname: ${hostname}"
      continue
    fi
    log_info "Creating DNS route: ${hostname} -> ${name}"
    cloudflared "$dir" tunnel route dns "$name" "$hostname" || true
  done
}

create_dns_routes() {
  section "Create DNS Routes"
  require_docker || return 1
  local slug
  slug="$(select_tunnel)" || return 1
  create_dns_routes_for_slug "$slug"
}

generate_compose() {
  section "Generate docker-compose.yml"
  refresh_registry

  {
    printf "version: '3.8'\n\n"
    printf "services:\n"
  } >"$COMPOSE_FILE"

  local any="false"
  local slug name id dir service container
  while IFS= read -r slug; do
    dir="$(tunnel_dir "$slug")"
    [[ -f "${dir}/config.yaml" ]] || continue
    any="true"
    name="$(tunnel_name_for_slug "$slug")"
    id="$(tunnel_id_for_slug "$slug" 2>/dev/null || true)"
    service="cf_${slug//-/_}"
    container="cloudflared_${slug//-/_}"
    cat >>"$COMPOSE_FILE" <<EOF_COMPOSE
  ${service}:
    image: ${CLOUDFLARED_IMAGE}
    container_name: ${container}
    restart: unless-stopped
    user: "$(id -u):$(id -g)"
    volumes:
      - ./${slug}:${CONTAINER_CF_DIR}:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command: tunnel --config ${CONTAINER_CF_DIR}/config.yaml run
    labels:
      com.cloudflare.tunnel.manager: "true"
      com.cloudflare.tunnel.slug: "${slug}"
      com.cloudflare.tunnel.name: "${name}"
      com.cloudflare.tunnel.id: "${id:-unknown}"

EOF_COMPOSE
  done < <(registered_slugs)

  if [[ "$any" != "true" ]]; then
    cat >>"$COMPOSE_FILE" <<EOF_EMPTY
  # No tunnel services yet.
  # Create a tunnel and config.yaml, then regenerate this file.
EOF_EMPTY
    log_warn "No configured tunnels found. Wrote placeholder compose file."
  else
    log_success "Generated ${COMPOSE_FILE}."
  fi
}

compose_service_choices() {
  local include_all="${1:-true}"
  local services=()
  local slug service
  while IFS= read -r slug; do
    [[ -f "$(tunnel_dir "$slug")/config.yaml" ]] || continue
    service="cf_${slug//-/_}"
    services+=("$service")
  done < <(registered_slugs)

  if [[ "${#services[@]}" -eq 0 ]]; then
    log_error "No compose services found. Generate config.yaml and docker-compose.yml first."
    return 1
  fi

  section "Select Service" >&2
  if [[ "$include_all" == "true" ]]; then
    printf " 0) All services\n" >&2
  fi

  local i=1
  for service in "${services[@]}"; do
    printf "%2d) %s\n" "$i" "$service" >&2
    ((i++))
  done

  local choice
  read -r -p "Choose service number: " choice
  if [[ "$include_all" == "true" && "$choice" == "0" ]]; then
    printf "__all__"
    return 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#services[@]} )); then
    log_error "Invalid service selection."
    return 1
  fi
  printf "%s" "${services[$((choice - 1))]}"
}

run_compose() {
  local action="$1"
  local compose
  require_compose || return 1
  [[ -f "$COMPOSE_FILE" ]] || generate_compose
  compose="$(compose_cmd)"
  (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" $action)
}

start_tunnel() {
  section "Start Tunnel"
  require_compose || return 1
  [[ -f "$COMPOSE_FILE" ]] || generate_compose
  local service compose
  service="$(compose_service_choices true)" || return 1
  compose="$(compose_cmd)"
  if [[ "$service" == "__all__" ]]; then
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" up -d)
  else
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" up -d "$service")
  fi
}

stop_tunnel() {
  section "Stop Tunnel"
  require_compose || return 1
  local service compose
  service="$(compose_service_choices true)" || return 1
  compose="$(compose_cmd)"
  if [[ "$service" == "__all__" ]]; then
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" stop)
  else
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" stop "$service")
  fi
}

restart_tunnel() {
  section "Restart Tunnel"
  require_compose || return 1
  local service compose
  service="$(compose_service_choices true)" || return 1
  compose="$(compose_cmd)"
  if [[ "$service" == "__all__" ]]; then
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" restart)
  else
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" restart "$service")
  fi
}

view_logs() {
  section "View Logs"
  require_compose || return 1
  local service compose follow
  service="$(compose_service_choices true)" || return 1
  compose="$(compose_cmd)"
  follow=""
  confirm "Follow logs live?" "Y" && follow="-f"
  if [[ "$service" == "__all__" ]]; then
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" logs $follow --tail=200)
  else
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" logs $follow --tail=200 "$service")
  fi
}

validate_all() {
  section "Validation"
  local failures=0

  if require_docker; then
    log_success "Docker is available."
  else
    ((failures++))
  fi

  if compose_cmd >/dev/null 2>&1; then
    log_success "Docker Compose is available: $(compose_cmd)"
  else
    log_warn "Docker Compose is not available."
    ((failures++))
  fi

  refresh_registry
  local slug dir
  while IFS= read -r slug; do
    dir="$(tunnel_dir "$slug")"
    if [[ -f "${dir}/config.yaml" ]]; then
      log_info "Validating config for ${slug}"
      cloudflared_no_tty "$dir" tunnel --config "${CONTAINER_CF_DIR}/config.yaml" ingress validate || ((failures++))
    else
      log_warn "Missing config.yaml for ${slug}"
      ((failures++))
    fi
  done < <(registered_slugs)

  if [[ -f "$COMPOSE_FILE" ]] && compose_cmd >/dev/null 2>&1 && has_command docker; then
    local compose
    compose="$(compose_cmd)"
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" config >/dev/null) || ((failures++))
  fi

  if [[ "$failures" -eq 0 ]]; then
    log_success "Validation completed without failures."
  else
    log_warn "Validation completed with ${failures} issue(s)."
  fi
}

health_dashboard() {
  section "Health Dashboard"
  printf "%b\n" "${C_BOLD}Base directory:${C_RESET} ${BASE_DIR}"
  printf "%b\n" "${C_BOLD}Cloudflared image:${C_RESET} ${CLOUDFLARED_IMAGE}"
  printf "%b\n" "${C_BOLD}Timestamp:${C_RESET} $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo

  if has_command docker; then
    docker --version || true
    if docker info >/dev/null 2>&1; then
      log_success "Docker daemon is reachable."
    else
      log_warn "Docker daemon is not reachable."
    fi
  else
    log_warn "Docker is not installed."
  fi

  if compose_cmd >/dev/null 2>&1; then
    log_success "Compose command: $(compose_cmd)"
  else
    log_warn "Compose command not found."
  fi

  echo
  section "Disk Usage"
  df -h "$BASE_DIR" || true

  echo
  section "Tunnel Containers"
  refresh_registry
  local slug container status health restarts
  while IFS= read -r slug; do
    container="cloudflared_${slug//-/_}"
    if has_command docker && docker info >/dev/null 2>&1; then
      status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || printf "not-created")"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$container" 2>/dev/null || printf "n/a")"
      restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || printf "n/a")"
    else
      status="unknown"
      health="unknown"
      restarts="unknown"
    fi
    printf "%-24s status=%-12s health=%-10s restarts=%s\n" "$container" "$status" "$health" "$restarts"
  done < <(registered_slugs)

  echo
  section "Recent Compose Status"
  if [[ -f "$COMPOSE_FILE" ]] && compose_cmd >/dev/null 2>&1 && has_command docker && docker info >/dev/null 2>&1; then
    local compose
    compose="$(compose_cmd)"
    (cd "$BASE_DIR" && $compose -f "$COMPOSE_FILE" ps) || true
  else
    log_warn "Compose status unavailable."
  fi
}

backup_data() {
  section "Backup"
  mkdir -p "$BACKUP_DIR"

  local include_credentials="no"
  if confirm "Include credential JSON files and cert.pem in backup? Store the archive securely." "Y"; then
    include_credentials="yes"
  fi

  local archive
  archive="${BACKUP_DIR}/cloudflared-backup-$(date -u +"%Y%m%dT%H%M%SZ").tar.gz"

  if [[ "$include_credentials" == "yes" ]]; then
    tar --exclude "./backups" -czf "$archive" -C "$BASE_DIR" .
  else
    tar --exclude "./backups" --exclude "*.json" --exclude "cert.pem" -czf "$archive" -C "$BASE_DIR" .
  fi

  chmod 600 "$archive"
  log_success "Backup created: ${archive}"
}

restore_data() {
  section "Restore"
  mkdir -p "$BACKUP_DIR"

  local archives=()
  local archive
  while IFS= read -r archive; do
    archives+=("$archive")
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "*.tar.gz" | sort)

  if [[ "${#archives[@]}" -eq 0 ]]; then
    log_warn "No backup archives found in ${BACKUP_DIR}."
    read -r -p "Enter full path to backup archive, or blank to cancel: " archive
    archive="$(trim "$archive")"
    [[ -n "$archive" ]] || return 0
    archives=("$archive")
  else
    local i=1
    for archive in "${archives[@]}"; do
      printf "%2d) %s\n" "$i" "$(basename "$archive")"
      ((i++))
    done
    local choice
    read -r -p "Choose backup number: " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#archives[@]} )); then
      log_error "Invalid backup selection."
      return 1
    fi
    archive="${archives[$((choice - 1))]}"
  fi

  [[ -f "$archive" ]] || {
    log_error "Backup archive not found: ${archive}"
    return 1
  }

  log_warn "Restore will extract files into ${BASE_DIR}."
  confirm "Continue restore?" "N" || return 0
  tar -xzf "$archive" -C "$BASE_DIR"
  refresh_registry
  log_success "Restore completed."
}

backup_restore_menu() {
  section "Backup / Restore"
  echo "1) Create backup"
  echo "2) Restore backup"
  echo "0) Back"
  local choice
  read -r -p "Choose an option: " choice
  case "$choice" in
    1) backup_data ;;
    2) restore_data ;;
    0) return 0 ;;
    *) log_error "Invalid option." ;;
  esac
}

nginx_template_generator() {
  section "Nginx Template Generator"
  mkdir -p "$NGINX_TEMPLATE_DIR"

  local hostname upstream output websocket
  hostname="$(prompt_required "Server name / hostname: ")"
  if ! valid_hostname "$hostname"; then
    log_error "Invalid hostname: ${hostname}"
    return 1
  fi

  upstream="$(prompt_default "Upstream service URL" "http://127.0.0.1:3000")"
  if ! [[ "$upstream" =~ ^https?://[^[:space:]]+$ ]]; then
    log_error "Nginx upstream must be http:// or https://"
    return 1
  fi

  websocket="no"
  confirm "Include WebSocket headers?" "Y" && websocket="yes"
  output="${NGINX_TEMPLATE_DIR}/${hostname}.conf"

  {
    printf "server {\n"
    printf "    listen 80;\n"
    printf "    server_name %s;\n\n" "$hostname"
    printf "    client_max_body_size 1024m;\n\n"
    printf "    location / {\n"
    printf "        proxy_pass %s;\n" "$upstream"
    printf "        proxy_set_header Host \$host;\n"
    printf "        proxy_set_header X-Real-IP \$remote_addr;\n"
    printf "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
    printf "        proxy_set_header X-Forwarded-Proto \$scheme;\n"
    printf "        proxy_read_timeout 3600;\n"
    printf "        proxy_send_timeout 3600;\n"
    if [[ "$websocket" == "yes" ]]; then
      printf "        proxy_http_version 1.1;\n"
      printf "        proxy_set_header Upgrade \$http_upgrade;\n"
      printf "        proxy_set_header Connection \"upgrade\";\n"
    fi
    printf "    }\n"
    printf "}\n"
  } >"$output"

  log_success "Generated ${output}"
  log_info "Install example:"
  log_info "  sudo cp ${output} /etc/nginx/sites-available/${hostname}"
  log_info "  sudo ln -s /etc/nginx/sites-available/${hostname} /etc/nginx/sites-enabled/"
  log_info "  sudo nginx -t && sudo systemctl reload nginx"
}

show_main_menu() {
  clear || true
  printf "%b\n" "${C_BOLD}${C_MAGENTA}${APP_NAME}${C_RESET} ${C_DIM}v${APP_VERSION}${C_RESET}"
  printf "%b\n" "${C_DIM}Working directory: ${BASE_DIR}${C_RESET}"
  echo
  echo " 1) Install Docker (optional)"
  echo " 2) Cloudflare Login"
  echo " 3) Create Tunnel"
  echo " 4) List Tunnels"
  echo " 5) Delete Tunnel"
  echo " 6) Create DNS Routes"
  echo " 7) Generate config.yaml"
  echo " 8) Generate docker-compose.yml"
  echo " 9) Start Tunnel"
  echo "10) Stop Tunnel"
  echo "11) Restart Tunnel"
  echo "12) View Logs"
  echo "13) Health Dashboard"
  echo "14) Backup / Restore"
  echo "15) Nginx Template Generator"
  echo "16) Validation"
  echo " 0) Exit"
  echo
}

main_loop() {
  local choice
  while true; do
    show_main_menu
    read -r -p "Choose an option: " choice
    case "$choice" in
      1) install_docker; pause ;;
      2) cloudflare_login; pause ;;
      3) create_tunnel; pause ;;
      4) list_tunnels; pause ;;
      5) delete_tunnel; pause ;;
      6) create_dns_routes; pause ;;
      7) generate_config; pause ;;
      8) generate_compose; pause ;;
      9) start_tunnel; pause ;;
      10) stop_tunnel; pause ;;
      11) restart_tunnel; pause ;;
      12) view_logs; pause ;;
      13) health_dashboard; pause ;;
      14) backup_restore_menu; pause ;;
      15) nginx_template_generator; pause ;;
      16) validate_all; pause ;;
      0|q|Q) log_info "Goodbye."; exit 0 ;;
      *) log_error "Invalid option."; pause ;;
    esac
  done
}

parse_args "$@"
init_paths
main_loop
