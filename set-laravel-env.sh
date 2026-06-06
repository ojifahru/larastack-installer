#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
SITE_PATH=""
SITE_USER=""
PHP_VERSION=""
KEY=""
VALUE=""
VALUE_PROVIDED=false
CLEAR_CONFIG=false
CACHE_CONFIG=false
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash set-laravel-env.sh
  sudo bash set-laravel-env.sh --domain=example.com --key=APP_DEBUG --value=false [options]

Options:
  --interactive
  --domain=example.com
  --path=/home/example/public_html
  --site-user=example
  --php=8.3
  --key=APP_NAME
  --value='My App'
  --clear-config       Run php artisan config:clear after update
  --cache-config       Run php artisan config:cache after update
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --site-user=*) SITE_USER="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --key=*) KEY="${arg#*=}" ;;
    --value=*) VALUE="${arg#*=}"; VALUE_PROVIDED=true ;;
    --clear-config) CLEAR_CONFIG=true ;;
    --cache-config) CACHE_CONFIG=true ;;
    --interactive) INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage; exit 1 ;;
  esac
done

if (( EUID != 0 )); then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  echo "Run this script as root or with sudo." >&2
  exit 1
fi

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
success() { printf '[OK] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

is_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

prompt_text() {
  local prompt="$1"
  local default_value="${2:-}"
  local value

  if [[ -n "$default_value" ]]; then
    printf '%s' "${prompt} [${default_value}]: " > /dev/tty
  else
    printf '%s' "${prompt}: " > /dev/tty
  fi

  IFS= read -r value < /dev/tty

  if [[ -n "$default_value" ]]; then
    printf '%s' "${value:-$default_value}"
  else
    printf '%s' "$value"
  fi
}

prompt_required() {
  local prompt="$1"
  local default_value="${2:-}"
  local value

  while true; do
    value="$(prompt_text "$prompt" "$default_value")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    warn "Value is required"
  done
}

prompt_yes_no() {
  local prompt="$1"
  local default_value="${2:-n}"
  local suffix="[y/N]"
  local answer

  if [[ "$default_value" == "y" ]]; then
    suffix="[Y/n]"
  fi

  while true; do
    printf '%s' "${prompt} ${suffix}: " > /dev/tty
    IFS= read -r answer < /dev/tty
    answer="${answer:-$default_value}"

    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "Answer y or n" ;;
    esac
  done
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
  [[ "$value" != *".."* ]] || return 1
}

nginx_directive() {
  local directive="$1"
  local file="$2"
  sed -nE "s/^[[:space:]]*${directive}[[:space:]]+([^;]+);.*/\1/p" "$file" | head -n 1
}

project_path_from_root() {
  local root_path="$1"
  if [[ "$root_path" == */public ]]; then
    printf '%s' "${root_path%/public}"
  else
    printf '%s' "$root_path"
  fi
}

php_version_from_socket() {
  local socket="$1"
  grep -oE 'php[0-9]+\.[0-9]+' <<<"$socket" 2>/dev/null | head -n 1 | sed 's/^php//' || true
}

site_user_from_socket() {
  local socket="$1"
  local php_version="$2"
  sed -nE "s#^/run/php/php${php_version}-fpm-([A-Za-z0-9._-]+)\.sock\$#\1#p" <<<"$socket"
}

find_nginx_site_by_domain() {
  local file server_names
  [[ -n "$DOMAIN" ]] || return 0

  for file in /etc/nginx/sites-available/*; do
    [[ -f "$file" ]] || continue
    server_names="$(nginx_directive "server_name" "$file" | tr -d ';')"
    if [[ " ${server_names} " == *" ${DOMAIN} "* ]]; then
      printf '%s' "$file"
      return
    fi
  done
}

find_nginx_site_by_path() {
  local file root_path project_path
  [[ -n "$SITE_PATH" ]] || return 0

  for file in /etc/nginx/sites-available/*; do
    [[ -f "$file" ]] || continue
    root_path="$(nginx_directive "root" "$file")"
    project_path="$(project_path_from_root "$root_path")"
    if [[ "$project_path" == "$SITE_PATH" ]]; then
      printf '%s' "$file"
      return
    fi
  done
}

default_site_path() {
  local file root_path
  file="$(find /etc/nginx/sites-available -maxdepth 1 -type f ! -name default 2>/dev/null | sort | head -n 1 || true)"
  if [[ -n "$file" ]]; then
    root_path="$(nginx_directive "root" "$file")"
    project_path_from_root "$root_path"
    return
  fi

  if [[ -d /home ]]; then
    find /home -mindepth 2 -maxdepth 2 -type d -name public_html 2>/dev/null | sort | head -n 1 || true
  fi
}

detect_site_context() {
  local nginx_file="" server_names root_path socket detected_php detected_user

  nginx_file="$(find_nginx_site_by_domain)"
  if [[ -z "$nginx_file" ]]; then
    nginx_file="$(find_nginx_site_by_path)"
  fi

  if [[ -n "$nginx_file" ]]; then
    server_names="$(nginx_directive "server_name" "$nginx_file" | tr -d ';')"
    root_path="$(nginx_directive "root" "$nginx_file")"
    socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$nginx_file" | head -n 1)"

    [[ -n "$DOMAIN" ]] || DOMAIN="$(awk '{print $1}' <<<"$server_names")"
    [[ -n "$SITE_PATH" ]] || SITE_PATH="$(project_path_from_root "$root_path")"

    detected_php="$(php_version_from_socket "$socket")"
    [[ -n "$PHP_VERSION" || -z "$detected_php" ]] || PHP_VERSION="$detected_php"

    detected_user="$(site_user_from_socket "$socket" "${PHP_VERSION:-$detected_php}")"
    [[ -n "$SITE_USER" || -z "$detected_user" ]] || SITE_USER="$detected_user"
  fi

  if [[ -z "$SITE_USER" && -n "$SITE_PATH" && -e "$SITE_PATH" ]]; then
    SITE_USER="$(stat -c '%U' "$SITE_PATH" 2>/dev/null || true)"
  fi

  [[ -n "$PHP_VERSION" ]] || PHP_VERSION="8.3"
}

env_value() {
  local value="$1"

  if [[ "$value" =~ ^[A-Za-z0-9_./:@+-]*$ ]]; then
    printf '%s' "$value"
    return
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

set_env_key() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*" key "=" {
      print key "=" value
      found=1
      next
    }
    { print }
    END {
      if (!found) {
        print key "=" value
      }
    }
  ' "$env_file" > "$tmp"

  install -m 0600 "$tmp" "$env_file"
  rm -f "$tmp"
  chown "$SITE_USER:$SITE_USER" "$env_file"
}

php_bin() {
  if command -v "php${PHP_VERSION}" >/dev/null 2>&1; then
    command -v "php${PHP_VERSION}"
    return
  fi

  command -v php >/dev/null 2>&1 || error "PHP binary not found"
  command -v php
}

run_artisan_config() {
  local php_bin_value
  php_bin_value="$(php_bin)"

  if [[ ! -f "${SITE_PATH}/artisan" ]]; then
    warn "artisan not found; skipping Laravel config command"
    return
  fi

  if [[ "$CLEAR_CONFIG" == true ]]; then
    info "Running artisan config:clear as ${SITE_USER}"
    sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" artisan config:clear' bash "$SITE_PATH" "$php_bin_value"
  fi

  if [[ "$CACHE_CONFIG" == true ]]; then
    info "Running artisan config:cache as ${SITE_USER}"
    sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" artisan config:cache' bash "$SITE_PATH" "$php_bin_value"
  fi
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain/--path, --key, and --value for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel .env editor wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_text "Domain site. Kosongkan jika pakai path" "$DOMAIN")"
  detect_site_context

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="$(default_site_path)"
  fi

  SITE_PATH="$(prompt_required "Path project Laravel" "$SITE_PATH")"
  detect_site_context
  SITE_USER="$(prompt_required "Site user" "$SITE_USER")"
  PHP_VERSION="$(prompt_required "Versi PHP" "$PHP_VERSION")"
  KEY="$(prompt_required "Nama key .env" "$KEY")"
  VALUE="$(prompt_text "Value .env" "$VALUE")"
  VALUE_PROVIDED=true

  if [[ "$CLEAR_CONFIG" != true ]] && prompt_yes_no "Jalankan artisan config:clear setelah update?" "y"; then
    CLEAR_CONFIG=true
  fi

  if [[ "$CACHE_CONFIG" != true ]] && prompt_yes_no "Jalankan artisan config:cache setelah update?" "n"; then
    CACHE_CONFIG=true
  fi

  cat > /dev/tty <<EOF

Ringkasan update .env:
  domain:    ${DOMAIN:-"-"}
  path:      ${SITE_PATH}
  site user: ${SITE_USER}
  PHP:       ${PHP_VERSION}
  key:       ${KEY}
  clear:     ${CLEAR_CONFIG}
  cache:     ${CACHE_CONFIG}

EOF

  if ! prompt_yes_no "Lanjut update .env sekarang?" "y"; then
    error ".env update cancelled"
  fi
}

validate_input() {
  detect_site_context

  if [[ -n "$DOMAIN" ]]; then
    validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"
  fi

  [[ -n "$SITE_PATH" ]] || error "--path is required, or supply --domain for auto-detect"
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  [[ -d "$SITE_PATH" ]] || error "Project path not found: $SITE_PATH"
  [[ -n "$SITE_USER" ]] || error "Could not detect site user. Use --site-user=example."
  id "$SITE_USER" >/dev/null 2>&1 || error "Site user does not exist: $SITE_USER"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  [[ -n "$KEY" ]] || error "--key is required"
  [[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || error "--key must be a valid .env key"
  [[ "$INTERACTIVE" == true || "$VALUE_PROVIDED" == true ]] || error "--value is required; use --value= to set an empty value"
  [[ "$CLEAR_CONFIG" != true || "$CACHE_CONFIG" != true ]] || warn "Both --clear-config and --cache-config supplied; clear will run before cache"
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input

  local env_file="${SITE_PATH}/.env"
  [[ -f "$env_file" ]] || error ".env not found: $env_file"

  cp -a "$env_file" "${env_file}.bak.$(date +%Y%m%d%H%M%S)"
  set_env_key "$env_file" "$KEY" "$(env_value "$VALUE")"
  chmod 0600 "$env_file"
  chown "$SITE_USER:$SITE_USER" "$env_file"

  success "Updated ${KEY} in ${env_file}"
  run_artisan_config
}

main "$@"
