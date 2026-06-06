#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
BACKUP_PATH=""
BACKUP_ROOT="/root/backups/laravel"
YES=false
SKIP_DB=false
SKIP_ENV=false
SKIP_STORAGE=false
SKIP_CONFIG=false
INTERACTIVE=false

RESTORE_TS=""
PROJECT_PATH=""
NGINX_FILE=""
PHP_VERSION=""
SITE_USER=""
PHP_FPM_POOL=""
DB_NAME=""
DB_USER=""
DB_PASS=""
APP_URL=""

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash restore-laravel-site.sh
  sudo bash restore-laravel-site.sh --domain=example.com
  sudo bash restore-laravel-site.sh --backup=/root/backups/laravel/example.com/YYYYMMDDHHMMSS

Options:
  --interactive
  --domain=example.com
  --backup=/path/to/backup
  --backup-root=/root/backups/laravel
  --yes
  --skip-db
  --skip-env
  --skip-storage
  --skip-config
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --backup=*) BACKUP_PATH="${arg#*=}" ;;
    --backup-root=*) BACKUP_ROOT="${arg#*=}" ;;
    --yes) YES=true ;;
    --skip-db) SKIP_DB=true ;;
    --skip-env) SKIP_ENV=true ;;
    --skip-storage) SKIP_STORAGE=true ;;
    --skip-config) SKIP_CONFIG=true ;;
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

safe_domain_dir_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/-}"
  printf '%s' "$value"
}

manifest_get() {
  local key="$1"
  local file="${BACKUP_PATH}/manifest.env"
  local value=""

  [[ -f "$file" ]] || return 0
  value="$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true)"
  printf '%s' "$value"
}

env_get_from_file() {
  local file="$1"
  local key="$2"
  local value=""

  [[ -f "$file" ]] || return 0
  value="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1 | cut -d= -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

sql_escape() {
  sed "s/'/''/g" <<<"$1"
}

backup_existing_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.restore-bak.${RESTORE_TS}"
  fi
}

home_dir_for_site_user() {
  if [[ -n "$SITE_USER" && "$PROJECT_PATH" == "/home/${SITE_USER}/"* ]]; then
    printf '/home/%s' "$SITE_USER"
  elif [[ -n "$SITE_USER" ]]; then
    printf '/home/%s' "$SITE_USER"
  fi
}

ensure_site_user() {
  local home_dir
  [[ -n "$SITE_USER" ]] || return

  home_dir="$(home_dir_for_site_user)"
  if id "$SITE_USER" >/dev/null 2>&1; then
    success "Linux user already exists: $SITE_USER"
    return
  fi

  info "Creating Linux user for restored site: $SITE_USER"
  useradd --create-home --home-dir "$home_dir" --shell /bin/bash "$SITE_USER"
  chmod 0755 "$home_dir"
}

load_backup_context() {
  local env_backup="${BACKUP_PATH}/env/.env"

  [[ -f "${BACKUP_PATH}/manifest.env" ]] || error "manifest.env not found in backup: $BACKUP_PATH"

  DOMAIN="${DOMAIN:-$(manifest_get DOMAIN)}"
  PROJECT_PATH="$(manifest_get PROJECT_PATH)"
  NGINX_FILE="$(manifest_get NGINX_FILE)"
  PHP_VERSION="$(manifest_get PHP_VERSION)"
  SITE_USER="$(manifest_get SITE_USER)"
  PHP_FPM_POOL="$(manifest_get PHP_FPM_POOL)"
  DB_NAME="$(manifest_get DB_DATABASE)"
  APP_URL="$(manifest_get APP_URL)"

  if [[ -f "$env_backup" ]]; then
    [[ -n "$DB_NAME" ]] || DB_NAME="$(env_get_from_file "$env_backup" "DB_DATABASE")"
    DB_USER="$(env_get_from_file "$env_backup" "DB_USERNAME")"
    DB_PASS="$(env_get_from_file "$env_backup" "DB_PASSWORD")"
  fi

  [[ -n "$DOMAIN" ]] || error "DOMAIN not found in backup manifest. Use --domain=example.com."
  validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"
  [[ -n "$PROJECT_PATH" ]] || error "PROJECT_PATH not found in backup manifest"
  [[ "$PROJECT_PATH" == /* ]] || error "PROJECT_PATH in manifest must be absolute: $PROJECT_PATH"
}

resolve_backup_path() {
  local safe_domain

  if [[ -z "$BACKUP_PATH" ]]; then
    [[ -n "$DOMAIN" ]] || error "--domain or --backup is required"
    safe_domain="$(safe_domain_dir_name "$DOMAIN")"
    BACKUP_PATH="${BACKUP_ROOT%/}/${safe_domain}/latest"
  fi

  if [[ -L "$BACKUP_PATH" ]]; then
    BACKUP_PATH="$(readlink -f "$BACKUP_PATH")"
  fi

  [[ -d "$BACKUP_PATH" ]] || error "Backup path not found: $BACKUP_PATH"
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain/--backup and --yes for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel restore wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_text "Domain website" "$DOMAIN")"
  if [[ -n "$DOMAIN" && -z "$BACKUP_PATH" ]]; then
    BACKUP_PATH="${BACKUP_ROOT%/}/$(safe_domain_dir_name "$DOMAIN")/latest"
  fi
  BACKUP_PATH="$(prompt_text "Path backup" "$BACKUP_PATH")"
}

print_restore_summary() {
  cat <<EOF

Restore summary:
  domain:       ${DOMAIN}
  backup path:  ${BACKUP_PATH}
  project path: ${PROJECT_PATH}
  site user:    ${SITE_USER:-"-"}
  PHP:          ${PHP_VERSION:-"-"}
  Nginx file:   ${NGINX_FILE:-"-"}
  PHP-FPM pool: ${PHP_FPM_POOL:-"-"}
  database:     ${DB_NAME:-"-"}
  APP_URL:      ${APP_URL:-"-"}
  restore db:   $([[ "$SKIP_DB" == true ]] && echo "skip" || echo "yes")
  restore env:  $([[ "$SKIP_ENV" == true ]] && echo "skip" || echo "yes")
  restore files: $([[ "$SKIP_STORAGE" == true ]] && echo "skip" || echo "yes")
  restore conf: $([[ "$SKIP_CONFIG" == true ]] && echo "skip" || echo "yes")

EOF
}

confirm_restore() {
  local expected="RESTORE ${DOMAIN}"
  local answer

  if [[ "$YES" == true ]]; then
    warn "Skipping restore confirmation because --yes was supplied"
    return
  fi

  is_tty || error "Restore needs confirmation. Re-run from a terminal or use --yes."
  printf "Type '%s' to continue: " "$expected" > /dev/tty
  IFS= read -r answer < /dev/tty
  [[ "$answer" == "$expected" ]] || error "Restore cancelled"
}

restore_env() {
  local env_backup="${BACKUP_PATH}/env/.env"
  local target="${PROJECT_PATH}/.env"

  if [[ "$SKIP_ENV" == true ]]; then
    warn "Skipping .env restore"
    return
  fi

  [[ -f "$env_backup" ]] || error ".env backup not found: $env_backup"
  install -d -m 0755 "$PROJECT_PATH"
  backup_existing_file "$target"
  install -m 0600 "$env_backup" "$target"
  if [[ -n "$SITE_USER" ]] && id "$SITE_USER" >/dev/null 2>&1; then
    chown "$SITE_USER:$SITE_USER" "$target"
  fi
  success "Restored .env to $target"
}

restore_storage() {
  local archive="${BACKUP_PATH}/storage-app-public.tar.gz"
  local target_dir="${PROJECT_PATH}/storage/app/public"

  if [[ "$SKIP_STORAGE" == true ]]; then
    warn "Skipping storage restore"
    return
  fi

  if [[ ! -f "$archive" ]]; then
    warn "Storage archive not found; skipping: $archive"
    return
  fi

  command -v tar >/dev/null 2>&1 || error "tar not found."
  install -d -m 0755 "$PROJECT_PATH"
  install -d -m 0755 "${PROJECT_PATH}/storage/app"

  if [[ -e "$target_dir" ]]; then
    mv "$target_dir" "${target_dir}.restore-bak.${RESTORE_TS}"
  fi

  tar -C "$PROJECT_PATH" -xzf "$archive"
  if [[ -n "$SITE_USER" ]] && id "$SITE_USER" >/dev/null 2>&1; then
    chown -R "$SITE_USER:$SITE_USER" "${PROJECT_PATH}/storage"
  fi
  success "Restored storage/app/public"
}

configure_database_user() {
  if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
    warn "DB_USERNAME or DB_PASSWORD not found in .env backup; skipping database user grant"
    return
  fi

  [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || error "Unsafe DB_USERNAME in .env backup: $DB_USER"

  local escaped_pass
  escaped_pass="$(sql_escape "$DB_PASS")"

  mysql <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

restore_database() {
  local dump_file="${BACKUP_PATH}/database/database.sql.gz"

  if [[ "$SKIP_DB" == true ]]; then
    warn "Skipping database restore"
    return
  fi

  if [[ ! -f "$dump_file" ]]; then
    warn "Database dump not found; skipping: $dump_file"
    return
  fi

  [[ -n "$DB_NAME" ]] || error "DB_DATABASE not found in backup"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || error "Unsafe database name: $DB_NAME"
  command -v mysql >/dev/null 2>&1 || error "mysql client not found."
  command -v gzip >/dev/null 2>&1 || error "gzip not found."

  info "Creating database if needed: $DB_NAME"
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL

  configure_database_user

  info "Importing database dump into ${DB_NAME}"
  gzip -dc "$dump_file" | mysql "$DB_NAME"
  success "Database restored: $DB_NAME"
}

restore_configs() {
  local nginx_backup="${BACKUP_PATH}/nginx/site.conf"
  local pool_backup="${BACKUP_PATH}/php-fpm/pool.conf"
  local nginx_target="${NGINX_FILE:-/etc/nginx/sites-available/${DOMAIN}}"
  local pool_target="$PHP_FPM_POOL"

  if [[ "$SKIP_CONFIG" == true ]]; then
    warn "Skipping Nginx/PHP-FPM config restore"
    return
  fi

  if [[ -f "$nginx_backup" ]]; then
    backup_existing_file "$nginx_target"
    install -D -m 0644 "$nginx_backup" "$nginx_target"
    install -d -m 0755 /etc/nginx/sites-enabled
    ln -sfn "$nginx_target" "/etc/nginx/sites-enabled/$(basename "$nginx_target")"
    success "Restored Nginx config: $nginx_target"
  else
    warn "Nginx backup not found; skipping: $nginx_backup"
  fi

  if [[ -f "$pool_backup" ]]; then
    if [[ -z "$pool_target" ]]; then
      [[ -n "$PHP_VERSION" && -n "$SITE_USER" ]] || error "Cannot determine PHP-FPM pool target"
      pool_target="/etc/php/${PHP_VERSION}/fpm/pool.d/${SITE_USER}.conf"
    fi
    backup_existing_file "$pool_target"
    install -D -m 0644 "$pool_backup" "$pool_target"
    success "Restored PHP-FPM pool: $pool_target"
  else
    warn "PHP-FPM pool backup not found; skipping: $pool_backup"
  fi
}

reload_services() {
  if [[ "$SKIP_CONFIG" != true && -n "$PHP_VERSION" ]]; then
    if systemctl list-unit-files "php${PHP_VERSION}-fpm.service" --no-pager --no-legend 2>/dev/null | grep -q "^php${PHP_VERSION}-fpm.service"; then
      info "Restarting php${PHP_VERSION}-fpm"
      systemctl restart "php${PHP_VERSION}-fpm"
    else
      warn "php${PHP_VERSION}-fpm service not found; skipping restart"
    fi
  fi

  if [[ "$SKIP_CONFIG" != true ]] && command -v nginx >/dev/null 2>&1; then
    info "Reloading Nginx"
    nginx -t
    systemctl reload nginx
  fi

  if command -v supervisorctl >/dev/null 2>&1; then
    supervisorctl reread || true
    supervisorctl update || true
  fi
}

validate_input() {
  [[ "$BACKUP_ROOT" == /* ]] || error "--backup-root must be an absolute path"
}

main() {
  RESTORE_TS="$(date +%Y%m%d%H%M%S)"

  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  resolve_backup_path
  load_backup_context
  print_restore_summary
  confirm_restore
  ensure_site_user
  restore_configs
  restore_env
  restore_storage
  restore_database
  reload_services
  success "Restore complete for $DOMAIN"
}

main "$@"
