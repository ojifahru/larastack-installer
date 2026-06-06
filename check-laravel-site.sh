#!/usr/bin/env bash
set -euo pipefail

DOMAIN_FILTER=""
CHECK_ALL=false
NO_HTTP=false
FAIL_COUNT=0
WARN_COUNT=0
CURRENT_DOMAIN=""
NGINX_TEST_DONE=false

usage() {
  cat <<'USAGE'
Usage:
  sudo bash check-laravel-site.sh --domain=example.com
  sudo bash check-laravel-site.sh --all

Options:
  --domain=example.com
  --all
  --no-http    Skip external HTTP response check
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN_FILTER="${arg#*=}" ;;
    --all) CHECK_ALL=true ;;
    --no-http) NO_HTTP=true ;;
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

pass() {
  printf '[OK] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

error() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
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

symlink_enabled_status() {
  local site_file="$1"
  local enabled_file

  for enabled_file in /etc/nginx/sites-enabled/*; do
    [[ -L "$enabled_file" ]] || continue
    if [[ "$(readlink -f "$enabled_file")" == "$(readlink -f "$site_file")" ]]; then
      return 0
    fi
  done

  return 1
}

find_site_by_domain() {
  local lookup="$1"
  local file server_names

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

check_nginx_global() {
  if [[ "$NGINX_TEST_DONE" == true ]]; then
    return
  fi

  NGINX_TEST_DONE=true
  if ! command -v nginx >/dev/null 2>&1; then
    fail "Nginx command not found"
    return
  fi

  if nginx -t >/tmp/larastack-nginx-check.log 2>&1; then
    pass "Nginx config test passed"
  else
    fail "Nginx config test failed: $(tail -n 1 /tmp/larastack-nginx-check.log)"
  fi
}

check_nginx_site() {
  local site_file="$1"
  local root_path="$2"

  [[ -f "$site_file" ]] && pass "Nginx site file exists: $site_file" || fail "Nginx site file missing: $site_file"
  symlink_enabled_status "$site_file" && pass "Nginx site is enabled" || warn "Nginx site is not enabled"

  if [[ -n "$root_path" && -d "$root_path" ]]; then
    pass "Nginx root exists: $root_path"
  else
    fail "Nginx root missing: ${root_path:-"-"}"
  fi
}

check_php_fpm() {
  local php_version="$1"
  local pool_file="$2"
  local socket="$3"

  [[ -n "$php_version" ]] && pass "PHP version detected: $php_version" || fail "PHP version could not be detected from socket"

  if [[ -n "$pool_file" && -f "$pool_file" ]]; then
    pass "PHP-FPM pool exists: $pool_file"
  else
    fail "PHP-FPM pool missing"
  fi

  if [[ -n "$php_version" ]] && systemctl list-unit-files "php${php_version}-fpm.service" --no-pager --no-legend 2>/dev/null | grep -q "^php${php_version}-fpm.service"; then
    if systemctl is-active --quiet "php${php_version}-fpm"; then
      pass "php${php_version}-fpm is active"
    else
      fail "php${php_version}-fpm is not active"
    fi
  else
    fail "php${php_version}-fpm service not found"
  fi

  if [[ -n "$socket" && -S "$socket" ]]; then
    pass "PHP-FPM socket exists: $socket"
  else
    fail "PHP-FPM socket missing: ${socket:-"-"}"
  fi
}

check_permissions() {
  local project_path="$1"
  local site_user="$2"
  local owner mode

  if [[ ! -d "$project_path" ]]; then
    fail "Project path missing: $project_path"
    return
  fi

  owner="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
  if [[ -n "$site_user" && "$owner" == "$site_user" ]]; then
    pass "Project owner matches site user: $owner"
  else
    warn "Project owner is ${owner:-"-"}, expected ${site_user:-"-"}"
  fi

  if [[ -d "${project_path}/storage" && -w "${project_path}/storage" ]]; then
    pass "storage directory exists"
  else
    warn "storage directory missing or not writable by root check"
  fi

  if [[ -d "${project_path}/bootstrap/cache" ]]; then
    pass "bootstrap/cache exists"
  else
    warn "bootstrap/cache missing"
  fi

  if [[ -f "${project_path}/.env" ]]; then
    mode="$(stat -c '%a' "${project_path}/.env" 2>/dev/null || true)"
    if [[ "$mode" =~ ^[0-7]*[0-4][0-0]$ || "$mode" == "600" || "$mode" == "640" ]]; then
      pass ".env permission looks restricted: $mode"
    else
      warn ".env permission may be too open: $mode"
    fi
  fi
}

check_env() {
  local env_file="$1"
  local handoff_mode="${2:-false}"
  local app_key app_env app_debug db_name db_user db_host

  if [[ ! -f "$env_file" ]]; then
    if [[ "$handoff_mode" == true ]]; then
      warn ".env not found yet; handoff slot is waiting for website files"
    else
      fail ".env not found: $env_file"
    fi
    return
  fi

  app_key="$(env_get "$env_file" "APP_KEY")"
  app_env="$(env_get "$env_file" "APP_ENV")"
  app_debug="$(env_get "$env_file" "APP_DEBUG")"
  db_name="$(env_get "$env_file" "DB_DATABASE")"
  db_user="$(env_get "$env_file" "DB_USERNAME")"
  db_host="$(env_get "$env_file" "DB_HOST")"

  [[ -n "$app_key" ]] && pass "APP_KEY is set" || fail "APP_KEY is empty"
  [[ "$app_env" == "production" ]] && pass "APP_ENV=production" || warn "APP_ENV is ${app_env:-"-"}"
  [[ "$app_debug" == "false" ]] && pass "APP_DEBUG=false" || warn "APP_DEBUG is ${app_debug:-"-"}"
  [[ -n "$db_name" ]] && pass "DB_DATABASE is set" || warn "DB_DATABASE is empty"
  [[ -n "$db_user" ]] && pass "DB_USERNAME is set" || warn "DB_USERNAME is empty"
  [[ -n "$db_host" ]] && pass "DB_HOST is set" || warn "DB_HOST is empty"
}

check_database_via_artisan() {
  local project_path="$1"
  local site_user="$2"
  local php_version="$3"
  local php_bin="php${php_version}"

  if [[ ! -f "${project_path}/artisan" ]]; then
    warn "artisan not found; skipping database check via Artisan"
    return
  fi

  command -v "$php_bin" >/dev/null 2>&1 || php_bin="php"
  command -v "$php_bin" >/dev/null 2>&1 || {
    fail "PHP binary not found for Artisan database check"
    return
  }

  if [[ -n "$site_user" ]] && id "$site_user" >/dev/null 2>&1; then
    if sudo -H -u "$site_user" bash -lc 'cd "$1" && "$2" artisan migrate:status --no-interaction' bash "$project_path" "$php_bin" >/dev/null 2>&1; then
      pass "Database connection works via Artisan"
    else
      fail "Database check via Artisan failed"
    fi
  else
    if (cd "$project_path" && "$php_bin" artisan migrate:status --no-interaction) >/dev/null 2>&1; then
      pass "Database connection works via Artisan"
    else
      fail "Database check via Artisan failed"
    fi
  fi
}

check_queue() {
  local domain="$1"
  local status

  if ! command -v supervisorctl >/dev/null 2>&1; then
    warn "supervisorctl not found; skipping queue check"
    return
  fi

  status="$(supervisorctl status "${domain}-queue:*" 2>/dev/null || true)"
  if [[ -z "$status" ]]; then
    warn "No Supervisor queue found for ${domain}"
    return
  fi

  if awk '{print $2}' <<<"$status" | grep -qv RUNNING; then
    warn "Queue exists but not all workers are RUNNING"
    printf '%s\n' "$status"
  else
    pass "Queue workers are RUNNING"
  fi
}

check_ssl() {
  local domain="$1"
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local end_epoch now days

  if [[ ! -f "$cert" ]]; then
    warn "SSL certificate not found for ${domain}"
    return
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found; skipping SSL expiry check"
    return
  fi

  end_epoch="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2- | xargs -I{} date -d "{}" +%s 2>/dev/null || true)"
  now="$(date +%s)"
  if [[ -z "$end_epoch" ]]; then
    warn "Could not parse SSL expiry for ${domain}"
    return
  fi

  days=$(( (end_epoch - now) / 86400 ))
  if (( days < 0 )); then
    fail "SSL certificate expired ${days#-} days ago"
  elif (( days < 14 )); then
    warn "SSL certificate expires in ${days} days"
  else
    pass "SSL certificate valid for ${days} days"
  fi
}

check_http() {
  local domain="$1"
  local scheme="$2"
  local code

  if [[ "$NO_HTTP" == true ]]; then
    warn "Skipping HTTP check because --no-http was supplied"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; skipping HTTP check"
    return
  fi

  code="$(curl -k -L -o /dev/null -s -w '%{http_code}' --max-time 10 "${scheme}://${domain}" || true)"
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    pass "HTTP response ${scheme}://${domain}: ${code}"
  else
    fail "HTTP response ${scheme}://${domain}: ${code:-failed}"
  fi
}

check_site() {
  local site_file="$1"
  local server_names root_path domain aliases project_path socket php_version site_user pool_file env_file scheme
  local home_dir handoff_file handoff_mode=false

  server_names="$(nginx_directive "server_name" "$site_file" | tr -d ';')"
  root_path="$(nginx_directive "root" "$site_file")"
  socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$site_file" | head -n 1)"

  [[ -n "$server_names" ]] || return 0
  domain="$(awk '{print $1}' <<<"$server_names")"
  aliases="$(awk '{$1=""; sub(/^[[:space:]]+/, ""); print}' <<<"$server_names")"

  if [[ -n "$DOMAIN_FILTER" && "$DOMAIN_FILTER" != "$domain" && " ${aliases} " != *" ${DOMAIN_FILTER} "* ]]; then
    return 0
  fi

  CURRENT_DOMAIN="$domain"
  validate_domain "$domain" || {
    fail "Invalid domain in Nginx config: $domain"
    return
  }

  project_path="$(project_path_from_root "$root_path")"
  php_version="$(php_version_from_socket "$socket")"
  site_user="$(site_user_from_socket "$socket" "$php_version")"
  if [[ -z "$site_user" && -e "$project_path" ]]; then
    site_user="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
  fi
  pool_file="$(pool_file_from_socket "$socket" "$php_version" "$site_user")"
  env_file="${project_path}/.env"

  if [[ -n "$site_user" ]] && id "$site_user" >/dev/null 2>&1; then
    home_dir="$(getent passwd "$site_user" | cut -d: -f6)"
    handoff_file="${home_dir}/site-info.env"
    if [[ -f "$handoff_file" && ! -f "${project_path}/artisan" ]]; then
      handoff_mode=true
    fi
  fi

  printf '\nChecking %s\n' "$domain"
  printf '%s\n' "----------------------------------------------------------------"
  if [[ "$handoff_mode" == true ]]; then
    pass "Handoff slot detected: ${handoff_file}"
  fi
  check_nginx_global
  check_nginx_site "$site_file" "$root_path"
  check_php_fpm "$php_version" "$pool_file" "$socket"
  check_permissions "$project_path" "$site_user"
  check_env "$env_file" "$handoff_mode"
  check_database_via_artisan "$project_path" "$site_user" "$php_version"
  check_queue "$domain"
  check_ssl "$domain"

  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    scheme="https"
  else
    scheme="http"
  fi
  check_http "$domain" "$scheme"
}

validate_input() {
  if [[ "$CHECK_ALL" == true && -n "$DOMAIN_FILTER" ]]; then
    error "Use either --all or --domain, not both"
  fi

  if [[ "$CHECK_ALL" != true ]]; then
    [[ -n "$DOMAIN_FILTER" ]] || error "--domain is required, or use --all"
    validate_domain "$DOMAIN_FILTER" || error "Invalid domain: $DOMAIN_FILTER"
  fi
}

main() {
  local files=()
  local file site_file

  validate_input

  if [[ "$CHECK_ALL" == true ]]; then
    while IFS= read -r file; do
      files+=("$file")
    done < <(list_site_files)
  else
    site_file="$(find_site_by_domain "$DOMAIN_FILTER")"
    [[ -n "$site_file" ]] || error "Nginx site not found for domain: $DOMAIN_FILTER"
    files+=("$site_file")
  fi

  if (( ${#files[@]} == 0 )); then
    warn "No Nginx site files found"
    exit 0
  fi

  for file in "${files[@]}"; do
    check_site "$file"
  done

  printf '\nSummary: %s fail(s), %s warning(s)\n' "$FAIL_COUNT" "$WARN_COUNT"
  if (( FAIL_COUNT > 0 )); then
    exit 1
  fi
}

main "$@"
