#!/usr/bin/env bash
set -euo pipefail

SITE_PATH=""
BRANCH="main"
PHP_VERSION="8.3"
NO_NPM=false
NO_MIGRATE=false
NO_OPTIMIZE=false
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash deploy-laravel.sh
  sudo bash deploy-laravel.sh --path=/var/www/example.com [options]

Options:
  --interactive
  --branch=main
  --php=8.3
  --no-npm
  --no-migrate
  --no-optimize
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --path=*) SITE_PATH="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --no-npm) NO_NPM=true ;;
    --no-migrate) NO_MIGRATE=true ;;
    --no-optimize) NO_OPTIMIZE=true ;;
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

LOG_DIR="/var/log/laravel-deploy"
DOMAIN="unknown"
LOG_FILE=""

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
success() { printf '[OK] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

setup_logging() {
  DOMAIN="$(basename "${SITE_PATH:-unknown}")"
  DOMAIN="${DOMAIN//[^A-Za-z0-9._-]/-}"
  LOG_FILE="${LOG_DIR}/deploy-${DOMAIN}.log"
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 640 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'error "Deploy failed at line ${LINENO}. See ${LOG_FILE} for details."' ERR
}

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

default_site_path() {
  local candidate=""
  if [[ -d /var/www ]]; then
    candidate="$(find /var/www -mindepth 1 -maxdepth 1 -type d | sort | head -n 1 || true)"
  fi
  printf '%s' "$candidate"
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --path and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel deploy wizard
Press Enter to accept the value in brackets.

INTRO

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="$(default_site_path)"
  fi

  SITE_PATH="$(prompt_required "Path project Laravel" "$SITE_PATH")"
  BRANCH="$(prompt_required "Branch Git" "$BRANCH")"
  PHP_VERSION="$(prompt_required "Versi PHP-FPM" "$PHP_VERSION")"

  if [[ "$NO_NPM" != true ]] && ! prompt_yes_no "Jalankan npm ci dan npm run build jika package.json ada?" "y"; then
    NO_NPM=true
  fi

  if [[ "$NO_MIGRATE" != true ]] && ! prompt_yes_no "Jalankan php artisan migrate --force?" "y"; then
    NO_MIGRATE=true
  fi

  if [[ "$NO_OPTIMIZE" != true ]] && ! prompt_yes_no "Rebuild cache Laravel production?" "y"; then
    NO_OPTIMIZE=true
  fi

  cat > /dev/tty <<EOF

Ringkasan deploy:
  path:       ${SITE_PATH}
  branch:     ${BRANCH}
  PHP:        ${PHP_VERSION}
  npm build:  $([[ "$NO_NPM" == true ]] && echo "skip" || echo "run")
  migrate:    $([[ "$NO_MIGRATE" == true ]] && echo "skip" || echo "run")
  optimize:   $([[ "$NO_OPTIMIZE" == true ]] && echo "skip" || echo "run")

EOF

  if ! prompt_yes_no "Lanjut deploy sekarang?" "y"; then
    error "Deploy cancelled"
  fi
}

validate_input() {
  [[ -n "$SITE_PATH" ]] || error "--path is required"
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  [[ -d "$SITE_PATH" ]] || error "Project path not found: $SITE_PATH"
  [[ -d "${SITE_PATH}/.git" ]] || error "$SITE_PATH is not a git repository"
  [[ -f "${SITE_PATH}/artisan" ]] || error "$SITE_PATH does not look like a Laravel project: artisan not found"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
}

php_bin() {
  if command -v "php${PHP_VERSION}" >/dev/null 2>&1; then
    command -v "php${PHP_VERSION}"
  else
    command -v php
  fi
}

artisan() {
  local php
  php="$(php_bin)"
  "$php" artisan "$@"
}

git_update() {
  info "Pulling latest code from origin/${BRANCH}"
  git fetch origin "$BRANCH"
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
}

composer_install() {
  info "Installing Composer dependencies"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
}

npm_build() {
  if [[ "$NO_NPM" == true ]]; then
    warn "Skipping npm because --no-npm was supplied"
    return
  fi

  if [[ -f package-lock.json ]]; then
    info "Installing npm dependencies with npm ci"
    npm ci
  elif [[ -f package.json && ! -d node_modules ]]; then
    warn "package-lock.json not found; running npm install because node_modules is missing"
    npm install
  fi

  if [[ -f package.json ]]; then
    info "Building frontend assets"
    npm run build
  else
    info "package.json not found; skipping frontend build"
  fi
}

run_migrations() {
  if [[ "$NO_MIGRATE" == true ]]; then
    warn "Skipping migrations because --no-migrate was supplied"
    return
  fi

  info "Running database migrations"
  artisan migrate --force
}

ensure_storage_link() {
  if [[ -L public/storage || -e public/storage ]]; then
    info "public/storage already exists"
    return
  fi

  info "Creating Laravel storage link"
  artisan storage:link
}

optimize_laravel() {
  if [[ "$NO_OPTIMIZE" == true ]]; then
    warn "Skipping Laravel optimization because --no-optimize was supplied"
    return
  fi

  info "Rebuilding Laravel caches"
  artisan optimize:clear
  artisan config:cache
  artisan route:cache
  artisan view:cache
}

set_permissions() {
  info "Setting writable Laravel permissions"
  if [[ -d storage ]]; then
    chown -R www-data:www-data storage
    chmod -R 775 storage
  fi

  if [[ -d bootstrap/cache ]]; then
    chown -R www-data:www-data bootstrap/cache
    chmod -R 775 bootstrap/cache
  fi
}

restart_services() {
  local php_service="php${PHP_VERSION}-fpm"

  info "Restarting ${php_service}"
  systemctl restart "$php_service"

  if command -v supervisorctl >/dev/null 2>&1; then
    local queue_prefix="${DOMAIN}-queue:"
    if supervisorctl status 2>/dev/null | awk '{print $1}' | grep -Fq "$queue_prefix"; then
      info "Restarting Supervisor queue workers for ${DOMAIN}"
      supervisorctl restart "${DOMAIN}-queue:*" || true
    else
      info "No Supervisor queue workers found for ${DOMAIN}"
    fi
  fi

  info "Reloading Nginx"
  nginx -t
  systemctl reload nginx
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  setup_logging
  validate_input
  cd "$SITE_PATH"

  info "Deploy started for $SITE_PATH"
  git_update
  composer_install
  npm_build
  run_migrations
  ensure_storage_link
  optimize_laravel
  set_permissions
  restart_services
  success "Deploy complete. Log saved to $LOG_FILE"
}

main "$@"
