#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
SCRIPT_NAME="./$(basename "$0")"

ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
TRAEFIK_CONFIG="${SCRIPT_DIR}/core/traefik/traefik.yml"
TRAEFIK_USERS="${SCRIPT_DIR}/core/traefik/users.htpasswd"
DB_INIT="${SCRIPT_DIR}/core/database/init-databases.sh"
CF_CONFIG="${SCRIPT_DIR}/core/cloudflared/config.yml"
CF_CERT_FILE="${HOME}/.cloudflared/cert.pem"

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

is_standard_env_key() {
  case "$1" in
    TZ|STACK_ID|PRIMARY_DOMAIN|CLOUDFLARE_TUNNEL_TOKEN|CLOUDFLARE_TUNNEL_NAME|CLOUDFLARE_TUNNEL_ID|TRAEFIK_BASIC_AUTH_USER|POSTGRES_DB|POSTGRES_USER|POSTGRES_PASSWORD|APP_SECRET|APP_PASSWORD)
      return 0
      ;;
  esac
  return 1
}

normalize_env_file() {
  [ -f "$ENV_FILE" ] || return

  load_env_if_exists

  local tmp line key val seen
  local extras=()
  tmp=$(mktemp)
  seen=""

  cat > "$tmp" <<EOF
TZ=$(shell_quote "${TZ:-Europe/Amsterdam}")

# Unique compose project id (used for isolation)
STACK_ID=$(shell_quote "${STACK_ID:-scaleton}")

# Primary domain for this stack
PRIMARY_DOMAIN=$(shell_quote "${PRIMARY_DOMAIN:-example.com}")

# Cloudflare tunnel settings
CLOUDFLARE_TUNNEL_TOKEN=$(shell_quote "${CLOUDFLARE_TUNNEL_TOKEN:-}")
CLOUDFLARE_TUNNEL_NAME=$(shell_quote "${CLOUDFLARE_TUNNEL_NAME:-}")
CLOUDFLARE_TUNNEL_ID=$(shell_quote "${CLOUDFLARE_TUNNEL_ID:-}")

# Traefik dashboard basic auth username
TRAEFIK_BASIC_AUTH_USER=$(shell_quote "${TRAEFIK_BASIC_AUTH_USER:-admin}")

# Postgres base credentials
POSTGRES_DB=$(shell_quote "${POSTGRES_DB:-scaleton_db}")
POSTGRES_USER=$(shell_quote "${POSTGRES_USER:-admin}")
POSTGRES_PASSWORD=$(shell_quote "${POSTGRES_PASSWORD:-}")

# App credentials
APP_SECRET=$(shell_quote "${APP_SECRET:-}")
APP_PASSWORD=$(shell_quote "${APP_PASSWORD:-}")
EOF

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z0-9_]+)= ]]; then
      key="${BASH_REMATCH[1]}"
      if ! is_standard_env_key "$key"; then
        extras+=("$key")
      fi
    fi
  done < "$ENV_FILE"

  if [ "${#extras[@]}" -gt 0 ]; then
    printf '\n# Custom variables\n' >> "$tmp"
    for key in "${extras[@]}"; do
      case " $seen " in
        *" $key "*)
          continue
          ;;
      esac
      seen="${seen}${key} "
      val="${!key:-}"
      printf '%s=%s\n' "$key" "$(shell_quote "$val")" >> "$tmp"
    done
  fi

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

random_lower_alnum() {
  local len="$1"
  local out=""
  local chunk
  while [ "${#out}" -lt "$len" ]; do
    chunk=$(openssl rand -base64 96 | tr -dc 'a-z0-9')
    out="${out}${chunk}"
  done
  printf '%s' "${out:0:${len}}"
}

normalize_tunnel_name() {
  local raw="$1"
  local normalized
  normalized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')
  normalized="${normalized#-}"
  normalized="${normalized%-}"
  if [ -z "$normalized" ]; then
    normalized="scaleton"
  fi
  printf '%s' "$normalized"
}

default_tunnel_name() {
  if [ -n "${PRIMARY_DOMAIN:-}" ]; then
    printf '%s' "${PRIMARY_DOMAIN,,}"
    return
  fi

  if [ -n "${STACK_ID:-}" ]; then
    normalize_tunnel_name "$STACK_ID"
    return
  fi
  normalize_tunnel_name "$(basename "$SCRIPT_DIR")"
}

rename_project_dir_if_needed() {
  local target_name="$1"
  local current_name parent_dir target_dir old_path

  [ -n "$target_name" ] || return
  current_name="$(basename "$SCRIPT_DIR")"

  if [ "$target_name" = "$current_name" ]; then
    return
  fi

  case "$target_name" in
    */*)
      die "Folder name cannot contain '/'"
      ;;
  esac

  parent_dir="$(dirname "$SCRIPT_DIR")"
  target_dir="${parent_dir}/${target_name}"
  old_path="${parent_dir}/${current_name}"

  if [ -e "$target_dir" ]; then
    die "Cannot rename folder; target already exists: ${target_dir}"
  fi

  mv "$SCRIPT_DIR" "$target_dir"

  # Keep old path usable for the current shell session.
  # A child script cannot change the parent shell's cwd, so this symlink
  # prevents a broken cwd after rename.
  ln -s "$target_name" "$old_path" 2>/dev/null || true

  SCRIPT_DIR="$target_dir"
  cd "$SCRIPT_DIR"
  log "INIT" "Project directory renamed to: ${target_name}"
}

prompt_directory_rename() {
  local current_name target_name
  current_name="$(basename "$SCRIPT_DIR")"
  target_name=$(prompt_value "Rename project folder to (empty keeps ${current_name})" "")

  if [ -z "$target_name" ]; then
    log "INIT" "Directory name unchanged: ${current_name}"
    return
  fi

  rename_project_dir_if_needed "$target_name"
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  die "This operation needs root privileges. Install sudo or run as root."
}

detect_platform() {
  case "$(uname -s)" in
    Linux)
      if [ -f /proc/version ] && grep -qi microsoft /proc/version; then
        printf 'wsl'
      else
        printf 'linux'
      fi
      ;;
    Darwin)
      printf 'macos'
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

install_cloudflared_linux() {
  if command -v apt-get >/dev/null 2>&1; then
    run_privileged apt-get update
    run_privileged apt-get install -y cloudflared
    return
  fi

  if command -v dnf >/dev/null 2>&1; then
    run_privileged dnf install -y cloudflared
    return
  fi

  if command -v yum >/dev/null 2>&1; then
    run_privileged yum install -y cloudflared
    return
  fi

  if command -v pacman >/dev/null 2>&1; then
    run_privileged pacman -Sy --noconfirm cloudflared
    return
  fi

  if command -v zypper >/dev/null 2>&1; then
    run_privileged zypper --non-interactive install cloudflared
    return
  fi

  die "No supported package manager found for cloudflared install."
}

install_cloudflared_macos() {
  if command -v brew >/dev/null 2>&1; then
    brew install cloudflared
    return
  fi
  die "Homebrew is required on macOS to install cloudflared."
}

ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "CF" "cloudflared already installed"
    return
  fi

  local platform
  platform=$(detect_platform)
  log "CF" "Installing cloudflared for ${platform}"

  case "$platform" in
    linux|wsl)
      install_cloudflared_linux
      ;;
    macos)
      install_cloudflared_macos
      ;;
    *)
      die "Unsupported platform for automatic cloudflared install"
      ;;
  esac

  command -v cloudflared >/dev/null 2>&1 || die "cloudflared install failed"
  log "CF" "cloudflared installed"
}

load_env_if_exists() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

extract_cf_cert_token_json() {
  [ -f "$CF_CERT_FILE" ] || return 1

  local payload
  payload=$(grep -v "^-----" "$CF_CERT_FILE" | tr -d '\n')
  [ -n "$payload" ] || return 1

  printf '%s' "$payload" | base64 -d 2>/dev/null || return 1
}

extract_cf_cert_field() {
  local field="$1"
  local token_json
  token_json=$(extract_cf_cert_token_json) || return 1

  python3 - <<'PY' "$field" "$token_json"
import json
import sys

field = sys.argv[1]
raw = sys.argv[2]
obj = json.loads(raw)
val = obj.get(field, "")
print(val if isinstance(val, str) else "")
PY
}

cf_zone_name_from_api() {
  local zone_id="$1"
  local api_token="$2"

  command -v curl >/dev/null 2>&1 || die "curl is required for Cloudflare zone verification"

  local response
  response=$(curl -fsSL \
    -H "Authorization: Bearer ${api_token}" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}" 2>/dev/null) || return 1

  python3 - <<'PY' "$response"
import json
import sys

raw = sys.argv[1]
obj = json.loads(raw)
if not obj.get("success"):
    print("")
    raise SystemExit(0)

result = obj.get("result") or {}
print(result.get("name", ""))
PY
}

domain_matches_zone() {
  local domain="$1"
  local zone="$2"

  [ -n "$domain" ] || return 1
  [ -n "$zone" ] || return 1

  if [ "$domain" = "$zone" ]; then
    return 0
  fi

  case "$domain" in
    *."$zone")
      return 0
      ;;
  esac

  return 1
}

verify_primary_domain_zone() {
  local primary_domain="$1"
  local cert_zone_id cert_api_token cert_zone_name

  command -v python3 >/dev/null 2>&1 || die "python3 is required for Cloudflare zone verification"

  cert_zone_id=$(extract_cf_cert_field "zoneID" || true)
  cert_api_token=$(extract_cf_cert_field "apiToken" || true)

  [ -n "$cert_zone_id" ] || die "Could not read zoneID from ${CF_CERT_FILE}; rerun '${SCRIPT_NAME} init cf --relogin'"
  [ -n "$cert_api_token" ] || die "Could not read apiToken from ${CF_CERT_FILE}; rerun '${SCRIPT_NAME} init cf --relogin'"

  cert_zone_name=$(cf_zone_name_from_api "$cert_zone_id" "$cert_api_token" || true)
  [ -n "$cert_zone_name" ] || die "Could not resolve Cloudflare zone from cert; rerun '${SCRIPT_NAME} init cf --relogin'"

  if ! domain_matches_zone "$primary_domain" "$cert_zone_name"; then
    die "PRIMARY_DOMAIN '${primary_domain}' is not in logged Cloudflare zone '${cert_zone_name}'. Use '${SCRIPT_NAME} init cf --relogin'."
  fi

  log "CF" "Verified zone: ${cert_zone_name}"
}

ensure_cloudflared_login() {
  local force_relogin="${1:-0}"

  if [ "$force_relogin" -eq 1 ] && [ -f "$CF_CERT_FILE" ]; then
    rm -f "$CF_CERT_FILE"
    log "CF" "Removed existing login certificate"
  fi

  if [ -f "$CF_CERT_FILE" ]; then
    cloudflared tunnel list >/dev/null 2>&1 || die "Existing cloudflared cert is invalid: ${CF_CERT_FILE}"
    log "CF" "Using existing login certificate"
    return
  fi

  cloudflared tunnel login
  [ -f "$CF_CERT_FILE" ] || die "cloudflared login did not create ${CF_CERT_FILE}"
  cloudflared tunnel list >/dev/null 2>&1 || die "cloudflared login looks invalid; tunnel list failed"
  log "CF" "Login successful"
}

get_tunnel_id() {
  local tunnel_ref="$1"
  local info id list line

  info=$(cloudflared tunnel info "$tunnel_ref" 2>/dev/null || true)
  id=$(printf '%s\n' "$info" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)
  if [ -n "$id" ]; then
    printf '%s' "$id"
    return
  fi

  list=$(cloudflared tunnel list 2>/dev/null || true)
  line=$(printf '%s\n' "$list" | grep -E "[[:space:]]${tunnel_ref}([[:space:]]|$)" | head -n1 || true)
  id=$(printf '%s\n' "$line" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)
  printf '%s' "$id"
}

remove_stack_networks() {
  local stack_id="$1"
  local net

  if ! command -v docker >/dev/null 2>&1; then
    return
  fi

  for net in "network-${stack_id}" "network-${stack_id}-db"; do
    if docker network inspect "$net" >/dev/null 2>&1; then
      docker network rm "$net" >/dev/null 2>&1 || true
    fi
  done
}

route_dns_record() {
  local tunnel_ref="$1"
  local hostname="$2"
  local output

  output=$(cloudflared tunnel route dns --overwrite-dns "$tunnel_ref" "$hostname" 2>&1) && {
    if printf '%s' "$output" | grep -Fq "${hostname}."; then
      log "CF" "WARN: route mapped outside expected zone for ${hostname}"
      printf '%s\n' "$output" >&2
      return 2
    fi
    log "CF" "DNS route set: ${hostname}"
    return
  }

  printf '%s\n' "$output" >&2
  log "CF" "WARN: failed DNS route for ${hostname}"
  return 1
}

configure_dns_routes() {
  local tunnel_ref="$1"
  local primary_domain="$2"
  local dns_ok=1
  local zone_mismatch=0
  local rc

  route_dns_record "$tunnel_ref" "$primary_domain" || {
    rc=$?
    dns_ok=0
    if [ "$rc" -eq 2 ]; then
      zone_mismatch=1
    fi
  }
  route_dns_record "$tunnel_ref" "*.${primary_domain}" || {
    rc=$?
    dns_ok=0
    if [ "$rc" -eq 2 ]; then
      zone_mismatch=1
    fi
  }

  if [ "$dns_ok" -eq 0 ]; then
    if [ "$zone_mismatch" -eq 1 ]; then
      log "CF" "DNS routes were attempted in a different zone. Run '${SCRIPT_NAME} init cf --relogin' and select ${primary_domain}."
      return
    fi
    log "CF" "DNS route check failed; fix zone/account and rerun '${SCRIPT_NAME} init cf'"
  fi
}

ensure_network_exists() {
  local network_name="$1"
  if ! command -v docker >/dev/null 2>&1; then
    return
  fi
  if docker network inspect "$network_name" >/dev/null 2>&1; then
    return
  fi
  docker network create "$network_name" >/dev/null 2>&1 || die "Could not create docker network ${network_name}"
}

ensure_stack_networks() {
  local stack_id="$1"
  ensure_network_exists "network-${stack_id}"
  ensure_network_exists "network-${stack_id}-db"
}

is_initialized() {
  [ -f "$ENV_FILE" ] || return 1
  [ -f "$COMPOSE_FILE" ] || return 1
  [ -f "$TRAEFIK_CONFIG" ] || return 1
  [ -f "$DB_INIT" ] || return 1
  [ -f "$CF_CONFIG" ] || return 1
  [ -f "$TRAEFIK_USERS" ] || return 1

  load_env_if_exists
  [ -n "${PRIMARY_DOMAIN:-}" ] || return 1
  [ -n "${TRAEFIK_BASIC_AUTH_USER:-}" ] || return 1
  [ -n "${POSTGRES_PASSWORD:-}" ] || return 1
  return 0
}

ensure_initialized_for_cf() {
  if is_initialized; then
    log "CF" "Base init already present"
    return
  fi

  log "CF" "Base init missing; running ${SCRIPT_NAME} init first"
  init_command "--no-rename"
}

create_tunnel_and_store_token() {
  ensure_initialized_for_cf
  load_env_if_exists

  [ -n "${PRIMARY_DOMAIN:-}" ] || die "PRIMARY_DOMAIN is empty after init"
  [ -n "${STACK_ID:-}" ] || die "STACK_ID is empty after init"
  log "CF" "Using stack id: ${STACK_ID}"
  verify_primary_domain_zone "$PRIMARY_DOMAIN"

  local tunnel_name token tunnel_id create_output
  tunnel_name=$(default_tunnel_name)
  tunnel_id=$(get_tunnel_id "$tunnel_name")

  if [ -n "$tunnel_id" ]; then
    log "CF" "Tunnel found: ${tunnel_name} (${tunnel_id})"
  else
    create_output=$(cloudflared tunnel create "$tunnel_name" 2>&1) || {
      printf '%s\n' "$create_output" >&2
      die "Failed to create tunnel ${tunnel_name}"
    }
    tunnel_id=$(printf '%s\n' "$create_output" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n1 || true)
    if [ -z "$tunnel_id" ]; then
      tunnel_id=$(get_tunnel_id "$tunnel_name")
    fi
    [ -n "$tunnel_id" ] || die "Tunnel create reported success but no tunnel ID found"
    log "CF" "Tunnel created: ${tunnel_name} (${tunnel_id})"
  fi
  
  log "CF" "Tunnel target: name=${tunnel_name} id=${tunnel_id}"

  token=$(cloudflared tunnel token "$tunnel_id" 2>/dev/null | tr -d '\r\n' || true)
  if [ -z "$token" ]; then
    token=$(cloudflared tunnel token "$tunnel_name" 2>/dev/null | tr -d '\r\n' || true)
  fi
  [ -n "$token" ] || die "Could not read tunnel token"

  set_env_var "CLOUDFLARE_TUNNEL_TOKEN" "$token"
  set_env_var "CLOUDFLARE_TUNNEL_NAME" "$tunnel_name"
  set_env_var "CLOUDFLARE_TUNNEL_ID" "$tunnel_id"
  normalize_env_file
  log "CF" "Stored tunnel token in .env"

  configure_dns_routes "$tunnel_id" "$PRIMARY_DOMAIN"
}

delete_cloudflared_tunnel_if_exists() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "REBIRTH" "cloudflared not installed; skipping tunnel delete"
    return
  fi

  load_env_if_exists
  local tunnel_name="${CLOUDFLARE_TUNNEL_NAME:-$(default_tunnel_name)}"
  local tunnel_id="${CLOUDFLARE_TUNNEL_ID:-}"
  local tunnel_ref

  if [ -n "$tunnel_id" ] && cloudflared tunnel info "$tunnel_id" >/dev/null 2>&1; then
    tunnel_ref="$tunnel_id"
  elif cloudflared tunnel info "$tunnel_name" >/dev/null 2>&1; then
    tunnel_ref="$tunnel_name"
  else
    log "REBIRTH" "No tunnel found for: ${tunnel_name}"
    return
  fi

  cloudflared tunnel delete "$tunnel_ref" >/dev/null 2>&1 || true
  log "REBIRTH" "Deleted tunnel: ${tunnel_ref}"
}

ensure_structure() {
  mkdir -p ./core/traefik
  mkdir -p ./core/database
  mkdir -p ./core/cloudflared
  mkdir -p ./core/testsite
  mkdir -p ./services/postgres/data
}

generate_testsite_files() {
  local legacy_page_file="${SCRIPT_DIR}/apps/testsite/index.html"
  local page_file="${SCRIPT_DIR}/core/testsite/index.html"

  if [ -f "$legacy_page_file" ] && [ ! -f "$page_file" ]; then
    mkdir -p "${SCRIPT_DIR}/core/testsite"
    cp "$legacy_page_file" "$page_file"
  fi

  if [ -f "$page_file" ]; then
    return
  fi

  cat > "$page_file" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>test.${PRIMARY_DOMAIN}</title>
  <style>
    :root {
      --bg-0: #08111f;
      --bg-1: #13243f;
      --card: rgba(14, 24, 42, 0.78);
      --line: rgba(154, 191, 255, 0.24);
      --text: #edf4ff;
      --muted: #bdd0eb;
      --accent: #7ed9ff;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      color: var(--text);
      font-family: "Segoe UI", "Noto Sans", "Helvetica Neue", sans-serif;
      background:
        radial-gradient(900px 500px at 15% 20%, #1a3f70 0%, transparent 70%),
        radial-gradient(900px 600px at 85% 80%, #11494b 0%, transparent 72%),
        linear-gradient(145deg, var(--bg-0), var(--bg-1));
      padding: 18px;
    }

    .card {
      width: min(680px, 100%);
      border: 1px solid var(--line);
      background: var(--card);
      backdrop-filter: blur(6px);
      border-radius: 16px;
      padding: 26px 22px;
      box-shadow: 0 18px 50px rgba(0, 0, 0, 0.28);
      text-align: center;
    }

    h1 {
      margin: 0 0 10px;
      font-size: clamp(1.35rem, 2.6vw, 1.95rem);
      letter-spacing: 0.01em;
    }

    p {
      margin: 8px 0;
      line-height: 1.5;
      color: var(--muted);
      font-size: clamp(0.96rem, 2.4vw, 1.04rem);
    }

    code {
      color: var(--text);
      background: rgba(8, 17, 31, 0.72);
      border: 1px solid rgba(126, 217, 255, 0.32);
      border-radius: 8px;
      padding: 2px 8px;
      font-size: 0.95em;
    }

    .status {
      display: inline-block;
      margin-bottom: 12px;
      border-radius: 999px;
      padding: 6px 12px;
      color: #06262b;
      background: linear-gradient(90deg, #92ffe2, var(--accent));
      font-weight: 700;
      font-size: 0.82rem;
      letter-spacing: 0.02em;
    }
  </style>
</head>
<body>
  <main class="card">
    <span class="status">ONLINE</span>
    <h1>Testsite online</h1>
    <p>This page is served by the <code>testsite</code> service.</p>
    <p>Expected host: <code>test.${PRIMARY_DOMAIN}</code></p>
    <p>Active stack: <code>${STACK_ID}</code></p>
    <p>If you can open this, your tunnel + Traefik routing works.</p>
  </main>
</body>
</html>
EOF
}

write_gitignore_file() {
  cat > "${SCRIPT_DIR}/.gitignore" <<'EOF'
.env
.gitignore
# Generated security files
core/traefik/users.htpasswd
core/**
compose.yaml
# Runtime data
services/postgres/data/**
services/**
*.log
*.tmp
EOF
}

write_compose_file() {
  cat > "$COMPOSE_FILE" <<'EOF'
name: ${STACK_ID}

services:
  traefik:
    image: traefik:v3.6
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./core/traefik/traefik.yml:/traefik.yml:ro
      - ./core/traefik/users.htpasswd:/users.htpasswd:ro
    networks:
      - network-edge
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard-${STACK_ID}.rule=Host(`net.${PRIMARY_DOMAIN}`)"
      - "traefik.http.routers.dashboard-${STACK_ID}.entrypoints=web"
      - "traefik.http.routers.dashboard-${STACK_ID}.service=api@internal"
      - "traefik.http.routers.dashboard-${STACK_ID}.middlewares=dashboard-auth-${STACK_ID}"
      - "traefik.http.middlewares.dashboard-auth-${STACK_ID}.basicauth.usersfile=/users.htpasswd"

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run --token ${CLOUDFLARE_TUNNEL_TOKEN}
    volumes:
      - ./core/cloudflared/config.yml:/etc/cloudflared/config.yml:ro
    networks:
      - network-edge

  testsite:
    image: nginx:alpine
    restart: unless-stopped
    volumes:
      - ./core/testsite:/usr/share/nginx/html:ro
    networks:
      - network-edge
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.testsite-${STACK_ID}.rule=Host(`test.${PRIMARY_DOMAIN}`)"
      - "traefik.http.routers.testsite-${STACK_ID}.entrypoints=web"
      - "traefik.http.services.testsite-${STACK_ID}.loadbalancer.server.port=80"

  adminer:
    image: adminer:latest
    restart: unless-stopped
    environment:
      - ADMINER_DEFAULT_SERVER=postgres
    networks:
      - network-edge
      - network-db
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.adminer-${STACK_ID}.rule=Host(`db.${PRIMARY_DOMAIN}`)"
      - "traefik.http.routers.adminer-${STACK_ID}.entrypoints=web"
      - "traefik.http.services.adminer-${STACK_ID}.loadbalancer.server.port=8080"

  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - ./services/postgres/data:/var/lib/postgresql/data
      - ./core/database/init-databases.sh:/docker-entrypoint-initdb.d/init-databases.sh:ro
    networks:
      - network-db

networks:
  network-edge:
    external: true
    name: network-${STACK_ID}
  network-db:
    external: true
    name: network-${STACK_ID}-db
EOF
}

ensure_env_file() {
  local app_secret app_password postgres_password
  if [ ! -f "$ENV_FILE" ]; then
    app_secret=$(random_lower_alnum 100)
    app_password=$(random_lower_alnum 100)
    postgres_password=$(random_lower_alnum 69)

    cat > "$ENV_FILE" <<EOF
TZ='Europe/Amsterdam'

# Unique compose project id (used for isolation)
STACK_ID='scaleton'

# Primary domain for this stack
PRIMARY_DOMAIN='example.com'

# Cloudflare tunnel settings
CLOUDFLARE_TUNNEL_TOKEN=''
CLOUDFLARE_TUNNEL_NAME=''
CLOUDFLARE_TUNNEL_ID=''

# Traefik dashboard basic auth username
TRAEFIK_BASIC_AUTH_USER='admin'

# Postgres base credentials
POSTGRES_DB='scaleton_db'
POSTGRES_USER='admin'
POSTGRES_PASSWORD='${postgres_password}'

# App credentials
APP_SECRET='${app_secret}'
APP_PASSWORD='${app_password}'
EOF

    chmod 600 "$ENV_FILE"
    log "INIT" ".env created"
  fi

  normalize_env_file
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
    printf '\n' >&2
    read -r -s -p "Confirm ${prompt}: " second
    printf '\n' >&2
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
  cat > "$TRAEFIK_CONFIG" <<EOF
# Traefik static configuration (generated by setup.sh)

api:
  dashboard: true

entryPoints:
  web:
    address: ":80"
    forwardedHeaders:
      trustedIPs:
        - "10.0.0.0/8"
        - "172.16.0.0/12"
        - "192.168.0.0/16"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: network-${stack_id}
    constraints: "Label(\`com.docker.compose.project\`,\`${stack_id}\`)"

log:
  level: WARN
EOF
}

generate_db_init_template() {
  cat > "$DB_INIT" <<'EOF'
#!/usr/bin/env bash
set -e

# Generated by setup.sh.
# Add CREATE USER / CREATE DATABASE statements for your services.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Example:
    -- CREATE USER app_user WITH PASSWORD 'change_me';
    -- CREATE DATABASE app_db;
    -- GRANT ALL PRIVILEGES ON DATABASE app_db TO app_user;
    -- ALTER DATABASE app_db OWNER TO app_user;
EOSQL
EOF
  chmod +x "$DB_INIT"
}

generate_cloudflared_config() {
  local primary_domain="$1"
  cat > "$CF_CONFIG" <<EOF
ingress:
  - hostname: ${primary_domain}
    service: http://traefik:80
  - hostname: "*.${primary_domain}"
    service: http://traefik:80
  - service: http_status:404
EOF
}

render_base_files() {
  ensure_structure
  generate_testsite_files
  write_gitignore_file
  write_compose_file
  generate_traefik_config "${STACK_ID}"
  generate_db_init_template
  generate_cloudflared_config "${PRIMARY_DOMAIN}"
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

  for key in STACK_ID PRIMARY_DOMAIN TRAEFIK_BASIC_AUTH_USER POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
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

  ensure_stack_networks "$STACK_ID"
  render_base_files

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

gen_secret() {
  random_lower_alnum 100
}

env_command() {
  [ -f "$ENV_FILE" ] || die "Missing .env. Run ${SCRIPT_NAME} init first."
  local tmp
  tmp=$(mktemp)

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z0-9_]+)= ]]; then
      local key
      key="${BASH_REMATCH[1]}"
      if [[ "$key" == *_SECRET ]]; then
        local secret
        secret=$(gen_secret)
        printf "%s=%s\n" "$key" "$(shell_quote "$secret")" >> "$tmp"
        log "ENV" "Regenerated ${key}"
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$ENV_FILE"

  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  normalize_env_file
  log "ENV" "Secret rotation complete"
}

reset_command() {
  local target="${1:-}"
  case "$target" in
    trae|traefik|traefik-password)
      load_env
      local password
      password=$(prompt_secret "New Traefik dashboard password")
      generate_traefik_htpasswd "${TRAEFIK_BASIC_AUTH_USER}" "$password"
      log "RESET" "Traefik password updated"
      ;;
    database)
      load_env
      local db_password
      db_password=$(prompt_secret "New database password")
      set_env_var "POSTGRES_PASSWORD" "$db_password"
      normalize_env_file
      log "RESET" "Database password updated in .env"
      ;;
    *)
      die "Usage: ${SCRIPT_NAME} reset <database|trae>"
      ;;
  esac
}

reborn_command() {
  local force="${1:-}"

  if [ "$force" != "--yes" ] && [ "$force" != "--fuckit" ]; then
    local confirmation
    read -r -p "This removes generated files. Type 'reborn' to continue: " confirmation
    [ "$confirmation" = "reborn" ] || die "Cancelled"
  fi

  if command -v docker >/dev/null 2>&1 && [ -f "${SCRIPT_DIR}/compose.yaml" ]; then
    docker compose down --remove-orphans >/dev/null 2>&1 || true
  fi

  load_env_if_exists
  if [ -n "${STACK_ID:-}" ]; then
    remove_stack_networks "$STACK_ID"
  fi

  delete_cloudflared_tunnel_if_exists

  shopt -s dotglob nullglob
  local path base keep_name
  keep_name="$(basename "$0")"
  for path in "${SCRIPT_DIR}"/*; do
    base="$(basename "$path")"
    if [ "$base" = ".git" ] || [ "$base" = "$keep_name" ] || [ "$base" = "README.md" ] || [ "$base" = "LICENSE" ]; then
      continue
    fi
    rm -rf "$path"
  done
  shopt -u dotglob nullglob

  log "REBIRTH" "Project fully reset. Kept: ${keep_name}, README.md, .git, LICENSE"
}

init_command() {
  local mode="${1:-}"
  local do_rename=1
  if [ "$mode" = "--no-rename" ]; then
    do_rename=0
  elif [ -n "$mode" ]; then
    die "Usage: ${SCRIPT_NAME} init"
  fi

  ensure_env_file
  load_env

  local stack_id domain tz token_user token_password
  local postgres_db postgres_user postgres_password
  local app_secret app_password
  stack_id=$(prompt_value "Stack ID (unique project id)" "${STACK_ID:-scaleton}")
  domain=$(prompt_value "Primary domain" "${PRIMARY_DOMAIN:-example.com}")
  tz=$(prompt_value "Timezone" "${TZ:-Europe/Amsterdam}")
  token_user="admin"
  token_password=$(prompt_secret "Traefik dashboard password")
  postgres_db="${stack_id}_db"
  postgres_user="admin"
  postgres_password=$(random_lower_alnum 69)

  app_secret=$(random_lower_alnum 100)
  app_password=$(random_lower_alnum 100)

  set_env_var "STACK_ID" "$stack_id"
  set_env_var "PRIMARY_DOMAIN" "$domain"
  set_env_var "TZ" "$tz"
  set_env_var "TRAEFIK_BASIC_AUTH_USER" "$token_user"
  set_env_var "POSTGRES_DB" "$postgres_db"
  set_env_var "POSTGRES_USER" "$postgres_user"
  set_env_var "POSTGRES_PASSWORD" "$postgres_password"
  set_env_var "APP_SECRET" "$app_secret"
  set_env_var "APP_PASSWORD" "$app_password"
  normalize_env_file

  load_env
  ensure_stack_networks "$STACK_ID"
  render_base_files
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
  echo "- Generated: .gitignore"

  if [ "$do_rename" -eq 1 ]; then
    prompt_directory_rename
  fi
}

init_cf_command() {
  local relogin_flag="${1:-}"
  local force_relogin=0

  if [ "$relogin_flag" = "--relogin" ]; then
    force_relogin=1
  elif [ -n "$relogin_flag" ]; then
    die "Usage: ${SCRIPT_NAME} init cf [--relogin]"
  fi

  ensure_cloudflared
  ensure_cloudflared_login "$force_relogin"
  create_tunnel_and_store_token
  log "CF" "Cloudflared tunnel init complete"
}

print_help() {
  cat <<EOF
Usage: ${SCRIPT_NAME} <command> [opts]

Commands:
  init                         Interactive bootstrap for skeleton stack
  init cf [--relogin]          Install/login cloudflared and store tunnel token
  env                          Regenerate values for every *_SECRET key in .env
  validate                     Validate .env and docker compose config
  reset <database|trae>        Reset database password or Traefik password
  reborn [--yes|--fuckit]      Remove generated files, keep setup.sh README.md .git LICENSE
  help | -h                    Show this help
EOF
}

main() {
  case "${1:-}" in
    init)
      case "${2:-}" in
        "")
          init_command
          ;;
        env)
          env_command
          ;;
        cf)
          init_cf_command "${3:-}"
          ;;
        *)
          die "Usage: ${SCRIPT_NAME} init [cf|env]"
          ;;
      esac
      ;;
    env)
      env_command
      ;;
    validate)
      validate_stack
      ;;
    reset)
      shift
      reset_command "$@"
      ;;
    reborn)
      shift
      reborn_command "$@"
      ;;
    help|-h|"")
      print_help
      ;;
    *)
      die "Unknown command: ${1}. Use -h."
      ;;
  esac
}

main "$@"
