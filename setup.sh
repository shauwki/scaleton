#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE_FILE="${SCRIPT_DIR}/.env.example"
TRAEFIK_TEMPLATE="${SCRIPT_DIR}/core/traefik/traefik.yml.template"
TRAEFIK_CONFIG="${SCRIPT_DIR}/core/traefik/traefik.yml"
TRAEFIK_USERS="${SCRIPT_DIR}/core/traefik/users.htpasswd"
DB_TEMPLATE="${SCRIPT_DIR}/core/database/init-databases.template.sh"
DB_INIT="${SCRIPT_DIR}/core/database/init-databases.sh"

log() {
  printf '[%s] %s\n' "$1" "$2"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

shell_quote() {
  local value="$1"
  value=${value//\'/\'"\'"\'}
  printf "'%s'" "$value"
}

ensure_structure() {
  mkdir -p ./core/traefik
  mkdir -p ./core/database
  mkdir -p ./apps
  mkdir -p ./services
  mkdir -p ./backups
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    if [ ! -f "$ENV_EXAMPLE_FILE" ]; then
      die ".env and .env.example are missing"
    fi
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "INIT" ".env created from .env.example"
  fi
}

load_env() {
  ensure_env_file
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

set_env_var() {
  local key="$1"
  local value="$2"
  local quoted
  quoted=$(shell_quote "$value")

  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${quoted}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$quoted" >> "$ENV_FILE"
  fi
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local input=""
  if [ -n "$default" ]; then
    read -r -p "${prompt} [${default}]: " input
  else
    read -r -p "${prompt}: " input
  fi
  if [ -z "$input" ]; then
    printf '%s' "$default"
  else
    printf '%s' "$input"
  fi
}

prompt_secret() {
  local prompt="$1"
  local first=""
  local second=""

  while true; do
    read -r -s -p "${prompt}: " first
    printf '\n'
    read -r -s -p "Confirm ${prompt}: " second
    printf '\n'
    if [ "$first" != "$second" ]; then
      echo "Values do not match, try again."
      continue
    fi
    if [ -z "$first" ]; then
      echo "Value cannot be empty."
      continue
    fi
    printf '%s' "$first"
    return
  done
}

generate_traefik_config() {
  local stack_id="$1"
  local network_name="network-${stack_id}"
  [ -f "$TRAEFIK_TEMPLATE" ] || die "Missing Traefik template: ${TRAEFIK_TEMPLATE}"

  sed \
    -e "s|__NETWORK_NAME__|${network_name}|g" \
    -e "s|__STACK_ID__|${stack_id}|g" \
    "$TRAEFIK_TEMPLATE" > "$TRAEFIK_CONFIG"
}

generate_db_init_template() {
  [ -f "$DB_TEMPLATE" ] || die "Missing database template: ${DB_TEMPLATE}"
  cp "$DB_TEMPLATE" "$DB_INIT"
  chmod +x "$DB_INIT"
}

generate_traefik_htpasswd() {
  local user="$1"
  local password="$2"
  mkdir -p "$(dirname "$TRAEFIK_USERS")"

  if ! command -v docker >/dev/null 2>&1; then
    die "docker command not found; required to generate htpasswd"
  fi

  docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$password" > "$TRAEFIK_USERS"
  chmod 640 "$TRAEFIK_USERS"
}

validate_env() {
  load_env
  local missing=0
  local key

  for key in STACK_ID PRIMARY_DOMAIN TRAEFIK_BASIC_AUTH_USER; do
    if [ -z "${!key:-}" ]; then
      echo "Missing required env: ${key}"
      missing=1
    fi
  done

  if [ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    echo "Warning: CLOUDFLARE_TUNNEL_TOKEN is empty. Public routing will not work yet."
  fi

  if [ "$missing" -eq 1 ]; then
    return 1
  fi

  return 0
}

validate_stack() {
  if ! validate_env; then
    die "Environment validation failed"
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker compose config --quiet >/dev/null 2>&1; then
      log "VALIDATE" "docker compose config is valid"
    else
      die "docker compose config validation failed"
    fi
  else
    log "VALIDATE" "docker not found, skipped compose validation"
  fi
}

is_empty_assignment_line() {
  local line="$1"
  if [[ "$line" =~ ^([A-Z0-9_]+)=\'\'$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ ^([A-Z0-9_]+)=\"\"$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$line" =~ ^([A-Z0-9_]+)=$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

gen_secret() {
  openssl rand -base64 32
}

gen_secrets() {
  ensure_env_file
  local tmp
  tmp=$(mktemp)

  while IFS= read -r line; do
    local key=""
    if key=$(is_empty_assignment_line "$line"); then
      if [[ "$key" == *_PASSWORD || "$key" == *_SECRET ]]; then
        local secret
        secret=$(gen_secret)
        printf "%s=%s\n" "$key" "$(shell_quote "$secret")" >> "$tmp"
        log "SECRETS" "Generated ${key}"
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$ENV_FILE"

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log "SECRETS" "Done"
}

reset_command() {
  local target="${1:-}"
  case "$target" in
    traefik-password)
      load_env
      local password
      password=$(prompt_secret "New Traefik dashboard password")
      generate_traefik_htpasswd "${TRAEFIK_BASIC_AUTH_USER}" "$password"
      log "RESET" "Traefik dashboard password updated"
      ;;
    env)
      local key="${2:-}"
      [ -n "$key" ] || die "Usage: ./setup.sh reset env <KEY>"
      ensure_env_file
      local value
      value=$(prompt_value "Value for ${key}" "")
      set_env_var "$key" "$value"
      log "RESET" "Updated ${key}"
      ;;
    database-template)
      generate_db_init_template
      log "RESET" "Regenerated ${DB_INIT} from template"
      ;;
    *)
      die "Usage: ./setup.sh reset <traefik-password|env|database-template>"
      ;;
  esac
}

init_command() {
  ensure_structure
  ensure_env_file
  load_env

  local stack_id domain tz tunnel token_user token_password
  stack_id=$(prompt_value "Stack ID (unique project id)" "${STACK_ID:-scaleton}")
  domain=$(prompt_value "Primary domain" "${PRIMARY_DOMAIN:-example.com}")
  tz=$(prompt_value "Timezone" "${TZ:-Europe/Amsterdam}")
  tunnel=$(prompt_value "Cloudflare tunnel token (optional now)" "${CLOUDFLARE_TUNNEL_TOKEN:-}")
  token_user=$(prompt_value "Traefik dashboard username" "${TRAEFIK_BASIC_AUTH_USER:-admin}")
  token_password=$(prompt_secret "Traefik dashboard password")

  set_env_var "STACK_ID" "$stack_id"
  set_env_var "PRIMARY_DOMAIN" "$domain"
  set_env_var "TZ" "$tz"
  set_env_var "CLOUDFLARE_TUNNEL_TOKEN" "$tunnel"
  set_env_var "TRAEFIK_BASIC_AUTH_USER" "$token_user"

  generate_traefik_config "$stack_id"
  generate_db_init_template
  generate_traefik_htpasswd "$token_user" "$token_password"

  chmod 600 "$ENV_FILE"
  chmod +x "$DB_INIT"

  validate_stack

  echo
  log "DONE" "Skeleton initialized"
  echo "- Stack ID: ${stack_id}"
  echo "- Domain: ${domain}"
  echo "- Compose project: ${stack_id}"
  echo "- Network: network-${stack_id}"
  echo
  echo "Next steps:"
  echo "1) Configure Cloudflare tunnel ingress for ${domain} and tre.${domain}"
  echo "2) Run: docker compose up -d"
  echo "3) Open: https://tre.${domain}"
}

print_help() {
  cat <<'EOF'
Usage: ./setup.sh <command>

Commands:
  init                         Interactive bootstrap for skeleton stack
  --gen-secrets                Generate random values for empty *_PASSWORD/*_SECRET env keys
  --validate                   Validate .env and docker compose config
  reset traefik-password       Reset Traefik dashboard password (users.htpasswd)
  reset env <KEY>              Reset a single env key interactively
  reset database-template      Regenerate database init script from template
  --help                       Show this help
EOF
}

main() {
  case "${1:-}" in
    init)
      init_command
      ;;
    --gen-secrets)
      gen_secrets
      ;;
    --validate)
      validate_stack
      ;;
    reset)
      shift
      reset_command "$@"
      ;;
    --help|-h|"")
      print_help
      ;;
    *)
      die "Unknown command: ${1}. Use --help."
      ;;
  esac
}

main "$@"
