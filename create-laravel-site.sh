#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
ALIASES=""
SITE_PATH=""
PHP_VERSION="8.3"
REPO=""
DB_NAME=""
DB_USER=""
DB_PASS=""
WITH_SSL=false
WITH_QUEUE=false
EMAIL=""
INTERACTIVE=false

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
  --aliases=www.example.com,sub.example.com
  --path=/var/www/example.com
  --php=8.3
  --repo=https://github.com/user/repo.git
  --db-name=example_db
  --db-user=example_user
  --db-pass=random
  --with-ssl
  --email=admin@example.com
  --with-queue
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --aliases=*) ALIASES="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}" ;;
    --db-name=*) DB_NAME="${arg#*=}" ;;
    --db-user=*) DB_USER="${arg#*=}" ;;
    --db-pass=*) DB_PASS="${arg#*=}" ;;
    --with-ssl) WITH_SSL=true ;;
    --email=*) EMAIL="${arg#*=}" ;;
    --with-queue) WITH_QUEUE=true ;;
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

domain_to_identifier() {
  local value="$1"
  value="${value//./_}"
  value="${value//-/_}"
  value="${value//[^A-Za-z0-9_]/_}"
  printf '%s' "$value"
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain and other options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel site wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_required "Domain utama" "$DOMAIN")"

  ALIASES="$(prompt_text "Alias domain, pisahkan dengan koma. Contoh: www.${DOMAIN}. Kosongkan jika tidak ada" "$ALIASES")"

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="/var/www/${DOMAIN}"
  fi
  SITE_PATH="$(prompt_required "Path project" "$SITE_PATH")"

  PHP_VERSION="$(prompt_required "Versi PHP-FPM" "$PHP_VERSION")"
  REPO="$(prompt_text "Git repository URL. Kosongkan jika belum ada repo" "$REPO")"

  local wants_db=false
  if [[ -n "$DB_NAME" || -n "$DB_USER" || -n "$DB_PASS" ]]; then
    wants_db=true
  elif prompt_yes_no "Buat database MariaDB untuk site ini?" "y"; then
    wants_db=true
  fi

  if [[ "$wants_db" == true ]]; then
    local db_base
    db_base="$(domain_to_identifier "$DOMAIN")"
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

  cat > /dev/tty <<EOF

Ringkasan site:
  domain:       ${DOMAIN}
  aliases:      ${ALIASES:-"-"}
  path:         ${SITE_PATH}
  PHP:          ${PHP_VERSION}
  repo:         ${REPO:-"-"}
  database:     ${DB_NAME:-"-"}
  db user:      ${DB_USER:-"-"}
  SSL:          ${WITH_SSL}
  queue:        ${WITH_QUEUE}

EOF

  if ! prompt_yes_no "Lanjut buat/update site sekarang?" "y"; then
    error "Site creation cancelled"
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
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"

  if [[ -z "$SITE_PATH" ]]; then
    SITE_PATH="/var/www/${DOMAIN}"
  fi
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"

  if [[ -n "$ALIASES" ]]; then
    local alias
    for alias in ${ALIASES//,/ }; do
      validate_domain "$alias" || error "Invalid alias: $alias"
    done
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
}

sql_escape() {
  sed "s/'/''/g" <<<"$1"
}

create_project_path() {
  if [[ -n "$REPO" ]]; then
    if [[ -e "$SITE_PATH" && -n "$(find "$SITE_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      if [[ -d "${SITE_PATH}/.git" ]]; then
        warn "$SITE_PATH already contains a git repository; skipping clone"
      else
        error "$SITE_PATH exists and is not empty. Refusing to overwrite it."
      fi
    else
      install -d -m 0755 "$(dirname "$SITE_PATH")"
      git clone "$REPO" "$SITE_PATH"
      success "Repository cloned to $SITE_PATH"
    fi
  else
    install -d -m 0755 "$SITE_PATH"
    success "Project directory ready: $SITE_PATH"
  fi

  install -d -m 0755 "${SITE_PATH}/public"
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

create_nginx_site() {
  local nginx_file="/etc/nginx/sites-available/${DOMAIN}"
  local enabled_file="/etc/nginx/sites-enabled/${DOMAIN}"
  local server_names="$DOMAIN"

  if [[ -n "$ALIASES" ]]; then
    server_names="$server_names ${ALIASES//,/ }"
  fi

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
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
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
  info "Setting Laravel permissions"
  chown -R www-data:www-data "$SITE_PATH"
  chmod -R 755 "$SITE_PATH"

  if [[ -d "${SITE_PATH}/storage" ]]; then
    chmod -R 775 "${SITE_PATH}/storage"
  fi

  if [[ -d "${SITE_PATH}/bootstrap/cache" ]]; then
    chmod -R 775 "${SITE_PATH}/bootstrap/cache"
  fi
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
    --user=www-data
}

print_summary() {
  local nginx_file="/etc/nginx/sites-available/${DOMAIN}"
  local ssl_status="disabled"
  local queue_status="disabled"
  local db_status="-"
  local db_user_status="-"
  local credential_file="/root/laravel-deploy/credentials/${DOMAIN}.db.env"

  [[ "$WITH_SSL" == true ]] && ssl_status="enabled"
  [[ "$WITH_QUEUE" == true ]] && queue_status="enabled"
  [[ -n "$DB_NAME" ]] && db_status="$DB_NAME"
  [[ -n "$DB_USER" ]] && db_user_status="$DB_USER"

  cat <<EOF

Site summary:
  domain:          ${DOMAIN}
  aliases:         ${ALIASES:-"-"}
  path:            ${SITE_PATH}
  database:        ${db_status}
  database user:   ${db_user_status}
  credentials:     $([[ -f "$credential_file" ]] && echo "$credential_file" || echo "-")
  nginx file:      ${nginx_file}
  SSL:             ${ssl_status}
  queue:           ${queue_status}
EOF
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  create_project_path
  create_database
  create_nginx_site
  set_permissions
  enable_ssl
  enable_queue
  print_summary
}

main "$@"
