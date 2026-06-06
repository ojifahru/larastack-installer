#!/usr/bin/env bash
set -euo pipefail

NAME=""
DOMAIN=""
SITE_PATH=""
PHP_VERSION=""
DETECTED_PHP_VERSION=""
RUN_USER=""
WORKERS="1"
QUEUE_CONNECTION="redis"
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash create-supervisor-laravel-queue.sh
  sudo bash create-supervisor-laravel-queue.sh --domain=example.com [options]

Options:
  --interactive
  --domain=example.com
  --name=example.com
  --path=/home/example/public_html
  --php=8.3
  --user=example     Linux user for queue worker. Default: project owner
  --workers=1        Number of queue workers. Default: 1
  --connection=redis Queue connection passed to queue:work. Default: redis
  -h, --help         Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --name=*) NAME="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --user=*) RUN_USER="${arg#*=}" ;;
    --workers=*) WORKERS="${arg#*=}" ;;
    --connection=*) QUEUE_CONNECTION="${arg#*=}" ;;
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
  local lookup="${DOMAIN:-$NAME}"
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

first_public_html_path() {
  if [[ -d /home ]]; then
    find /home -mindepth 2 -maxdepth 2 -type d -name public_html 2>/dev/null | sort | head -n 1 || true
  fi
}

detect_site_context() {
  local nginx_file="" server_names root_path socket detected_user

  nginx_file="$(find_nginx_site_by_domain)"
  if [[ -z "$nginx_file" ]]; then
    nginx_file="$(find_nginx_site_by_path)"
  fi

  if [[ -n "$nginx_file" ]]; then
    server_names="$(nginx_directive "server_name" "$nginx_file" | tr -d ';')"
    root_path="$(nginx_directive "root" "$nginx_file")"
    socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$nginx_file" | head -n 1)"

    [[ -n "$DOMAIN" ]] || DOMAIN="$(awk '{print $1}' <<<"$server_names")"
    [[ -n "$NAME" ]] || NAME="$DOMAIN"
    [[ -n "$SITE_PATH" || -z "$root_path" ]] || SITE_PATH="$(project_path_from_root "$root_path")"

    DETECTED_PHP_VERSION="$(php_version_from_socket "$socket")"
    if [[ -z "$PHP_VERSION" && -n "$DETECTED_PHP_VERSION" ]]; then
      PHP_VERSION="$DETECTED_PHP_VERSION"
    fi

    detected_user="$(site_user_from_socket "$socket" "${DETECTED_PHP_VERSION:-$PHP_VERSION}")"
    if [[ -z "$RUN_USER" && -n "$detected_user" ]]; then
      RUN_USER="$detected_user"
    fi
  fi

  if [[ -z "$SITE_PATH" && -n "$RUN_USER" ]]; then
    SITE_PATH="/home/${RUN_USER}/public_html"
  fi

  if [[ -z "$SITE_PATH" && "$INTERACTIVE" == true && -z "$DOMAIN" && -z "$NAME" ]]; then
    SITE_PATH="$(first_public_html_path)"
  fi

  if [[ -z "$RUN_USER" && -n "$SITE_PATH" && -e "$SITE_PATH" ]]; then
    RUN_USER="$(stat -c '%U' "$SITE_PATH" 2>/dev/null || true)"
  fi

  if [[ -z "$NAME" ]]; then
    NAME="${DOMAIN:-$RUN_USER}"
  fi

  if [[ -z "$PHP_VERSION" ]]; then
    PHP_VERSION="8.3"
  fi
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain/--path and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel queue wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_text "Domain site. Kosongkan jika pakai path" "$DOMAIN")"
  detect_site_context

  SITE_PATH="$(prompt_required "Path project Laravel" "$SITE_PATH")"
  detect_site_context

  NAME="$(prompt_required "Nama queue/site" "$NAME")"
  RUN_USER="$(prompt_required "User Linux untuk worker" "$RUN_USER")"
  PHP_VERSION="$(prompt_required "Versi PHP" "$PHP_VERSION")"
  QUEUE_CONNECTION="$(prompt_required "Queue connection" "$QUEUE_CONNECTION")"
  WORKERS="$(prompt_required "Jumlah worker" "$WORKERS")"

  cat > /dev/tty <<EOF

Ringkasan queue:
  name:       ${NAME}
  domain:     ${DOMAIN:-"-"}
  path:       ${SITE_PATH}
  PHP:        ${PHP_VERSION}
  user:       ${RUN_USER}
  connection: ${QUEUE_CONNECTION}
  workers:    ${WORKERS}
  log:        /var/log/supervisor/${NAME}/queue.log

EOF

  if ! prompt_yes_no "Lanjut buat/update Supervisor queue?" "y"; then
    error "Queue setup cancelled"
  fi
}

validate_input() {
  detect_site_context

  [[ -n "$NAME" ]] || error "--name or --domain is required"
  [[ -n "$SITE_PATH" ]] || error "--path is required, or supply --domain for auto-detect"
  [[ -n "$RUN_USER" ]] || error "Could not detect project owner. Use --user=example."
  [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || error "--name may only contain letters, numbers, dot, underscore, and dash"
  [[ "$SITE_PATH" == /* ]] || error "--path must be an absolute path"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  [[ "$WORKERS" =~ ^[0-9]+$ ]] || error "--workers must be a number"
  (( WORKERS >= 1 )) || error "--workers must be at least 1"
  [[ "$QUEUE_CONNECTION" =~ ^[A-Za-z0-9_-]+$ ]] || error "--connection may only contain letters, numbers, underscore, and dash"
  [[ -d "$SITE_PATH" ]] || error "Project path not found: $SITE_PATH"
  [[ -f "${SITE_PATH}/artisan" ]] || warn "artisan not found in $SITE_PATH; queue will fail until Laravel is installed"
  id "$RUN_USER" >/dev/null 2>&1 || error "Linux user not found: $RUN_USER"

  if [[ -n "$DETECTED_PHP_VERSION" && "$PHP_VERSION" != "$DETECTED_PHP_VERSION" ]]; then
    error "Site Nginx/PHP-FPM config uses PHP ${DETECTED_PHP_VERSION}, but --php=${PHP_VERSION} was supplied."
  fi

  if [[ "$(stat -c '%U' "$SITE_PATH")" != "$RUN_USER" ]]; then
    warn "Project owner is $(stat -c '%U' "$SITE_PATH"), but queue user is ${RUN_USER}"
  fi
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input

  local php_bin="/usr/bin/php${PHP_VERSION}"
  if [[ ! -x "$php_bin" ]]; then
    error "PHP binary not found: $php_bin. Install PHP ${PHP_VERSION} first."
  fi

  if ! command -v supervisorctl >/dev/null 2>&1; then
    error "supervisorctl not found. Install Supervisor first."
  fi

  local program_name="${NAME}-queue"
  local conf_file="/etc/supervisor/conf.d/${program_name}.conf"
  local log_dir="/var/log/supervisor/${NAME}"
  local log_file="${log_dir}/queue.log"

  install -d -m 0755 "$log_dir"

  info "Creating Supervisor queue config: $conf_file"
  write_file_if_changed "$conf_file" 0644 <<EOF
[program:${program_name}]
process_name=%(program_name)s_%(process_num)02d
command=${php_bin} artisan queue:work ${QUEUE_CONNECTION} --sleep=3 --tries=3 --timeout=120
directory=${SITE_PATH}
user=${RUN_USER}
numprocs=${WORKERS}
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=${log_file}
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=5
stopwaitsecs=130
environment=HOME="/home/${RUN_USER}",USER="${RUN_USER}"
EOF

  supervisorctl reread
  supervisorctl update

  if supervisorctl status "${program_name}:*" >/dev/null 2>&1; then
    supervisorctl restart "${program_name}:*" || true
  else
    supervisorctl start "${program_name}:*" || true
  fi

  supervisorctl status "${program_name}:*" || true
  success "Supervisor queue configured for ${NAME}"
}

main "$@"
