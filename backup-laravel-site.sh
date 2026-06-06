#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
BACKUP_ALL=false
BACKUP_ROOT="/root/backups/laravel"
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash backup-laravel-site.sh
  sudo bash backup-laravel-site.sh --domain=example.com
  sudo bash backup-laravel-site.sh --all

Options:
  --interactive
  --domain=example.com
  --all
  --backup-root=/root/backups/laravel
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --all) BACKUP_ALL=true ;;
    --backup-root=*) BACKUP_ROOT="${arg#*=}" ;;
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

pool_file_from_socket() {
  local socket="$1"
  local php_version="$2"
  local site_user="$3"
  local pool_file=""

  if [[ -n "$php_version" && -n "$site_user" && -f "/etc/php/${php_version}/fpm/pool.d/${site_user}.conf" ]]; then
    printf '%s' "/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"
    return
  fi

  if [[ -n "$php_version" && -d "/etc/php/${php_version}/fpm/pool.d" ]]; then
    pool_file="$(grep -RslF "listen = ${socket}" "/etc/php/${php_version}/fpm/pool.d" 2>/dev/null | head -n 1 || true)"
  fi

  printf '%s' "$pool_file"
}

env_get() {
  local env_file="$1"
  local key="$2"
  local value=""

  [[ -f "$env_file" ]] || return 0
  value="$(grep -E "^[[:space:]]*${key}=" "$env_file" | tail -n 1 | cut -d= -f2- || true)"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

find_site_by_domain() {
  local lookup="$1"
  local file server_names
  [[ -n "$lookup" ]] || return 0

  for file in /etc/nginx/sites-available/*; do
    [[ -f "$file" ]] || continue
    server_names="$(nginx_directive "server_name" "$file" | tr -d ';')"
    if [[ " ${server_names} " == *" ${lookup} "* ]]; then
      printf '%s' "$file"
      return
    fi
  done
}

list_site_files() {
  if [[ ! -d /etc/nginx/sites-available ]]; then
    error "/etc/nginx/sites-available not found. Is Nginx installed?"
  fi

  find /etc/nginx/sites-available -maxdepth 1 -type f ! -name default | sort
}

safe_domain_dir_name() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/-}"
  printf '%s' "$value"
}

copy_if_exists() {
  local source="$1"
  local target="$2"
  local mode="${3:-0600}"

  if [[ ! -f "$source" ]]; then
    warn "File not found, skipping: $source"
    return
  fi

  install -D -m "$mode" "$source" "$target"
  success "Backed up $source"
}

backup_database() {
  local db_name="$1"
  local backup_dir="$2"
  local dump_file="${backup_dir}/database/database.sql.gz"

  if [[ -z "$db_name" ]]; then
    warn "DB_DATABASE not found; skipping database backup"
    return
  fi

  [[ "$db_name" =~ ^[A-Za-z0-9_]+$ ]] || error "Unsafe database name in .env: $db_name"
  command -v mysqldump >/dev/null 2>&1 || error "mysqldump not found. Install mariadb-client first."
  command -v gzip >/dev/null 2>&1 || error "gzip not found."

  install -d -m 0700 "$(dirname "$dump_file")"
  info "Backing up database ${db_name}"
  mysqldump --single-transaction --quick --routines --triggers "$db_name" | gzip -c > "$dump_file"
  chmod 0600 "$dump_file"
  success "Database dump written: $dump_file"
}

backup_storage_public() {
  local project_path="$1"
  local backup_dir="$2"
  local source_dir="${project_path}/storage/app/public"
  local archive="${backup_dir}/storage-app-public.tar.gz"

  if [[ ! -d "$source_dir" ]]; then
    warn "storage/app/public not found; skipping uploaded files backup"
    return
  fi

  command -v tar >/dev/null 2>&1 || error "tar not found."
  info "Backing up storage/app/public"
  tar -C "$project_path" -czf "$archive" storage/app/public
  chmod 0600 "$archive"
  success "Storage archive written: $archive"
}

write_manifest() {
  local manifest="$1"
  local domain="$2"
  local aliases="$3"
  local project_path="$4"
  local nginx_file="$5"
  local php_version="$6"
  local site_user="$7"
  local pool_file="$8"
  local db_name="$9"
  local app_url="${10}"
  local timestamp="${11}"

  cat > "$manifest" <<EOF
BACKUP_CREATED_AT=${timestamp}
DOMAIN=${domain}
ALIASES=${aliases}
PROJECT_PATH=${project_path}
NGINX_FILE=${nginx_file}
PHP_VERSION=${php_version}
SITE_USER=${site_user}
PHP_FPM_POOL=${pool_file}
DB_DATABASE=${db_name}
APP_URL=${app_url}
EOF
  chmod 0600 "$manifest"
}

backup_site_file() {
  local site_file="$1"
  local timestamp="$2"
  local server_names root_path domain aliases project_path socket php_version site_user pool_file
  local env_file db_name app_url safe_domain backup_dir

  server_names="$(nginx_directive "server_name" "$site_file" | tr -d ';')"
  root_path="$(nginx_directive "root" "$site_file")"
  socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$site_file" | head -n 1)"

  [[ -n "$server_names" ]] || return 0
  domain="$(awk '{print $1}' <<<"$server_names")"
  aliases="$(awk '{$1=""; sub(/^[[:space:]]+/, ""); print}' <<<"$server_names")"
  validate_domain "$domain" || error "Invalid domain detected in ${site_file}: $domain"

  project_path="$(project_path_from_root "$root_path")"
  php_version="$(php_version_from_socket "$socket")"
  site_user="$(site_user_from_socket "$socket" "$php_version")"
  if [[ -z "$site_user" && -e "$project_path" ]]; then
    site_user="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
  fi
  pool_file="$(pool_file_from_socket "$socket" "$php_version" "$site_user")"

  env_file="${project_path}/.env"
  db_name="$(env_get "$env_file" "DB_DATABASE")"
  app_url="$(env_get "$env_file" "APP_URL")"

  safe_domain="$(safe_domain_dir_name "$domain")"
  backup_dir="${BACKUP_ROOT%/}/${safe_domain}/${timestamp}"
  install -d -m 0700 "$backup_dir"

  info "Starting backup for ${domain}"
  write_manifest "${backup_dir}/manifest.env" "$domain" "$aliases" "$project_path" "$site_file" "$php_version" "$site_user" "$pool_file" "$db_name" "$app_url" "$timestamp"
  copy_if_exists "$env_file" "${backup_dir}/env/.env" 0600
  backup_storage_public "$project_path" "$backup_dir"
  copy_if_exists "$site_file" "${backup_dir}/nginx/site.conf" 0600
  if [[ -n "$pool_file" ]]; then
    copy_if_exists "$pool_file" "${backup_dir}/php-fpm/pool.conf" 0600
  else
    warn "PHP-FPM pool not detected; skipping pool backup"
  fi
  backup_database "$db_name" "$backup_dir"

  ln -sfn "$timestamp" "${BACKUP_ROOT%/}/${safe_domain}/latest"
  success "Backup complete for ${domain}: ${backup_dir}"
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain or --all for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel backup wizard
Press Enter to accept the value in brackets.

INTRO

  if prompt_yes_no "Backup semua website?" "n"; then
    BACKUP_ALL=true
  else
    DOMAIN="$(prompt_text "Domain website" "$DOMAIN")"
  fi

  BACKUP_ROOT="$(prompt_text "Folder root backup" "$BACKUP_ROOT")"
}

validate_input() {
  [[ "$BACKUP_ROOT" == /* ]] || error "--backup-root must be an absolute path"

  if [[ "$BACKUP_ALL" == true && -n "$DOMAIN" ]]; then
    error "Use either --all or --domain, not both"
  fi

  if [[ "$BACKUP_ALL" != true ]]; then
    [[ -n "$DOMAIN" ]] || error "--domain is required, or use --all"
    validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"
  fi
}

main() {
  local timestamp site_file files=()

  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input

  timestamp="$(date +%Y%m%d%H%M%S)"
  install -d -m 0700 "$BACKUP_ROOT"

  if [[ "$BACKUP_ALL" == true ]]; then
    while IFS= read -r site_file; do
      files+=("$site_file")
    done < <(list_site_files)

    if (( ${#files[@]} == 0 )); then
      warn "No Nginx site files found"
      return
    fi
  else
    site_file="$(find_site_by_domain "$DOMAIN")"
    [[ -n "$site_file" ]] || error "Nginx site not found for domain: $DOMAIN"
    files+=("$site_file")
  fi

  for site_file in "${files[@]}"; do
    backup_site_file "$site_file" "$timestamp"
  done
}

main "$@"
