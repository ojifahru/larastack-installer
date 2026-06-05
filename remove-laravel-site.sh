#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
DELETE_FILES=false
DELETE_DB=false
DB_NAME=""
DB_USER=""
SITE_PATH=""

usage() {
  cat <<'USAGE'
Usage: sudo bash remove-laravel-site.sh --domain=example.com [options]

Options:
  --delete-files      Delete /var/www/{domain} after explicit confirmation
  --delete-db         Drop database and user after explicit confirmation
  --db-name=name      Required with --delete-db
  --db-user=user      Required with --delete-db
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --delete-files) DELETE_FILES=true ;;
    --delete-db) DELETE_DB=true ;;
    --db-name=*) DB_NAME="${arg#*=}" ;;
    --db-user=*) DB_USER="${arg#*=}" ;;
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

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
  [[ "$value" != *".."* ]] || return 1
}

validate_input() {
  [[ -n "$DOMAIN" ]] || error "--domain is required"
  validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"
  SITE_PATH="/var/www/${DOMAIN}"

  if [[ "$DELETE_DB" == true ]]; then
    [[ -n "$DB_NAME" ]] || error "--db-name is required with --delete-db"
    [[ -n "$DB_USER" ]] || error "--db-user is required with --delete-db"
    [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-name may only contain letters, numbers, and underscore"
    [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-user may only contain letters, numbers, and underscore"
  fi
}

disable_nginx_site() {
  local available="/etc/nginx/sites-available/${DOMAIN}"
  local enabled="/etc/nginx/sites-enabled/${DOMAIN}"

  info "Disabling Nginx site for $DOMAIN"
  rm -f "$enabled"
  rm -f "$available"

  nginx -t
  systemctl reload nginx
  success "Nginx site removed"
}

remove_supervisor_queue() {
  local conf="/etc/supervisor/conf.d/${DOMAIN}-queue.conf"

  if [[ ! -f "$conf" ]]; then
    info "No Supervisor queue config found for $DOMAIN"
    return
  fi

  info "Removing Supervisor queue config"
  supervisorctl stop "${DOMAIN}-queue:*" || true
  rm -f "$conf"
  supervisorctl reread
  supervisorctl update
  success "Supervisor queue removed"
}

confirm_or_skip() {
  local expected="$1"
  local prompt="$2"
  local answer

  printf '%s\n' "$prompt"
  read -r answer
  [[ "$answer" == "$expected" ]]
}

delete_files_if_requested() {
  if [[ "$DELETE_FILES" != true ]]; then
    return
  fi

  if [[ ! -d "$SITE_PATH" ]]; then
    warn "Project path not found: $SITE_PATH"
    return
  fi

  [[ "$SITE_PATH" == /var/www/* ]] || error "Refusing to delete path outside /var/www: $SITE_PATH"

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
FLUSH PRIVILEGES;
SQL
    rm -f "/root/laravel-deploy/credentials/${DOMAIN}.db.env"
    success "Database and user removed"
  else
    warn "Database deletion skipped"
  fi
}

main() {
  validate_input
  disable_nginx_site
  remove_supervisor_queue
  delete_files_if_requested
  delete_database_if_requested
  success "Removal complete for $DOMAIN"
}

main "$@"
