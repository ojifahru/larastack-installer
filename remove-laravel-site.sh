#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
DELETE_FILES=false
DELETE_DB=false
DB_NAME=""
DB_USER=""
SITE_PATH=""
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

load_db_defaults_from_credentials() {
  local credential_file="/root/laravel-deploy/credentials/${DOMAIN}.db.env"
  if [[ ! -f "$credential_file" ]]; then
    return
  fi

  if [[ -z "$DB_NAME" ]]; then
    DB_NAME="$(grep '^DB_NAME=' "$credential_file" | cut -d= -f2- || true)"
  fi

  if [[ -z "$DB_USER" ]]; then
    DB_USER="$(grep '^DB_USER=' "$credential_file" | cut -d= -f2- || true)"
  fi
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel site removal wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_required "Domain site yang akan dihapus" "$DOMAIN")"
  load_db_defaults_from_credentials

  if [[ "$DELETE_FILES" != true ]] && prompt_yes_no "Hapus folder project juga?" "n"; then
    DELETE_FILES=true
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

  cat > /dev/tty <<EOF

Ringkasan removal:
  domain:       ${DOMAIN}
  nginx:        remove config
  supervisor:   remove ${DOMAIN}-queue jika ada
  files:        ${DELETE_FILES}
  database:     ${DELETE_DB}
  db name:      ${DB_NAME:-"-"}
  db user:      ${DB_USER:-"-"}

EOF

  if ! prompt_yes_no "Lanjut disable site sekarang?" "n"; then
    error "Removal cancelled"
  fi
}

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

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '%s\n' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty
  else
    printf '%s\n' "$prompt"
    IFS= read -r answer
  fi

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
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  disable_nginx_site
  remove_supervisor_queue
  delete_files_if_requested
  delete_database_if_requested
  success "Removal complete for $DOMAIN"
}

main "$@"
