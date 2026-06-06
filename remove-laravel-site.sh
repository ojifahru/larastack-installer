#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
SITE_PATH=""
SITE_USER=""
PHP_VERSION=""
PHP_SOCKET=""
PHP_POOL_FILE=""
NGINX_FILE=""
DELETE_FILES=false
DELETE_DB=false
DELETE_USER=false
DELETE_SSL=false
DB_NAME=""
DB_USER=""
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash remove-laravel-site.sh
  sudo bash remove-laravel-site.sh --domain=example.com [options]

Options:
  --interactive       Ask removal questions
  --domain=example.com
  --path=/home/example/public_html
  --site-user=example
  --php=8.3
  --delete-files      Delete project folder after explicit typed confirmation
  --delete-db         Drop database and user after explicit typed confirmation
  --db-name=name
  --db-user=user
  --delete-user       Delete Linux site user after explicit typed confirmation
  --delete-ssl        Delete Let's Encrypt certificate after explicit typed confirmation
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --site-user=*) SITE_USER="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --delete-files) DELETE_FILES=true ;;
    --delete-db) DELETE_DB=true ;;
    --db-name=*) DB_NAME="${arg#*=}" ;;
    --db-user=*) DB_USER="${arg#*=}" ;;
    --delete-user) DELETE_USER=true ;;
    --delete-ssl) DELETE_SSL=true ;;
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

domain_to_identifier() {
  local value="$1"
  value="${value//./_}"
  value="${value//-/_}"
  value="${value//[^A-Za-z0-9_]/_}"
  printf '%s' "$value"
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

pool_file_from_socket() {
  local socket="$1"
  local php_version="$2"
  local site_user="$3"
  local file

  if [[ -n "$php_version" && -n "$site_user" && -f "/etc/php/${php_version}/fpm/pool.d/${site_user}.conf" ]]; then
    printf '%s' "/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"
    return
  fi

  if [[ -n "$socket" && -n "$php_version" && -d "/etc/php/${php_version}/fpm/pool.d" ]]; then
    file="$(grep -RslF "listen = ${socket}" "/etc/php/${php_version}/fpm/pool.d" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$file" ]]; then
      printf '%s' "$file"
      return
    fi
  fi

  if [[ -n "$site_user" ]]; then
    for file in /etc/php/*/fpm/pool.d/"${site_user}".conf; do
      [[ -f "$file" ]] || continue
      printf '%s' "$file"
      return
    done
  fi
}

env_value() {
  local file="$1"
  local key="$2"
  local value

  [[ -f "$file" ]] || return 0
  value="$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true)"
  value="$(printf '%s' "$value" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  printf '%s' "$value"
}

load_db_defaults() {
  local credential_file=""
  local env_file=""

  if [[ -n "$DOMAIN" ]]; then
    credential_file="/root/laravel-deploy/credentials/${DOMAIN}.db.env"
  fi

  if [[ -n "$credential_file" && -f "$credential_file" ]]; then
    [[ -n "$DB_NAME" ]] || DB_NAME="$(env_value "$credential_file" "DB_NAME")"
    [[ -n "$DB_USER" ]] || DB_USER="$(env_value "$credential_file" "DB_USER")"
  fi

  if [[ -n "$SITE_PATH" ]]; then
    env_file="${SITE_PATH}/.env"
  fi

  if [[ -f "$env_file" ]]; then
    [[ -n "$DB_NAME" ]] || DB_NAME="$(env_value "$env_file" "DB_DATABASE")"
    [[ -n "$DB_USER" ]] || DB_USER="$(env_value "$env_file" "DB_USERNAME")"
  fi
}

detect_site_context() {
  local server_names root_path detected_php detected_user

  if [[ -z "$NGINX_FILE" ]]; then
    NGINX_FILE="$(find_nginx_site_by_domain)"
  fi
  if [[ -z "$NGINX_FILE" ]]; then
    NGINX_FILE="$(find_nginx_site_by_path)"
  fi

  if [[ -n "$NGINX_FILE" && -f "$NGINX_FILE" ]]; then
    server_names="$(nginx_directive "server_name" "$NGINX_FILE" | tr -d ';')"
    root_path="$(nginx_directive "root" "$NGINX_FILE")"
    PHP_SOCKET="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$NGINX_FILE" | head -n 1)"

    [[ -n "$DOMAIN" ]] || DOMAIN="$(awk '{print $1}' <<<"$server_names")"
    [[ -n "$SITE_PATH" || -z "$root_path" ]] || SITE_PATH="$(project_path_from_root "$root_path")"

    detected_php="$(php_version_from_socket "$PHP_SOCKET")"
    if [[ -z "$PHP_VERSION" && -n "$detected_php" ]]; then
      PHP_VERSION="$detected_php"
    fi

    detected_user="$(site_user_from_socket "$PHP_SOCKET" "${PHP_VERSION:-$detected_php}")"
    if [[ -z "$SITE_USER" && -n "$detected_user" ]]; then
      SITE_USER="$detected_user"
    fi
  fi

  if [[ -z "$SITE_USER" && -n "$SITE_PATH" && -e "$SITE_PATH" ]]; then
    SITE_USER="$(stat -c '%U' "$SITE_PATH" 2>/dev/null || true)"
  fi

  if [[ -z "$PHP_POOL_FILE" ]]; then
    PHP_POOL_FILE="$(pool_file_from_socket "$PHP_SOCKET" "$PHP_VERSION" "$SITE_USER")"
  fi

  if [[ -z "$PHP_VERSION" && "$PHP_POOL_FILE" =~ /etc/php/([^/]+)/fpm/pool.d/ ]]; then
    PHP_VERSION="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$PHP_SOCKET" && -f "$PHP_POOL_FILE" ]]; then
    PHP_SOCKET="$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$PHP_POOL_FILE" | head -n 1)"
  fi

  load_db_defaults
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel site removal wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_required "Domain site yang akan dihapus" "$DOMAIN")"
  detect_site_context

  if [[ "$DELETE_FILES" != true ]] && prompt_yes_no "Hapus folder project juga?" "n"; then
    DELETE_FILES=true
  fi
  if [[ "$DELETE_FILES" == true ]]; then
    SITE_PATH="$(prompt_required "Path project yang akan dihapus" "$SITE_PATH")"
  fi

  if [[ "$DELETE_DB" != true ]] && prompt_yes_no "Hapus database dan user MariaDB juga?" "n"; then
    DELETE_DB=true
  fi
  if [[ "$DELETE_DB" == true ]]; then
    local db_base
    db_base="$(domain_to_identifier "$DOMAIN")"
    [[ -n "$DB_NAME" ]] || DB_NAME="${db_base}_db"
    [[ -n "$DB_USER" ]] || DB_USER="${db_base}_user"
    DB_NAME="$(prompt_required "Nama database yang akan dihapus" "$DB_NAME")"
    DB_USER="$(prompt_required "User database yang akan dihapus" "$DB_USER")"
  fi

  if [[ "$DELETE_USER" != true ]] && prompt_yes_no "Hapus Linux site user juga?" "n"; then
    DELETE_USER=true
  fi
  if [[ "$DELETE_USER" == true ]]; then
    SITE_USER="$(prompt_required "Linux site user yang akan dihapus" "$SITE_USER")"
  fi

  if [[ "$DELETE_SSL" != true ]] && prompt_yes_no "Hapus SSL certificate Let's Encrypt juga?" "n"; then
    DELETE_SSL=true
  fi

  cat > /dev/tty <<EOF

Ringkasan removal:
  domain:       ${DOMAIN}
  nginx file:   ${NGINX_FILE:-"/etc/nginx/sites-available/${DOMAIN}"}
  PHP-FPM pool: ${PHP_POOL_FILE:-"-"}
  site user:    ${SITE_USER:-"-"}
  project path: ${SITE_PATH:-"-"}
  delete files: ${DELETE_FILES}
  delete db:    ${DELETE_DB}
  db name:      ${DB_NAME:-"-"}
  db user:      ${DB_USER:-"-"}
  delete user:  ${DELETE_USER}
  delete SSL:   ${DELETE_SSL}

EOF

  if ! prompt_yes_no "Lanjut remove site sekarang?" "n"; then
    error "Removal cancelled"
  fi
}

safe_delete_path() {
  [[ -n "$SITE_PATH" && "$SITE_PATH" == /* ]] || return 1
  [[ "$SITE_PATH" != *".."* ]] || return 1

  case "$SITE_PATH" in
    /|/home|/home/|/var|/var/|/var/www|/var/www/|/etc|/etc/|/root|/root/|/usr|/usr/|/opt|/opt/)
      return 1
      ;;
  esac

  [[ "$SITE_PATH" == /home/*/public_html || "$SITE_PATH" == /var/www/* ]]
}

validate_input() {
  detect_site_context

  [[ -n "$DOMAIN" ]] || error "--domain is required, or supply --path for auto-detect"
  validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"

  if [[ -n "$SITE_PATH" ]]; then
    [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  fi

  if [[ -n "$PHP_VERSION" ]]; then
    [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  fi

  if [[ "$DELETE_FILES" == true ]]; then
    [[ -n "$SITE_PATH" ]] || error "--path could not be detected; provide --path before using --delete-files"
    safe_delete_path || error "Refusing to delete unsafe project path: $SITE_PATH"
  fi

  if [[ "$DELETE_DB" == true ]]; then
    [[ -n "$DB_NAME" ]] || error "--db-name is required with --delete-db"
    [[ -n "$DB_USER" ]] || error "--db-user is required with --delete-db"
    [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-name may only contain letters, numbers, and underscore"
    [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-user may only contain letters, numbers, and underscore"
  fi

  if [[ "$DELETE_USER" == true ]]; then
    [[ -n "$SITE_USER" ]] || error "--site-user could not be detected; provide --site-user before using --delete-user"
    [[ "$SITE_USER" != "root" && "$SITE_USER" != "www-data" ]] || error "Refusing to delete protected user: $SITE_USER"
  fi
}

confirm_or_skip() {
  local expected="$1"
  local prompt="$2"
  local answer

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s\n' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty
  else
    printf '%s\n' "$prompt"
    IFS= read -r answer
  fi

  [[ "$answer" == "$expected" ]]
}

reload_nginx_if_available() {
  if ! command -v nginx >/dev/null 2>&1; then
    warn "Nginx command not found; skipping reload"
    return
  fi

  nginx -t
  systemctl reload nginx
}

disable_nginx_site() {
  local available="${NGINX_FILE:-/etc/nginx/sites-available/${DOMAIN}}"
  local enabled="/etc/nginx/sites-enabled/$(basename "$available")"
  local linked

  info "Removing Nginx site for $DOMAIN"

  if [[ -e "$enabled" || -L "$enabled" ]]; then
    rm -f "$enabled"
  fi

  for linked in /etc/nginx/sites-enabled/*; do
    [[ -L "$linked" ]] || continue
    if [[ "$(readlink -f "$linked")" == "$(readlink -f "$available" 2>/dev/null || true)" ]]; then
      rm -f "$linked"
    fi
  done

  if [[ -f "$available" ]]; then
    rm -f "$available"
    success "Removed $available"
  else
    warn "Nginx site file not found: $available"
  fi

  reload_nginx_if_available
}

remove_php_fpm_pool() {
  if [[ -z "$PHP_POOL_FILE" ]]; then
    info "No per-site PHP-FPM pool detected for $DOMAIN"
    return
  fi

  if [[ ! -f "$PHP_POOL_FILE" ]]; then
    warn "PHP-FPM pool file not found: $PHP_POOL_FILE"
    return
  fi

  info "Removing PHP-FPM pool: $PHP_POOL_FILE"
  rm -f "$PHP_POOL_FILE"

  if [[ -n "$PHP_VERSION" ]]; then
    systemctl restart "php${PHP_VERSION}-fpm"
    systemctl is-active --quiet "php${PHP_VERSION}-fpm"
  fi

  success "PHP-FPM pool removed"
}

queue_conf_file() {
  local conf="/etc/supervisor/conf.d/${DOMAIN}-queue.conf"
  local found

  if [[ -f "$conf" ]]; then
    printf '%s' "$conf"
    return
  fi

  if [[ -n "$SITE_PATH" && -d /etc/supervisor/conf.d ]]; then
    found="$(grep -RslF "directory=${SITE_PATH}" /etc/supervisor/conf.d/*.conf 2>/dev/null | head -n 1 || true)"
    [[ -n "$found" ]] && printf '%s' "$found"
  fi
}

remove_supervisor_queue() {
  local conf program_name
  conf="$(queue_conf_file)"

  if [[ -z "$conf" || ! -f "$conf" ]]; then
    info "No Supervisor queue config found for $DOMAIN"
    return
  fi

  if ! command -v supervisorctl >/dev/null 2>&1; then
    warn "supervisorctl not found; removing config file only"
    rm -f "$conf"
    return
  fi

  program_name="$(basename "$conf" .conf)"
  info "Removing Supervisor queue config: $conf"
  supervisorctl stop "${program_name}:*" || true
  rm -f "$conf"
  supervisorctl reread
  supervisorctl update
  success "Supervisor queue removed"
}

delete_ssl_if_requested() {
  if [[ "$DELETE_SSL" != true ]]; then
    return
  fi

  local expected="DELETE SSL ${DOMAIN}"
  if ! confirm_or_skip "$expected" "Type '${expected}' to delete Let's Encrypt certificate for ${DOMAIN}:"; then
    warn "SSL certificate deletion skipped"
    return
  fi

  if ! command -v certbot >/dev/null 2>&1; then
    warn "certbot not found; SSL certificate was not deleted"
    return
  fi

  if ! certbot certificates --cert-name "$DOMAIN" >/dev/null 2>&1; then
    warn "No certbot certificate found with cert-name ${DOMAIN}"
    return
  fi

  certbot delete --cert-name "$DOMAIN" --non-interactive
  success "SSL certificate deleted for $DOMAIN"
}

delete_files_if_requested() {
  if [[ "$DELETE_FILES" != true ]]; then
    return
  fi

  if [[ ! -d "$SITE_PATH" ]]; then
    warn "Project path not found: $SITE_PATH"
    return
  fi

  local expected="DELETE FILES ${DOMAIN}"
  if confirm_or_skip "$expected" "Type '${expected}' to delete ${SITE_PATH}:"; then
    rm -rf --one-file-system "$SITE_PATH"
    success "Deleted $SITE_PATH"
  else
    warn "File deletion skipped"
  fi
}

delete_database_if_requested() {
  if [[ "$DELETE_DB" != true ]]; then
    return
  fi

  local expected="DELETE DB ${DB_NAME}"
  if confirm_or_skip "$expected" "Type '${expected}' to drop database ${DB_NAME} and user ${DB_USER}:"; then
    mysql <<SQL
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    rm -f "/root/laravel-deploy/credentials/${DOMAIN}.db.env"
    success "Database and user removed"
  else
    warn "Database deletion skipped"
  fi
}

delete_site_user_if_requested() {
  if [[ "$DELETE_USER" != true ]]; then
    return
  fi

  if ! id "$SITE_USER" >/dev/null 2>&1; then
    warn "Linux user not found: $SITE_USER"
    return
  fi

  local expected="DELETE USER ${SITE_USER}"
  if confirm_or_skip "$expected" "Type '${expected}' to delete Linux user ${SITE_USER}:"; then
    userdel "$SITE_USER"
    success "Linux user deleted: $SITE_USER"
  else
    warn "Linux user deletion skipped"
  fi
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  remove_supervisor_queue
  disable_nginx_site
  remove_php_fpm_pool
  delete_ssl_if_requested
  delete_database_if_requested
  delete_files_if_requested
  delete_site_user_if_requested
  success "Removal complete for $DOMAIN"
}

main "$@"
