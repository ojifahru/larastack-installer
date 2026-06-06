#!/usr/bin/env bash
set -euo pipefail

DOMAIN=""
SITE_USER=""
PUBLIC_KEY=""
KEY_FILE=""
LOGIN_HOST=""
INTERACTIVE=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash grant-site-ssh-access.sh
  sudo bash grant-site-ssh-access.sh --domain=example.com --key-file=/tmp/manager.pub
  sudo bash grant-site-ssh-access.sh --domain=example.com --key='ssh-ed25519 AAAA... user@laptop'

Options:
  --interactive
  --domain=example.com
  --site-user=example
  --key='ssh-ed25519 AAAA... user@laptop'
  --key-file=/path/to/public.key
  --host=server.example.com
  -h, --help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --site-user=*) SITE_USER="${arg#*=}" ;;
    --key=*) PUBLIC_KEY="${arg#*=}" ;;
    --key-file=*) KEY_FILE="${arg#*=}" ;;
    --host=*) LOGIN_HOST="${arg#*=}" ;;
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

detect_site_user() {
  local nginx_file root_path socket php_version project_path detected_user

  [[ -n "$SITE_USER" ]] && return

  nginx_file="$(find_nginx_site_by_domain)"
  if [[ -z "$nginx_file" ]]; then
    return
  fi

  root_path="$(nginx_directive "root" "$nginx_file")"
  socket="$(sed -nE 's/^[[:space:]]*fastcgi_pass[[:space:]]+unix:([^;]+);.*/\1/p' "$nginx_file" | head -n 1)"
  php_version="$(php_version_from_socket "$socket")"
  detected_user="$(site_user_from_socket "$socket" "$php_version")"

  if [[ -n "$detected_user" ]]; then
    SITE_USER="$detected_user"
    return
  fi

  project_path="$(project_path_from_root "$root_path")"
  if [[ -e "$project_path" ]]; then
    SITE_USER="$(stat -c '%U' "$project_path" 2>/dev/null || true)"
  fi
}

validate_public_key() {
  local key="$1"
  [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

load_public_key() {
  if [[ -n "$KEY_FILE" ]]; then
    [[ -f "$KEY_FILE" ]] || error "Key file not found: $KEY_FILE"
    PUBLIC_KEY="$(head -n 1 "$KEY_FILE")"
  fi

  if [[ -z "$PUBLIC_KEY" && "$INTERACTIVE" == true ]]; then
    PUBLIC_KEY="$(prompt_text "Paste public SSH key pengelola")"
  fi

  PUBLIC_KEY="$(printf '%s' "$PUBLIC_KEY" | sed 's/[[:space:]]*$//')"
  [[ -n "$PUBLIC_KEY" ]] || error "Public key is required. Use --key or --key-file."
  validate_public_key "$PUBLIC_KEY" || error "Invalid SSH public key format"
}

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --domain, --key/--key-file for non-interactive use."

  cat > /dev/tty <<'INTRO'
Grant website SSH access wizard
Press Enter to accept the value in brackets.

INTRO

  DOMAIN="$(prompt_text "Domain website" "$DOMAIN")"
  detect_site_user
  SITE_USER="$(prompt_text "Site user" "$SITE_USER")"
  LOGIN_HOST="$(prompt_text "Host/IP untuk command login" "$LOGIN_HOST")"
}

ensure_no_sudo_access() {
  local group
  for group in sudo admin wheel; do
    if id -nG "$SITE_USER" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$group"; then
      warn "Removing ${SITE_USER} from ${group} group"
      gpasswd -d "$SITE_USER" "$group" >/dev/null 2>&1 || true
    fi
  done
}

default_login_host() {
  local host
  host="$(hostname -f 2>/dev/null || true)"
  if [[ -z "$host" || "$host" == localhost* ]]; then
    host="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s' "${host:-SERVER_IP}"
}

grant_access() {
  local home_dir ssh_dir authorized_keys

  home_dir="$(getent passwd "$SITE_USER" | cut -d: -f6)"
  [[ -n "$home_dir" ]] || error "Could not determine home directory for $SITE_USER"

  ssh_dir="${home_dir}/.ssh"
  authorized_keys="${ssh_dir}/authorized_keys"

  install -d -m 0700 "$ssh_dir"
  touch "$authorized_keys"

  if grep -Fxq "$PUBLIC_KEY" "$authorized_keys"; then
    success "Public key already exists in $authorized_keys"
  else
    printf '%s\n' "$PUBLIC_KEY" >> "$authorized_keys"
    success "Public key added to $authorized_keys"
  fi

  chown -R "$SITE_USER:$SITE_USER" "$ssh_dir"
  chmod 0700 "$ssh_dir"
  chmod 0600 "$authorized_keys"
}

validate_input() {
  if [[ -n "$DOMAIN" ]]; then
    validate_domain "$DOMAIN" || error "Invalid domain: $DOMAIN"
  fi

  detect_site_user
  [[ -n "$SITE_USER" ]] || error "Could not detect site user. Use --site-user=example."
  id "$SITE_USER" >/dev/null 2>&1 || error "Linux user not found: $SITE_USER"
}

main() {
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_input
  load_public_key
  ensure_no_sudo_access
  grant_access

  [[ -n "$LOGIN_HOST" ]] || LOGIN_HOST="$(default_login_host)"

  cat <<EOF

SSH access granted.
Login command:
  ssh ${SITE_USER}@${LOGIN_HOST}

EOF
}

main "$@"
