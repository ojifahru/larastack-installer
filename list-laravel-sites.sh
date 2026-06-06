#!/usr/bin/env bash
set -euo pipefail

DOMAIN_FILTER=""
SUMMARY=false
DETAILS=false
JSON=false
JSON_FIRST=true

usage() {
  cat <<'USAGE'
Usage:
  sudo bash list-laravel-sites.sh [options]

Options:
  --summary              Show compact table per site (default)
  --details              Show detailed block per site
  --json                 Show machine-readable JSON array
  --domain=example.com   Show only one domain
  -h, --help             Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --summary) SUMMARY=true ;;
    --details) DETAILS=true ;;
    --json) JSON=true ;;
    --domain=*) DOMAIN_FILTER="${arg#*=}" ;;
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
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

nginx_directive() {
  local directive="$1"
  local file="$2"
  sed -nE "s/^[[:space:]]*${directive}[[:space:]]+([^;]+);.*/\1/p" "$file" | head -n 1
}

normalize_dash() {
  local value="${1:-}"
  [[ -n "$value" ]] && printf '%s' "$value" || printf '%s' "-"
}

truncate_value() {
  local value="${1:-}"
  local max="${2:-20}"

  [[ -n "$value" ]] || value="-"
  if (( ${#value} > max )); then
    printf '%s' "${value:0:max-1}~"
  else
    printf '%s' "$value"
  fi
}

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_value() {
  printf '"%s"' "$(json_escape "${1:-}")"
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

file_exists_status() {
  local path="$1"
  [[ -e "$path" ]] && printf '%s' "yes" || printf '%s' "no"
}

symlink_enabled_status() {
  local site_file="$1"
  local enabled_file

  for enabled_file in /etc/nginx/sites-enabled/*; do
    [[ -L "$enabled_file" ]] || continue
    if [[ "$(readlink -f "$enabled_file")" == "$(readlink -f "$site_file")" ]]; then
      printf '%s' "yes"
      return
    fi
  done

  printf '%s' "no"
}

project_path_from_root() {
  local root_path="$1"
  if [[ "$root_path" == */public ]]; then
    printf '%s' "${root_path%/public}"
  else
    printf '%s' "$root_path"
  fi
}

site_user_from_socket() {
  local socket="$1"
  local php_version="$2"
  local value=""

  value="$(sed -nE "s#^/run/php/php${php_version}-fpm-([A-Za-z0-9._-]+)\.sock\$#\1#p" <<<"$socket")"
  printf '%s' "$value"
}

php_version_from_socket() {
  local socket="$1"
  grep -oE 'php[0-9]+\.[0-9]+' <<<"$socket" 2>/dev/null | head -n 1 | sed 's/^php//' || true
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

pool_user() {
  local pool_file="$1"
  [[ -f "$pool_file" ]] || return 0
  sed -nE 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$pool_file" | head -n 1
}

git_info() {
  local project_path="$1"
  local site_user="$2"
  local key="$3"
  local value=""

  [[ -d "${project_path}/.git" ]] || return 0

  if [[ -n "$site_user" && "$site_user" != "-" ]] && id "$site_user" >/dev/null 2>&1; then
    value="$(sudo -H -u "$site_user" git -C "$project_path" config --get "$key" 2>/dev/null || true)"
  else
    value="$(git -C "$project_path" config --get "$key" 2>/dev/null || true)"
  fi

  printf '%s' "$value"
}

git_branch() {
  local project_path="$1"
  local site_user="$2"
  local value=""

  [[ -d "${project_path}/.git" ]] || return 0

  if [[ -n "$site_user" && "$site_user" != "-" ]] && id "$site_user" >/dev/null 2>&1; then
    value="$(sudo -H -u "$site_user" git -C "$project_path" branch --show-current 2>/dev/null || true)"
  else
    value="$(git -C "$project_path" branch --show-current 2>/dev/null || true)"
  fi

  printf '%s' "$value"
}

laravel_version() {
  local project_path="$1"
  local site_user="$2"
  local php_version="$3"
  local php_bin="php${php_version}"
  local value=""

  [[ -f "${project_path}/artisan" ]] || return 0
  command -v "$php_bin" >/dev/null 2>&1 || php_bin="php"

  if [[ -n "$site_user" && "$site_user" != "-" ]] && id "$site_user" >/dev/null 2>&1; then
    value="$(sudo -H -u "$site_user" bash -lc 'cd "$1" && "$2" artisan --version' bash "$project_path" "$php_bin" 2>/dev/null || true)"
  else
    value="$(cd "$project_path" && "$php_bin" artisan --version 2>/dev/null || true)"
  fi

  printf '%s' "$value"
}

supervisor_status() {
  local domain="$1"
  local program="${domain}-queue"
  local value=""

  command -v supervisorctl >/dev/null 2>&1 || return 0
  value="$(supervisorctl status "${program}:*" 2>/dev/null | awk '{print $2}' | sort -u | paste -sd ',' - || true)"
  printf '%s' "$value"
}

cert_status() {
  local domain="$1"
  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    printf '%s' "yes"
  else
    printf '%s' "no"
  fi
}

disk_usage() {
  local project_path="$1"
  [[ -d "$project_path" ]] || return 0
  du -sh "$project_path" 2>/dev/null | awk '{print $1}'
}

print_summary_header() {
  printf '%-26s %-5s %-3s %-5s %-8s %-12s %-10s %-16s %-7s %-28s\n' \
    "DOMAIN" "NGINX" "SSL" "PHP" "FPM" "SITE_USER" "QUEUE" "DATABASE" "DISK" "PROJECT"
  printf '%-26s %-5s %-3s %-5s %-8s %-12s %-10s %-16s %-7s %-28s\n' \
    "--------------------------" "-----" "---" "-----" "--------" "------------" "----------" "----------------" "-------" "----------------------------"
}

print_summary_row() {
  local domain="$1"
  local enabled="$2"
  local ssl="$3"
  local php_version="$4"
  local php_service_status="$5"
  local site_user="$6"
  local queue="$7"
  local db_name="$8"
  local disk="$9"
  local project_path="${10}"

  printf '%-26s %-5s %-3s %-5s %-8s %-12s %-10s %-16s %-7s %-28s\n' \
    "$(truncate_value "$domain" 26)" \
    "$(truncate_value "$enabled" 5)" \
    "$(truncate_value "$ssl" 3)" \
    "$(truncate_value "$php_version" 5)" \
    "$(truncate_value "$php_service_status" 8)" \
    "$(truncate_value "$site_user" 12)" \
    "$(truncate_value "$queue" 10)" \
    "$(truncate_value "$db_name" 16)" \
    "$(truncate_value "$disk" 7)" \
    "$(truncate_value "$project_path" 28)"
}

print_site() {
  local site_file="$1"
  local server_names root_path domain aliases enabled project_path socket php_version site_user pool_file pool_run_user owner group
  local env_file app_url db_name db_user credential_file repo branch queue ssl disk laravel php_service_status socket_status
  local public_key home_dir access_log error_log

  server_names="$(nginx_directive "server_name" "$site_file" | tr -d ';')"
  root_path="$(nginx_directive "root" "$site_file")"
  socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$site_file" | head -n 1)"

  [[ -n "$server_names" ]] || return 0
  domain="$(awk '{print $1}' <<<"$server_names")"
  aliases="$(awk '{$1=""; sub(/^[[:space:]]+/, ""); print}' <<<"$server_names")"

  if [[ -n "$DOMAIN_FILTER" && "$DOMAIN_FILTER" != "$domain" && " ${aliases} " != *" ${DOMAIN_FILTER} "* ]]; then
    return 0
  fi

  enabled="$(symlink_enabled_status "$site_file")"
  project_path="$(project_path_from_root "$root_path")"
  php_version="$(php_version_from_socket "$socket")"
  site_user="$(site_user_from_socket "$socket" "$php_version")"
  pool_file="$(pool_file_from_socket "$socket" "$php_version" "$site_user")"
  pool_run_user="$(pool_user "$pool_file")"

  if [[ -z "$site_user" ]]; then
    site_user="$pool_run_user"
  fi

  if [[ -z "$site_user" && -e "$project_path" ]]; then
    site_user="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
  fi

  owner="-"
  group="-"
  if [[ -e "$project_path" ]]; then
    owner="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
    group="$(stat -c '%G' "$project_path" 2>/dev/null || true)"
  fi

  home_dir="-"
  public_key="-"
  if [[ -n "$site_user" && "$site_user" != "-" ]] && id "$site_user" >/dev/null 2>&1; then
    home_dir="$(getent passwd "$site_user" | cut -d: -f6)"
    if [[ -n "$home_dir" ]]; then
      public_key="$(find "${home_dir}/.ssh" -maxdepth 1 -type f -name '*.pub' 2>/dev/null | head -n 1 || true)"
      [[ -n "$public_key" ]] || public_key="-"
    fi
  fi

  env_file="${project_path}/.env"
  app_url="$(env_get "$env_file" "APP_URL")"
  db_name="$(env_get "$env_file" "DB_DATABASE")"
  db_user="$(env_get "$env_file" "DB_USERNAME")"
  credential_file="/root/laravel-deploy/credentials/${domain}.db.env"
  repo="$(git_info "$project_path" "$site_user" "remote.origin.url")"
  branch="$(git_branch "$project_path" "$site_user")"
  queue="$(supervisor_status "$domain")"
  ssl="$(cert_status "$domain")"
  disk="$(disk_usage "$project_path")"
  laravel="$(laravel_version "$project_path" "$site_user" "$php_version")"
  socket_status="$(file_exists_status "$socket")"
  php_service_status="-"
  if [[ -n "$php_version" ]] && systemctl list-unit-files "php${php_version}-fpm.service" --no-pager --no-legend 2>/dev/null | grep -q "^php${php_version}-fpm.service"; then
    php_service_status="$(systemctl is-active "php${php_version}-fpm" 2>/dev/null || true)"
  fi

  access_log="/var/log/nginx/${domain}.access.log"
  error_log="/var/log/nginx/${domain}.error.log"

  if [[ "$JSON" == true ]]; then
    if [[ "$JSON_FIRST" == true ]]; then
      JSON_FIRST=false
    else
      printf ',\n'
    fi

    cat <<EOF
  {
    "domain": $(json_value "$domain"),
    "aliases": $(json_value "$aliases"),
    "enabled": $(json_value "$enabled"),
    "app_url": $(json_value "$app_url"),
    "ssl": $(json_value "$ssl"),
    "site_user": $(json_value "$site_user"),
    "home_directory": $(json_value "$home_dir"),
    "project_path": $(json_value "$project_path"),
    "project_owner": $(json_value "$owner"),
    "project_group": $(json_value "$group"),
    "disk_usage": $(json_value "$disk"),
    "ssh_public_key": $(json_value "$public_key"),
    "nginx_file": $(json_value "$site_file"),
    "nginx_root": $(json_value "$root_path"),
    "access_log": $(json_value "$access_log"),
    "error_log": $(json_value "$error_log"),
    "php_version": $(json_value "$php_version"),
    "php_fpm_service": $(json_value "$php_service_status"),
    "php_fpm_pool": $(json_value "$pool_file"),
    "php_fpm_user": $(json_value "$pool_run_user"),
    "php_fpm_socket": $(json_value "$socket"),
    "socket_exists": $(json_value "$socket_status"),
    "repository": $(json_value "$repo"),
    "git_branch": $(json_value "$branch"),
    "laravel": $(json_value "$laravel"),
    "database_name": $(json_value "$db_name"),
    "database_user": $(json_value "$db_user"),
    "credential_file": $(json_value "$([[ -f "$credential_file" ]] && echo "$credential_file" || echo "-")"),
    "queue_status": $(json_value "$queue")
  }
EOF
    return
  fi

  if [[ "$DETAILS" != true ]]; then
    print_summary_row \
      "$domain" \
      "$enabled" \
      "$ssl" \
      "$(normalize_dash "$php_version")" \
      "$(normalize_dash "$php_service_status")" \
      "$(normalize_dash "$site_user")" \
      "$(normalize_dash "$queue")" \
      "$(normalize_dash "$db_name")" \
      "$(normalize_dash "$disk")" \
      "$(normalize_dash "$project_path")"
    return
  fi

  cat <<EOF
Domain:          ${domain}
Aliases:         $(normalize_dash "$aliases")
Enabled:         ${enabled}
App URL:         $(normalize_dash "$app_url")
SSL:             ${ssl}

Site user:       $(normalize_dash "$site_user")
Home directory:  $(normalize_dash "$home_dir")
Project path:    $(normalize_dash "$project_path")
Project owner:   $(normalize_dash "$owner"):$(normalize_dash "$group")
Disk usage:      $(normalize_dash "$disk")
SSH public key:  $(normalize_dash "$public_key")

Nginx file:      ${site_file}
Nginx root:      $(normalize_dash "$root_path")
Access log:      ${access_log}
Error log:       ${error_log}

PHP version:     $(normalize_dash "$php_version")
PHP-FPM service: $(normalize_dash "$php_service_status")
PHP-FPM pool:    $(normalize_dash "$pool_file")
PHP-FPM user:    $(normalize_dash "$pool_run_user")
PHP-FPM socket:  $(normalize_dash "$socket")
Socket exists:   ${socket_status}

Repository:      $(normalize_dash "$repo")
Git branch:      $(normalize_dash "$branch")
Laravel:         $(normalize_dash "$laravel")

Database name:   $(normalize_dash "$db_name")
Database user:   $(normalize_dash "$db_user")
Credential file: $([[ -f "$credential_file" ]] && echo "$credential_file" || echo "-")

Queue status:    $(normalize_dash "$queue")
EOF
  printf '%s\n\n' "----------------------------------------------------------------"
}

main() {
  local files=()
  local file

  if [[ "$SUMMARY" == true && "$DETAILS" == true ]]; then
    error "Use either --summary or --details, not both"
  fi

  if [[ "$JSON" == true && ( "$SUMMARY" == true || "$DETAILS" == true ) ]]; then
    error "Use --json without --summary or --details"
  fi

  if [[ ! -d /etc/nginx/sites-available ]]; then
    error "/etc/nginx/sites-available not found. Is Nginx installed?"
  fi

  while IFS= read -r file; do
    files+=("$file")
  done < <(find /etc/nginx/sites-available -maxdepth 1 -type f ! -name default | sort)

  if (( ${#files[@]} == 0 )); then
    if [[ "$JSON" == true ]]; then
      printf '[]\n'
      return
    fi
    warn "No Nginx site files found in /etc/nginx/sites-available"
    return
  fi

  if [[ "$JSON" == true ]]; then
    printf '[\n'
  fi

  if [[ "$JSON" != true && "$DETAILS" != true ]]; then
    print_summary_header
  fi

  for file in "${files[@]}"; do
    print_site "$file"
  done

  if [[ "$JSON" == true ]]; then
    printf '\n]\n'
  fi
}

main "$@"
