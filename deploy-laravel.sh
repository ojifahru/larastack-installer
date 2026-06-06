#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
SITE_PATH=""
SITE_USER=""
BRANCH="main"
PHP_VERSION=""
NO_NPM=false
NO_MIGRATE=false
NO_OPTIMIZE=false
SEED=false
FORCE=false
MAINTENANCE=false
AUTO_ROLLBACK=false
ROLLBACK_COMMIT=""
INTERACTIVE=false
LOG_DIR="/var/log/laravel-deploy"
LOG_FILE=""
MAINTENANCE_ACTIVE=false
PREVIOUS_COMMIT=""

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash deploy-laravel.sh
  sudo bash deploy-laravel.sh --path=/home/example/public_html [options]

Options:
  --interactive
  --domain=example.com
  --path=/home/example/public_html
  --site-user=example
  --branch=main
  --php=8.3
  --no-npm
  --no-migrate
  --no-optimize
  --seed
  --no-seed
  --maintenance
  --auto-rollback       Checkout the previous Git commit if deploy fails
  --rollback=COMMIT     Checkout a specific Git commit and restart services only
  --force
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --site-user=*) SITE_USER="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --no-npm) NO_NPM=true ;;
    --no-migrate) NO_MIGRATE=true ;;
    --no-optimize) NO_OPTIMIZE=true ;;
    --seed) SEED=true ;;
    --no-seed) SEED=false ;;
    --maintenance) MAINTENANCE=true ;;
    --auto-rollback) AUTO_ROLLBACK=true ;;
    --rollback=*) ROLLBACK_COMMIT="${arg#*=}" ;;
    --force) FORCE=true ;;
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
  local nginx_file="" server_names root_path socket detected_user detected_php

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
    if [[ -z "$PHP_VERSION" && -n "$detected_php" ]]; then
      PHP_VERSION="$detected_php"
    fi

    detected_user="$(site_user_from_socket "$socket" "${PHP_VERSION:-$detected_php}")"
    if [[ -z "$SITE_USER" && -n "$detected_user" ]]; then
      SITE_USER="$detected_user"
    fi
  fi

  if [[ -z "$SITE_USER" && -n "$SITE_PATH" && -e "$SITE_PATH" ]]; then
    SITE_USER="$(stat -c '%U' "$SITE_PATH" 2>/dev/null || true)"
  fi

  if [[ -z "$DOMAIN" && -n "$SITE_PATH" ]]; then
    DOMAIN="$(basename "$SITE_PATH")"
  fi

  if [[ -z "$PHP_VERSION" ]]; then
    PHP_VERSION="8.3"
  fi
}

composer_lock_requires_php84() {
  local lock_file="${SITE_PATH}/composer.lock"
  [[ -f "$lock_file" ]] || return 1
  grep -Eq '"php"[[:space:]]*:[[:space:]]*"[^"]*(\^8\.4|>=8\.4|~8\.4|8\.4\.[0-9])' "$lock_file"
}

php_version_less_than_84() {
  [[ "$PHP_VERSION" =~ ^([0-7]\.|8\.[0-3]$|8\.[0-3]\.) ]]
}

php_bin() {
  if command -v "php${PHP_VERSION}" >/dev/null 2>&1; then
    command -v "php${PHP_VERSION}"
    return
  fi

  error "PHP binary php${PHP_VERSION} not found. Install it first, then re-run with --php=${PHP_VERSION}."
}

run_as_site_user() {
  sudo -H -u "$SITE_USER" bash -lc "$1" bash "$SITE_PATH" "$(php_bin)" "$(command -v composer || true)" "$BRANCH" "$PREVIOUS_COMMIT" "$ROLLBACK_COMMIT"
}

setup_logging() {
  DOMAIN="${DOMAIN:-$(basename "${SITE_PATH:-unknown}")}"
  DOMAIN="${DOMAIN//[^A-Za-z0-9._-]/-}"
  LOG_FILE="${LOG_DIR}/deploy-${DOMAIN}.log"
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 640 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'on_error $LINENO' ERR
}

on_error() {
  local line="${1:-$LINENO}"
  set +e
  if [[ "$MAINTENANCE_ACTIVE" == true ]]; then
    warn "Deploy failed; attempting to disable maintenance mode"
    run_as_site_user 'cd "$1" && "$2" artisan up' >/dev/null 2>&1
    MAINTENANCE_ACTIVE=false
  fi

  if [[ "$AUTO_ROLLBACK" == true && -n "$PREVIOUS_COMMIT" ]]; then
    warn "Auto rollback enabled; checking out previous commit ${PREVIOUS_COMMIT}"
    if run_as_site_user 'cd "$1" && git checkout "$5"' >/dev/null 2>&1; then
      if restart_services >/dev/null 2>&1; then
        warn "Services restarted after auto rollback checkout."
      else
        warn "Service restart after auto rollback failed. Run check-site after reviewing the log."
      fi
      warn "Git checkout rolled back to ${PREVIOUS_COMMIT}. Database migrations were not rolled back automatically."
    else
      warn "Auto rollback Git checkout failed. Run the rollback command manually after checking the worktree."
      print_rollback_hint
    fi
  else
    print_rollback_hint
  fi

  set -e
  error "Deploy failed at line ${line}. See ${LOG_FILE} for details."
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --path/--domain and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel deploy wizard
Press Enter to accept the value in brackets.

INTRO

  if [[ -z "$SITE_PATH" && -z "$DOMAIN" ]]; then
    SITE_PATH="$(default_site_path)"
  fi

  DOMAIN="$(prompt_text "Domain site. Kosongkan jika pakai path" "$DOMAIN")"
  detect_site_context

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="$(default_site_path)"
  fi

  SITE_PATH="$(prompt_required "Path project Laravel" "$SITE_PATH")"
  detect_site_context

  SITE_USER="$(prompt_required "Site user" "$SITE_USER")"
  BRANCH="$(prompt_required "Branch Git" "$BRANCH")"

  if composer_lock_requires_php84 && php_version_less_than_84; then
    warn "composer.lock terlihat membutuhkan PHP 8.4+. Default deploy diubah ke PHP 8.4."
    PHP_VERSION="8.4"
  fi

  PHP_VERSION="$(prompt_required "Versi PHP-FPM" "$PHP_VERSION")"

  if [[ "$NO_NPM" != true ]] && ! prompt_yes_no "Jalankan npm ci dan npm run build jika package.json ada?" "y"; then
    NO_NPM=true
  fi

  if [[ "$NO_MIGRATE" != true ]] && ! prompt_yes_no "Jalankan php artisan migrate --force?" "y"; then
    NO_MIGRATE=true
  fi

  if [[ "$NO_MIGRATE" != true && "$SEED" != true ]] && prompt_yes_no "Jalankan seeder saat migrate?" "n"; then
    SEED=true
  fi

  if [[ "$NO_OPTIMIZE" != true ]] && ! prompt_yes_no "Rebuild cache Laravel production?" "y"; then
    NO_OPTIMIZE=true
  fi

  if [[ "$MAINTENANCE" != true ]] && prompt_yes_no "Aktifkan maintenance mode selama deploy?" "n"; then
    MAINTENANCE=true
  fi

  if [[ "$AUTO_ROLLBACK" != true ]] && prompt_yes_no "Aktifkan auto rollback Git checkout jika deploy gagal?" "n"; then
    AUTO_ROLLBACK=true
  fi

  cat > /dev/tty <<EOF

Ringkasan deploy:
  domain:      ${DOMAIN:-"-"}
  path:        ${SITE_PATH}
  site user:   ${SITE_USER}
  branch:      ${BRANCH}
  PHP:         ${PHP_VERSION}
  npm build:   $([[ "$NO_NPM" == true ]] && echo "skip" || echo "run")
  migrate:     $([[ "$NO_MIGRATE" == true ]] && echo "skip" || echo "run")
  seed:        ${SEED}
  optimize:    $([[ "$NO_OPTIMIZE" == true ]] && echo "skip" || echo "run")
  maintenance: ${MAINTENANCE}
  auto rollback: ${AUTO_ROLLBACK}

EOF

  if ! prompt_yes_no "Lanjut deploy sekarang?" "y"; then
    error "Deploy cancelled"
  fi
}

validate_input() {
  [[ -n "$SITE_PATH" ]] || error "--path is required, or supply --domain for auto-detect"
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  [[ -d "$SITE_PATH" ]] || error "Project path not found: $SITE_PATH"
  [[ -d "${SITE_PATH}/.git" ]] || error "$SITE_PATH is not a git repository"
  [[ -f "${SITE_PATH}/artisan" ]] || error "$SITE_PATH does not look like a Laravel project: artisan not found"
  [[ -n "$SITE_USER" ]] || error "Could not detect site user. Use --site-user=example."
  id "$SITE_USER" >/dev/null 2>&1 || error "Site user does not exist: $SITE_USER"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  [[ -z "$ROLLBACK_COMMIT" || "$ROLLBACK_COMMIT" =~ ^[A-Za-z0-9._/-]+$ ]] || error "--rollback contains invalid characters"
  php_bin >/dev/null

  if [[ "$(stat -c '%U' "$SITE_PATH")" != "$SITE_USER" ]]; then
    warn "Project owner is $(stat -c '%U' "$SITE_PATH"), expected ${SITE_USER}. Permissions will be corrected after deploy."
  fi

  if composer_lock_requires_php84 && php_version_less_than_84; then
    error "composer.lock contains packages that require PHP 8.4+. Re-run with --php=8.4 after installing PHP 8.4."
  fi
}

ensure_clean_worktree() {
  if [[ "$FORCE" == true ]]; then
    warn "Skipping dirty worktree guard because --force was supplied"
    return
  fi

  if ! run_as_site_user 'cd "$1" && git diff --quiet && git diff --cached --quiet'; then
    error "Git worktree has local changes. Commit/stash them or re-run with --force."
  fi
}

git_update() {
  info "Pulling latest code from origin/${BRANCH} as ${SITE_USER}"
  run_as_site_user 'cd "$1" && git fetch origin "$4" && git checkout "$4" && git pull --ff-only origin "$4"'
}

capture_previous_commit() {
  PREVIOUS_COMMIT="$(run_as_site_user 'cd "$1" && git rev-parse HEAD')"
  success "Previous Git commit saved: ${PREVIOUS_COMMIT}"
}

rollback_target_arg() {
  if [[ -n "$DOMAIN" ]]; then
    printf -- '--domain=%s' "$DOMAIN"
  else
    printf -- '--path=%s' "$SITE_PATH"
  fi
}

print_rollback_hint() {
  [[ -n "$PREVIOUS_COMMIT" ]] || return

  cat <<EOF

Rollback command:
  sudo larastack deploy $(rollback_target_arg) --rollback=${PREVIOUS_COMMIT}

Note: rollback only changes the Git checkout and restarts services. Database migrations are not rolled back automatically.
EOF
}

rollback_to_commit() {
  local commit="$1"

  info "Checking out rollback commit ${commit} as ${SITE_USER}"
  run_as_site_user 'cd "$1" && git fetch --all --tags --prune && git checkout "$6"'
  warn "Git checkout changed to ${commit}. Database migrations were not rolled back automatically."
}

composer_install() {
  local composer_bin
  composer_bin="$(command -v composer || true)"
  [[ -n "$composer_bin" ]] || error "Composer not found. Run install-laravel-server.sh first."

  info "Installing Composer dependencies as ${SITE_USER}"
  run_as_site_user 'cd "$1" && COMPOSER_ALLOW_SUPERUSER=0 "$2" "$3" install --no-dev --optimize-autoloader --no-interaction'
}

npm_build() {
  if [[ "$NO_NPM" == true ]]; then
    warn "Skipping npm because --no-npm was supplied"
    return
  fi

  if [[ -f "${SITE_PATH}/package-lock.json" ]]; then
    info "Installing npm dependencies as ${SITE_USER}"
    run_as_site_user 'cd "$1" && npm ci'
  elif [[ -f "${SITE_PATH}/package.json" && ! -d "${SITE_PATH}/node_modules" ]]; then
    warn "package-lock.json not found; running npm install because node_modules is missing"
    run_as_site_user 'cd "$1" && npm install'
  fi

  if [[ -f "${SITE_PATH}/package.json" ]]; then
    info "Building frontend assets as ${SITE_USER}"
    run_as_site_user 'cd "$1" && npm run build'
  else
    info "package.json not found; skipping frontend build"
  fi
}

enable_maintenance() {
  if [[ "$MAINTENANCE" != true ]]; then
    return
  fi

  info "Enabling Laravel maintenance mode"
  run_as_site_user 'cd "$1" && "$2" artisan down --render="errors::503" || "$2" artisan down'
  MAINTENANCE_ACTIVE=true
}

disable_maintenance() {
  if [[ "$MAINTENANCE_ACTIVE" != true ]]; then
    return
  fi

  info "Disabling Laravel maintenance mode"
  run_as_site_user 'cd "$1" && "$2" artisan up'
  MAINTENANCE_ACTIVE=false
}

run_migrations() {
  if [[ "$NO_MIGRATE" == true ]]; then
    warn "Skipping migrations because --no-migrate was supplied"
    return
  fi

  if [[ "$SEED" == true ]]; then
    info "Running database migrations with seed as ${SITE_USER}"
    run_as_site_user 'cd "$1" && "$2" artisan migrate --force --seed'
  else
    info "Running database migrations as ${SITE_USER}"
    run_as_site_user 'cd "$1" && "$2" artisan migrate --force'
  fi
}

ensure_storage_link() {
  if [[ -L "${SITE_PATH}/public/storage" || -e "${SITE_PATH}/public/storage" ]]; then
    info "public/storage already exists"
    return
  fi

  info "Creating Laravel storage link as ${SITE_USER}"
  run_as_site_user 'cd "$1" && "$2" artisan storage:link'
}

optimize_laravel() {
  if [[ "$NO_OPTIMIZE" == true ]]; then
    warn "Skipping Laravel optimization because --no-optimize was supplied"
    return
  fi

  info "Rebuilding Laravel caches as ${SITE_USER}"
  run_as_site_user 'cd "$1" && "$2" artisan optimize:clear && "$2" artisan config:cache && "$2" artisan route:cache && "$2" artisan view:cache'
}

set_permissions() {
  info "Setting Laravel permissions for ${SITE_USER}"
  chown -R "$SITE_USER:$SITE_USER" "$SITE_PATH"

  find "$SITE_PATH" -type d -exec chmod 755 {} \;
  find "$SITE_PATH" -type f -exec chmod 644 {} \;

  if [[ -d "${SITE_PATH}/storage" ]]; then
    chmod -R 775 "${SITE_PATH}/storage"
  fi

  if [[ -d "${SITE_PATH}/bootstrap/cache" ]]; then
    chmod -R 775 "${SITE_PATH}/bootstrap/cache"
  fi

  if [[ -f "${SITE_PATH}/.env" ]]; then
    chmod 0600 "${SITE_PATH}/.env"
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
  else
    detect_site_context
  fi

  setup_logging
  validate_input

  if [[ -n "$ROLLBACK_COMMIT" ]]; then
    info "Rollback started for ${SITE_PATH}"
    info "Rollback context: domain=${DOMAIN:-"-"} site_user=${SITE_USER} php=${PHP_VERSION} commit=${ROLLBACK_COMMIT}"
    rollback_to_commit "$ROLLBACK_COMMIT"
    set_permissions
    restart_services
    success "Rollback checkout complete. Log saved to $LOG_FILE"
    return
  fi

  info "Deploy started for ${SITE_PATH}"
  info "Deploy context: domain=${DOMAIN:-"-"} site_user=${SITE_USER} php=${PHP_VERSION} branch=${BRANCH}"

  capture_previous_commit
  ensure_clean_worktree
  enable_maintenance
  git_update
  composer_install
  npm_build
  run_migrations
  ensure_storage_link
  optimize_laravel
  set_permissions
  restart_services
  disable_maintenance
  success "Deploy complete. Log saved to $LOG_FILE"
}

main "$@"
