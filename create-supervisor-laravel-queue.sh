#!/usr/bin/env bash
set -euo pipefail

NAME=""
SITE_PATH=""
PHP_VERSION="8.3"
RUN_USER="www-data"
WORKERS="1"

usage() {
  cat <<'USAGE'
Usage: sudo bash create-supervisor-laravel-queue.sh --name=example.com --path=/var/www/example.com [options]

Options:
  --php=8.3         PHP version. Default: 8.3
  --user=www-data   Linux user for queue worker. Default: www-data
  --workers=1       Number of queue workers. Default: 1
  -h, --help        Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --name=*) NAME="${arg#*=}" ;;
    --path=*) SITE_PATH="${arg#*=}" ;;
    --php=*) PHP_VERSION="${arg#*=}" ;;
    --user=*) RUN_USER="${arg#*=}" ;;
    --workers=*) WORKERS="${arg#*=}" ;;
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

validate_input() {
  [[ -n "$NAME" ]] || error "--name is required"
  [[ -n "$SITE_PATH" ]] || error "--path is required"
  [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || error "--name may only contain letters, numbers, dot, underscore, and dash"
  [[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || error "--php must look like 8.3"
  [[ "$WORKERS" =~ ^[0-9]+$ ]] || error "--workers must be a number"
  (( WORKERS >= 1 )) || error "--workers must be at least 1"
  [[ -d "$SITE_PATH" ]] || error "Project path not found: $SITE_PATH"
  [[ -f "${SITE_PATH}/artisan" ]] || warn "artisan not found in $SITE_PATH; queue will fail until Laravel is installed"
  id "$RUN_USER" >/dev/null 2>&1 || error "Linux user not found: $RUN_USER"
}

main() {
  validate_input

  local php_bin="/usr/bin/php${PHP_VERSION}"
  if [[ ! -x "$php_bin" ]]; then
    php_bin="$(command -v php || true)"
  fi
  [[ -n "$php_bin" && -x "$php_bin" ]] || error "PHP binary not found for version ${PHP_VERSION}"

  local program_name="${NAME}-queue"
  local conf_file="/etc/supervisor/conf.d/${program_name}.conf"
  local log_file="/var/log/supervisor/${program_name}.log"

  info "Creating Supervisor queue config: $conf_file"
  write_file_if_changed "$conf_file" 0644 <<EOF
[program:${program_name}]
process_name=%(program_name)s_%(process_num)02d
command=${php_bin} artisan queue:work redis --sleep=3 --tries=3 --timeout=120
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
