#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
ALIASES=""
SITE_USER=""
HOME_BASE="/home"
HOME_DIR=""
SITE_PATH=""
PHP_VERSION="8.3"
REPO=""
DB_NAME=""
DB_USER=""
DB_PASS=""
WITH_SSL=false
WITH_QUEUE=false
EMAIL=""
PRIVATE_REPO=false
SKIP_KEYGEN=false
KEY_NAME="id_ed25519"
NO_INSTALL_DEPS=false
MIGRATE=false
INTERACTIVE=false
DEPLOY_KEY_CONFIRMED=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash create-laravel-site.sh
  sudo bash create-laravel-site.sh --domain=example.com [options]

Options:
  --interactive
  --domain=example.com
  --aliases=www.example.com,sub.example.com
  --site-user=example
  --home-base=/home
  --path=/home/example/public_html
  --php=8.3
  --repo=git@github.com:user/repo.git
  --private-repo
  --skip-keygen
  --key-name=id_ed25519
  --db-name=example_db
  --db-user=example_user
  --db-pass=random
  --with-ssl
  --email=admin@example.com
  --with-queue
  --no-install-deps
  --migrate
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --aliases=*) ALIASES="${arg#*=}" ;;
    --site-user=*) SITE_USER="${arg#*=}" ;;
    --home-base=*) HOME_BASE="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}" ;;
    --private-repo) PRIVATE_REPO=true ;;
    --skip-keygen) SKIP_KEYGEN=true ;;
    --key-name=*) KEY_NAME="${arg#*=}" ;;
    --db-name=*) DB_NAME="${arg#*=}" ;;
    --db-user=*) DB_USER="${arg#*=}" ;;
    --db-pass=*) DB_PASS="${arg#*=}" ;;
    --with-ssl) WITH_SSL=true ;;
    --email=*) EMAIL="${arg#*=}" ;;
    --with-queue) WITH_QUEUE=true ;;
    --no-install-deps) NO_INSTALL_DEPS=true ;;
    --migrate) MIGRATE=true ;;
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

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

write_file_if_changed() {
  local target="$1"
  local mode="${2:-0644}"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  install -d -m 0755 "$(dirname "$target")"

  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    info "$target is already up to date"
    return
  fi

  if [[ -f "$target" ]]; then
    backup_file "$target"
  fi

  install -m "$mode" "$tmp" "$target"
  rm -f "$tmp"
  success "Wrote $target"
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

shell_quote() {
  printf '%q' "$1"
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
  [[ "$value" != *".."* ]] || return 1
}

generate_site_user_from_domain() {
  local value="$1"
  local first_label
  first_label="${value%%.*}"
  first_label="$(tr '[:upper:]' '[:lower:]' <<<"$first_label")"
  first_label="${first_label//[^a-z0-9_-]/-}"

  if [[ ! "$first_label" =~ ^[a-z_] ]]; then
    first_label="site_${first_label}"
  fi

  first_label="${first_label:0:32}"
  first_label="${first_label%-}"
  first_label="${first_label:-site}"
  printf '%s' "$first_label"
}

validate_site_user() {
  local value="$1"
  (( ${#value} >= 1 && ${#value} <= 32 )) || return 1
  [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  [[ "$value" != -* ]] || return 1
}

domain_to_identifier() {
  local value="$1"
  value="${value//./_}"
  value="${value//-/_}"
  value="${value//[^A-Za-z0-9_]/_}"
  printf '%s' "$value"
}

site_user_to_db_identifier() {
  local value="$1"
  value="${value//-/_}"
  value="${value//[^A-Za-z0-9_]/_}"
  printf '%s' "$value"
}

resolve_paths() {
  HOME_BASE="${HOME_BASE%/}"
  HOME_DIR="${HOME_BASE}/${SITE_USER}"

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="${HOME_DIR}/public_html"
  fi
}

validate_input() {
  [[ -n "$DOMAIN" ]] || error "--domain is required"
  validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"

  if [[ -z "$SITE_USER" ]]; then
    SITE_USER="$(generate_site_user_from_domain "$DOMAIN")"
  fi

  validate_site_user "$SITE_USER" || error "Invalid --site-user: use lowercase letters, numbers, underscore, or dash; start with lowercase letter or underscore; max 32 chars"
  [[ "$HOME_BASE" == /* ]] || error "--home-base must be an absolute path"
  resolve_paths
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  [[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || error "--key-name may only contain letters, numbers, dot, underscore, and dash"

  if [[ -n "$ALIASES" ]]; then
    local alias
    for alias in ${ALIASES//,/ }; do
      validate_domain "$alias" || error "Invalid alias: $alias"
    done
  fi

  if [[ "$PRIVATE_REPO" == true && -n "$REPO" && ! "$REPO" =~ ^git@github\.com:.+\.git$ ]]; then
    error "Private repo must use SSH format, for example git@github.com:username/repo.git"
  fi

  if [[ -n "$DB_NAME" || -n "$DB_USER" || -n "$DB_PASS" ]]; then
    [[ -n "$DB_NAME" ]] || error "--db-name is required when database options are used"
    [[ -n "$DB_USER" ]] || error "--db-user is required when database options are used"
    [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-name may only contain letters, numbers, and underscore"
    [[ "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || error "--db-user may only contain letters, numbers, and underscore"
  fi

  if [[ "$WITH_SSL" == true && -n "$EMAIL" ]]; then
    [[ "$EMAIL" == *@*.* ]] || error "--email must be a valid email address"
  fi

  if [[ "$SITE_PATH" != "${HOME_DIR}/"* && "$SITE_PATH" != "$HOME_DIR" ]]; then
    warn "Project path is outside ${HOME_DIR}. Owner will still be ${SITE_USER}:${SITE_USER}."
  fi
}

ensure_site_user() {
  if id "$SITE_USER" >/dev/null 2>&1; then
    local existing_home
    existing_home="$(getent passwd "$SITE_USER" | cut -d: -f6)"
    if [[ "$existing_home" != "$HOME_DIR" ]]; then
      error "User ${SITE_USER} already exists with home ${existing_home}, expected ${HOME_DIR}"
    fi
    success "Linux user already exists: $SITE_USER"
  else
    info "Creating Linux user for site: $SITE_USER"
    useradd --create-home --home-dir "$HOME_DIR" --shell /bin/bash "$SITE_USER"
  fi

  install -d -m 0755 "$HOME_DIR"
  chown "$SITE_USER:$SITE_USER" "$HOME_DIR"
  chmod 0755 "$HOME_DIR"
}

ensure_site_ssh_key() {
  local ssh_dir="${HOME_DIR}/.ssh"
  local private_key="${ssh_dir}/${KEY_NAME}"
  local public_key="${private_key}.pub"
  local known_hosts="${ssh_dir}/known_hosts"

  install -d -m 0700 "$ssh_dir"
  chown "$SITE_USER:$SITE_USER" "$ssh_dir"

  if [[ -f "$private_key" ]]; then
    success "SSH key already exists: $private_key"
  else
    info "Generating SSH key for ${SITE_USER}"
    sudo -H -u "$SITE_USER" ssh-keygen -t ed25519 -C "${SITE_USER}@${DOMAIN}" -f "$private_key" -N ""
  fi

  if [[ ! -f "$public_key" ]]; then
    error "Public key not found: $public_key"
  fi

  chown "$SITE_USER:$SITE_USER" "$private_key" "$public_key"
  chmod 0600 "$private_key"
  chmod 0644 "$public_key"

  touch "$known_hosts"
  chown "$SITE_USER:$SITE_USER" "$known_hosts"
  chmod 0644 "$known_hosts"

  if ! sudo -H -u "$SITE_USER" ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
    info "Adding github.com to known_hosts for ${SITE_USER}"
    sudo -H -u "$SITE_USER" bash -lc 'ssh-keyscan -H github.com >> "$1"' bash "$known_hosts" 2>/dev/null
  fi

  chmod 0644 "$known_hosts"
}

print_public_key_instructions() {
  local public_key="${HOME_DIR}/.ssh/${KEY_NAME}.pub"
  [[ -f "$public_key" ]] || error "Public key not found: $public_key"

  cat > /dev/tty <<EOF

SSH public key for ${DOMAIN}
Path: ${public_key}

$(cat "$public_key")

Copy public key di atas ke GitHub -> Repository -> Settings -> Deploy keys -> Add deploy key.
Jangan centang Allow write access kecuali butuh push.

EOF
}

wait_for_deploy_key_confirmation() {
  if ! is_tty; then
    error "Private repository setup needs a terminal to confirm GitHub Deploy Key."
  fi

  if prompt_yes_no "Sudah ditambahkan ke GitHub Deploy Key?" "n"; then
    DEPLOY_KEY_CONFIRMED=true
  else
    error "Deploy key belum ditambahkan. Script dihentikan tanpa clone repo."
  fi
}

test_github_ssh_access() {
  local output status

  set +e
  output="$(sudo -H -u "$SITE_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1)"
  status=$?
  set -e

  if grep -qi "successfully authenticated" <<<"$output"; then
    success "GitHub SSH authentication looks good"
    return 0
  fi

  if (( status == 0 )); then
    success "GitHub SSH test passed"
    return 0
  fi

  warn "GitHub SSH test did not confirm authentication:"
  warn "$output"

  if [[ "$PRIVATE_REPO" == true ]]; then
    if is_tty && prompt_yes_no "Lanjut clone meskipun test SSH belum sukses?" "n"; then
      return 0
    fi
    error "GitHub SSH access is not ready for private repo"
  fi
}

prepare_private_repo_access() {
  if [[ "$PRIVATE_REPO" != true ]]; then
    return
  fi

  ensure_site_user

  if [[ "$SKIP_KEYGEN" == true ]]; then
    warn "Skipping SSH key generation because --skip-keygen was supplied"
  else
    ensure_site_ssh_key
    print_public_key_instructions
  fi

  wait_for_deploy_key_confirmation
  test_github_ssh_access
}

composer_lock_requires_php84() {
  local lock_file="${SITE_PATH}/composer.lock"
  [[ -f "$lock_file" ]] || return 1
  grep -Eq '"php"[[:space:]]*:[[:space:]]*"[^"]*(\^8\.4|>=8\.4|~8\.4|8\.4\.[0-9])' "$lock_file"
}

php_version_less_than_84() {
  [[ "$PHP_VERSION" =~ ^([0-7]\.|8\.[0-3]$|8\.[0-3]\.) ]]
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain and other options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel site wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_required "Domain utama" "$DOMAIN")"

  if [[ -z "$SITE_USER" ]]; then
    SITE_USER="$(generate_site_user_from_domain "$DOMAIN")"
  fi
  SITE_USER="$(prompt_required "Linux site user" "$SITE_USER")"
  validate_site_user "$SITE_USER" || error "Invalid site user: $SITE_USER"

  resolve_paths
  cat > /dev/tty <<EOF
Path otomatis: ${SITE_PATH}
EOF
  SITE_PATH="$(prompt_required "Path project" "$SITE_PATH")"

  PHP_VERSION="$(prompt_required "Versi PHP-FPM" "$PHP_VERSION")"
  [[ "$KEY_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || error "--key-name may only contain letters, numbers, dot, underscore, and dash"

  if [[ "$PRIVATE_REPO" != true ]] && prompt_yes_no "Repository private?" "n"; then
    PRIVATE_REPO=true
  fi

  if [[ "$PRIVATE_REPO" == true ]]; then
    prepare_private_repo_access
  fi

  REPO="$(prompt_text "Git repository URL. Private repo wajib format SSH git@github.com:username/repo.git" "$REPO")"

  if [[ "$PRIVATE_REPO" == true && -n "$REPO" && ! "$REPO" =~ ^git@github\.com:.+\.git$ ]]; then
    error "Private repo must use SSH format: git@github.com:username/repo.git"
  fi

  ALIASES="$(prompt_text "Alias domain, pisahkan dengan koma. Contoh: www.${DOMAIN}. Kosongkan jika tidak ada" "$ALIASES")"

  local wants_db=false
  if [[ -n "$DB_NAME" || -n "$DB_USER" || -n "$DB_PASS" ]]; then
    wants_db=true
  elif prompt_yes_no "Buat database MariaDB untuk site ini?" "y"; then
    wants_db=true
  fi

  if [[ "$wants_db" == true ]]; then
    local db_base
    db_base="$(site_user_to_db_identifier "$SITE_USER")"
    [[ -n "$DB_NAME" ]] || DB_NAME="${db_base}_db"
    [[ -n "$DB_USER" ]] || DB_USER="${db_base}_user"
    [[ -n "$DB_PASS" ]] || DB_PASS="random"

    DB_NAME="$(prompt_required "Nama database" "$DB_NAME")"
    DB_USER="$(prompt_required "User database" "$DB_USER")"
    DB_PASS="$(prompt_required "Password database. Gunakan random untuk generate otomatis" "$DB_PASS")"
  fi

  if [[ "$WITH_SSL" != true ]] && prompt_yes_no "Aktifkan SSL Let's Encrypt sekarang?" "n"; then
    WITH_SSL=true
  fi

  if [[ "$WITH_SSL" == true ]]; then
    EMAIL="$(prompt_text "Email Let's Encrypt. Kosongkan untuk tanpa email" "$EMAIL")"
  fi

  if [[ "$WITH_QUEUE" != true ]] && prompt_yes_no "Buat Supervisor queue worker?" "n"; then
    WITH_QUEUE=true
  fi

  if [[ "$NO_INSTALL_DEPS" != true ]] && ! prompt_yes_no "Jalankan composer/npm/artisan setup sebagai ${SITE_USER}?" "y"; then
    NO_INSTALL_DEPS=true
  fi

  if [[ "$NO_INSTALL_DEPS" != true && "$MIGRATE" != true ]] && prompt_yes_no "Jalankan php artisan migrate --force?" "n"; then
    MIGRATE=true
  fi

  cat > /dev/tty <<EOF

Ringkasan site:
  domain:           ${DOMAIN}
  aliases:          ${ALIASES:-"-"}
  site user:        ${SITE_USER}
  home directory:   ${HOME_DIR}
  project path:     ${SITE_PATH}
  PHP:              ${PHP_VERSION}
  repo:             ${REPO:-"-"}
  private repo:     ${PRIVATE_REPO}
  database:         ${DB_NAME:-"-"}
  db user:          ${DB_USER:-"-"}
  install deps:     $([[ "$NO_INSTALL_DEPS" == true ]] && echo "false" || echo "true")
  migrate:          ${MIGRATE}
  SSL:              ${WITH_SSL}
  queue:            ${WITH_QUEUE}

EOF

  if ! prompt_yes_no "Lanjut buat/update site sekarang?" "y"; then
    error "Site creation cancelled"
  fi
}

sql_escape() {
  sed "s/'/''/g" <<<"$1"
}

ensure_php_fpm_available() {
  local php_bin="php${PHP_VERSION}"
  local php_service="php${PHP_VERSION}-fpm"

  command -v "$php_bin" >/dev/null 2>&1 || error "PHP binary ${php_bin} not found. Install PHP ${PHP_VERSION} first."

  if ! systemctl list-unit-files "${php_service}.service" --no-pager --no-legend 2>/dev/null | grep -q "^${php_service}.service"; then
    error "PHP-FPM service ${php_service} is not installed. Install PHP ${PHP_VERSION} FPM first."
  fi

  systemctl enable --now "$php_service"
}

create_project_path() {
  install -d -m 0755 "$(dirname "$SITE_PATH")"

  if [[ -e "$SITE_PATH" && -n "$(find "$SITE_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    if [[ -d "${SITE_PATH}/.git" ]]; then
      warn "$SITE_PATH already contains a git repository; skipping clone"
    else
      error "$SITE_PATH exists and is not empty. Refusing to overwrite it."
    fi
  else
    install -d -m 0755 "$SITE_PATH"
    chown "$SITE_USER:$SITE_USER" "$SITE_PATH"

    if [[ -n "$REPO" ]]; then
      if [[ "$PRIVATE_REPO" == true && ! "$REPO" =~ ^git@github\.com:.+\.git$ ]]; then
        error "Private repo must use SSH format: git@github.com:username/repo.git"
      fi

      info "Cloning repository as ${SITE_USER}"
      sudo -H -u "$SITE_USER" git clone "$REPO" "$SITE_PATH"
      success "Repository cloned to $SITE_PATH"
    else
      success "Project directory ready: $SITE_PATH"
    fi
  fi

  install -d -m 0755 "${SITE_PATH}/public"
  chown -R "$SITE_USER:$SITE_USER" "$SITE_PATH"
}

check_project_php_requirement() {
  if composer_lock_requires_php84 && php_version_less_than_84; then
    error "${SITE_PATH}/composer.lock requires PHP 8.4+. Re-run with --php=8.4 after installing PHP 8.4."
  fi
}

create_php_fpm_pool() {
  local pool_file="/etc/php/${PHP_VERSION}/fpm/pool.d/${SITE_USER}.conf"
  local socket="/run/php/php${PHP_VERSION}-fpm-${SITE_USER}.sock"
  local tmp_dir="${HOME_DIR}/tmp"
  local fpm_test_bin=""

  install -d -m 0750 "$tmp_dir"
  chown "$SITE_USER:$SITE_USER" "$tmp_dir"

  info "Creating PHP-FPM pool for ${SITE_USER}"
  write_file_if_changed "$pool_file" 0644 <<EOF
[${SITE_USER}]
user = ${SITE_USER}
group = ${SITE_USER}

listen = ${socket}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
pm.max_requests = 500

chdir = /

php_admin_value[open_basedir] = ${SITE_PATH}:${tmp_dir}:/tmp
php_admin_value[upload_tmp_dir] = ${tmp_dir}
php_admin_value[session.save_path] = ${tmp_dir}

php_value[memory_limit] = 256M
php_value[upload_max_filesize] = 64M
php_value[post_max_size] = 64M
php_value[max_execution_time] = 120
php_value[max_input_time] = 120
EOF

  fpm_test_bin="$(command -v "php-fpm${PHP_VERSION}" || true)"
  if [[ -n "$fpm_test_bin" ]]; then
    "$fpm_test_bin" -t
  else
    warn "php-fpm${PHP_VERSION} command not found; relying on systemctl restart test"
  fi

  systemctl restart "php${PHP_VERSION}-fpm"
  systemctl is-active --quiet "php${PHP_VERSION}-fpm"

  if [[ -S "$socket" ]]; then
    success "PHP-FPM socket ready: $socket"
  else
    warn "PHP-FPM service is active, but socket was not found yet: $socket"
  fi
}

create_database() {
  if [[ -z "$DB_NAME" ]]; then
    return
  fi

  local credential_dir="/root/laravel-deploy/credentials"
  local credential_file="${credential_dir}/${DOMAIN}.db.env"
  local generated=false
  install -d -m 0700 "$credential_dir"

  if [[ -z "$DB_PASS" || "$DB_PASS" == "random" ]]; then
    if [[ -f "$credential_file" ]] \
      && grep -qx "DB_NAME=${DB_NAME}" "$credential_file" \
      && grep -qx "DB_USER=${DB_USER}" "$credential_file"; then
      DB_PASS="$(grep '^DB_PASS=' "$credential_file" | cut -d= -f2-)"
      success "Reusing existing database password from $credential_file"
    else
      DB_PASS="$(openssl rand -hex 24)"
      generated=true
    fi
  fi

  local escaped_pass
  escaped_pass="$(sql_escape "$DB_PASS")"

  info "Creating MariaDB database and user"
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  umask 077
  cat > "$credential_file" <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
  umask 022

  if [[ "$generated" == true ]]; then
    success "Database credentials stored in $credential_file"
  else
    success "Database credentials updated in $credential_file"
  fi
}

install_laravel_dependencies() {
  if [[ "$NO_INSTALL_DEPS" == true ]]; then
    warn "Skipping Composer/NPM/Artisan setup because --no-install-deps was supplied"
    return
  fi

  if [[ -z "$REPO" ]]; then
    info "No repository supplied; skipping dependency install"
    return
  fi

  if [[ ! -f "${SITE_PATH}/composer.json" ]]; then
    warn "composer.json not found; skipping Laravel dependency setup"
    return
  fi

  local php_bin="php${PHP_VERSION}"
  local composer_bin
  composer_bin="$(command -v composer || true)"
  [[ -n "$composer_bin" ]] || error "Composer not found. Run install-laravel-server.sh first."

  info "Installing Composer dependencies as ${SITE_USER}"
  sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" "$3" install --no-dev --optimize-autoloader --no-interaction' bash "$SITE_PATH" "$php_bin" "$composer_bin"

  if [[ -f "${SITE_PATH}/package-lock.json" ]]; then
    info "Installing npm dependencies as ${SITE_USER}"
    sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && npm ci' bash "$SITE_PATH"
  fi

  if [[ -f "${SITE_PATH}/package.json" ]]; then
    info "Building frontend assets as ${SITE_USER}"
    sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && npm run build' bash "$SITE_PATH"
  fi

  if [[ -f "${SITE_PATH}/.env.example" && ! -f "${SITE_PATH}/.env" ]]; then
    info "Creating .env from .env.example"
    sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && cp .env.example .env' bash "$SITE_PATH"
  fi

  if [[ -f "${SITE_PATH}/artisan" && -f "${SITE_PATH}/.env" ]]; then
    if ! grep -Eq '^APP_KEY=.+$' "${SITE_PATH}/.env"; then
      info "Generating Laravel APP_KEY"
      sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" artisan key:generate --force' bash "$SITE_PATH" "$php_bin"
    fi

    if [[ ! -L "${SITE_PATH}/public/storage" && ! -e "${SITE_PATH}/public/storage" ]]; then
      info "Creating Laravel storage link"
      sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" artisan storage:link' bash "$SITE_PATH" "$php_bin"
    fi

    if [[ "$MIGRATE" == true ]]; then
      info "Running Laravel migrations"
      sudo -H -u "$SITE_USER" bash -lc 'cd "$1" && "$2" artisan migrate --force' bash "$SITE_PATH" "$php_bin"
    fi
  fi

  if [[ -n "$DB_NAME" ]]; then
    warn "Database credentials were created at /root/laravel-deploy/credentials/${DOMAIN}.db.env. Update ${SITE_PATH}/.env as needed."
  fi
}

create_nginx_site() {
  local nginx_file="/etc/nginx/sites-available/${DOMAIN}"
  local enabled_file="/etc/nginx/sites-enabled/${DOMAIN}"
  local server_names="$DOMAIN"
  local socket="/run/php/php${PHP_VERSION}-fpm-${SITE_USER}.sock"

  if [[ -n "$ALIASES" ]]; then
    server_names="$server_names ${ALIASES//,/ }"
  fi

  chmod 0755 "$HOME_DIR"
  chmod 0755 "$SITE_PATH"

  info "Creating Nginx server block for $DOMAIN"
  write_file_if_changed "$nginx_file" 0644 <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${server_names};

    root ${SITE_PATH}/public;
    index index.php index.html;
    charset utf-8;
    client_max_body_size 64M;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location = /robots.txt {
        access_log off;
        log_not_found off;
    }

    error_page 404 /index.php;

    location ~ \.php$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_pass unix:${socket};
    }

    location ~* /\.(env|git|htaccess)$ {
        deny all;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

  ln -sfn "$nginx_file" "$enabled_file"
  nginx -t
  systemctl reload nginx
  success "Nginx enabled for $DOMAIN"
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

  chmod 0755 "$HOME_DIR"
  chmod 0755 "$SITE_PATH"
}

enable_ssl() {
  if [[ "$WITH_SSL" != true ]]; then
    return
  fi

  local certbot_args=(--nginx --non-interactive --agree-tos --redirect -d "$DOMAIN")
  local alias

  for alias in ${ALIASES//,/ }; do
    [[ -n "$alias" ]] && certbot_args+=(-d "$alias")
  done

  if [[ -n "$EMAIL" ]]; then
    certbot_args+=(-m "$EMAIL")
  else
    warn "No --email supplied; certbot will register without email"
    certbot_args+=(--register-unsafely-without-email)
  fi

  certbot "${certbot_args[@]}"
  systemctl reload nginx
  success "SSL enabled for $DOMAIN"
}

enable_queue() {
  if [[ "$WITH_QUEUE" != true ]]; then
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "${script_dir}/create-supervisor-laravel-queue.sh" \
    --name="$DOMAIN" \
    --path="$SITE_PATH" \
    --php="$PHP_VERSION" \
    --user="$SITE_USER"
}

print_summary() {
  local nginx_file="/etc/nginx/sites-available/${DOMAIN}"
  local pool_file="/etc/php/${PHP_VERSION}/fpm/pool.d/${SITE_USER}.conf"
  local socket="/run/php/php${PHP_VERSION}-fpm-${SITE_USER}.sock"
  local ssl_status="disabled"
  local queue_status="disabled"
  local db_status="-"
  local db_user_status="-"
  local credential_file="/root/laravel-deploy/credentials/${DOMAIN}.db.env"
  local public_key="${HOME_DIR}/.ssh/${KEY_NAME}.pub"

  [[ "$WITH_SSL" == true ]] && ssl_status="enabled"
  [[ "$WITH_QUEUE" == true ]] && queue_status="enabled"
  [[ -n "$DB_NAME" ]] && db_status="$DB_NAME"
  [[ -n "$DB_USER" ]] && db_user_status="$DB_USER"

  cat <<EOF

Site summary:
  domain:          ${DOMAIN}
  aliases:         ${ALIASES:-"-"}
  site user:       ${SITE_USER}
  home directory:  ${HOME_DIR}
  project path:    ${SITE_PATH}
  PHP-FPM pool:    ${pool_file}
  PHP-FPM socket:  ${socket}
  nginx file:      ${nginx_file}
  database:        ${db_status}
  database user:   ${db_user_status}
  credentials:     $([[ -f "$credential_file" ]] && echo "$credential_file" || echo "-")
  SSL:             ${ssl_status}
  queue:           ${queue_status}
  repo:            ${REPO:-"-"}
  SSH public key:  $([[ -f "$public_key" ]] && echo "$public_key" || echo "-")
EOF
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  ensure_site_user

  if [[ "$PRIVATE_REPO" == true && "$DEPLOY_KEY_CONFIRMED" != true ]]; then
    prepare_private_repo_access
  fi

  ensure_php_fpm_available
  create_project_path
  check_project_php_requirement
  create_php_fpm_pool
  create_database
  install_laravel_dependencies
  set_permissions
  create_nginx_site
  enable_ssl
  enable_queue
  print_summary
}

main "$@"
