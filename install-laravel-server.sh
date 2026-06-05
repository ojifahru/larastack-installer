#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Jakarta}"
PHP_DEFAULT_VERSION="8.3"
INSTALL_PHP84=false
INSTALL_FAIL2BAN=false
INTERACTIVE=false
ASSUME_YES=false

if (( $# == 0 )); then
  INTERACTIVE=true
fi

usage() {
  cat <<'USAGE'
Usage:
  sudo bash install-laravel-server.sh
  sudo bash install-laravel-server.sh --yes [options]

Options:
  --interactive           Ask installation questions
  --yes                   Run with defaults and supplied options without questions
  --timezone=Asia/Jakarta  Set server timezone. Default: Asia/Jakarta
  --with-php84             Install PHP 8.4 if it is available from configured apt repositories
  --with-fail2ban          Install and enable Fail2ban
  -h, --help               Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --timezone=*) DEFAULT_TIMEZONE="${arg#*=}" ;;
    --with-php84) INSTALL_PHP84=true ;;
    --with-fail2ban) INSTALL_FAIL2BAN=true ;;
    --interactive) INTERACTIVE=true ;;
    --yes) ASSUME_YES=true; INTERACTIVE=false ;;
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
LOG_FILE="${LOG_DIR}/install.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
success() { printf '[OK] %s\n' "$*"; }
error() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

trap 'error "Installation failed at line ${LINENO}. See ${LOG_FILE} for details."' ERR

export DEBIAN_FRONTEND=noninteractive

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
  [[ -t 0 && -t 1 ]]
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

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --yes and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel server install wizard
Press Enter to accept the value in brackets.

INTRO

  DEFAULT_TIMEZONE="$(prompt_text "Timezone server" "$DEFAULT_TIMEZONE")"

  if [[ "$INSTALL_PHP84" != true ]] && prompt_yes_no "Install PHP 8.4 juga jika tersedia dari apt repository?" "n"; then
    INSTALL_PHP84=true
  fi

  if [[ "$INSTALL_FAIL2BAN" != true ]] && prompt_yes_no "Install dan aktifkan Fail2ban?" "y"; then
    INSTALL_FAIL2BAN=true
  fi

  cat > /dev/tty <<EOF

Ringkasan install:
  OS target:     Ubuntu 24.04
  timezone:      ${DEFAULT_TIMEZONE}
  PHP default:   ${PHP_DEFAULT_VERSION}
  PHP 8.4:       ${INSTALL_PHP84}
  Fail2ban:      ${INSTALL_FAIL2BAN}
  log:           ${LOG_FILE}

EOF

  if ! prompt_yes_no "Lanjut install stack production Laravel sekarang?" "y"; then
    error "Installation cancelled"
  fi
}

apt_install() {
  apt-get install -y "$@"
}

check_os() {
  [[ -r /etc/os-release ]] || error "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || error "This script supports Ubuntu only. Detected: ${ID:-unknown}"
  [[ "${VERSION_ID:-}" == "24.04" ]] || error "This script supports Ubuntu 24.04 only. Detected: ${VERSION_ID:-unknown}"

  success "Detected Ubuntu ${VERSION_ID}"
}

set_timezone() {
  if ! command -v timedatectl >/dev/null 2>&1; then
    warn "timedatectl not found; skipping timezone setup"
    return
  fi

  local current_timezone
  current_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"

  if [[ "$current_timezone" == "$DEFAULT_TIMEZONE" ]]; then
    success "Timezone already set to $DEFAULT_TIMEZONE"
    return
  fi

  timedatectl set-timezone "$DEFAULT_TIMEZONE"
  success "Timezone set to $DEFAULT_TIMEZONE"
}

install_base_packages() {
  info "Updating apt package index"
  apt-get update

  info "Upgrading installed packages"
  apt-get upgrade -y

  info "Installing base packages"
  apt_install \
    curl wget git unzip zip nano htop ca-certificates lsb-release \
    software-properties-common apt-transport-https gnupg openssl ufw

  info "Ensuring Ubuntu universe repository is enabled"
  add-apt-repository -y universe
  apt-get update
}

install_nginx() {
  info "Installing Nginx from Ubuntu apt repository"
  apt_install nginx
}

install_php_packages() {
  local version="$1"
  local packages=(
    "php${version}-fpm"
    "php${version}-cli"
    "php${version}-common"
    "php${version}-mysql"
    "php${version}-mbstring"
    "php${version}-xml"
    "php${version}-bcmath"
    "php${version}-curl"
    "php${version}-zip"
    "php${version}-gd"
    "php${version}-intl"
    "php${version}-readline"
    "php${version}-soap"
    "php${version}-opcache"
    "php${version}-sqlite3"
  )

  info "Installing PHP ${version} packages"
  apt_install php-fpm php-cli php-common
  apt_install "${packages[@]}"

  for extension in redis imagick; do
    if apt-cache show "php${version}-${extension}" >/dev/null 2>&1; then
      apt_install "php${version}-${extension}"
    else
      apt_install "php-${extension}"
    fi
  done
}

install_optional_php84() {
  if [[ "$INSTALL_PHP84" != true ]]; then
    return
  fi

  info "Checking PHP 8.4 availability from configured apt repositories"
  apt-get update
  if apt-cache show php8.4-fpm >/dev/null 2>&1; then
    install_php_packages "8.4"
    configure_php "8.4"
    systemctl enable --now php8.4-fpm
    success "PHP 8.4 installed"
  else
    warn "PHP 8.4 is not available from the configured apt repositories. Skipping PHP 8.4."
  fi
}

configure_php() {
  local version="$1"
  local php_dir="/etc/php/${version}"

  if [[ ! -d "$php_dir" ]]; then
    warn "$php_dir not found; skipping PHP ${version} configuration"
    return
  fi

  for sapi in fpm cli; do
    [[ -d "${php_dir}/${sapi}/conf.d" ]] || continue
    write_file_if_changed "${php_dir}/${sapi}/conf.d/99-laravel-production.ini" 0644 <<'PHPINI'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 120
max_input_time = 120
expose_php = Off
realpath_cache_size = 4096K
realpath_cache_ttl = 600
PHPINI
  done

  if [[ -d "${php_dir}/fpm/conf.d" ]]; then
    write_file_if_changed "${php_dir}/fpm/conf.d/98-laravel-opcache.ini" 0644 <<'OPCACHE'
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=0
opcache.revalidate_freq=0
opcache.save_comments=1
opcache.jit=0
OPCACHE
  fi
}

check_laravel_extensions() {
  local version="$1"
  local php_bin="php${version}"
  local missing=()
  local required_extensions=(
    ctype curl dom fileinfo filter hash mbstring openssl pcre pdo session tokenizer xml
  )

  if ! command -v "$php_bin" >/dev/null 2>&1; then
    php_bin="php"
  fi

  local loaded_extensions
  loaded_extensions="$("$php_bin" -m | tr '[:upper:]' '[:lower:]')"

  for extension in "${required_extensions[@]}"; do
    if ! grep -qx "$extension" <<<"$loaded_extensions"; then
      missing+=("$extension")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    error "Missing required PHP extensions for Laravel: ${missing[*]}"
  fi

  success "Required Laravel PHP extensions are active for PHP ${version}"
}

install_mariadb_redis_supervisor() {
  info "Installing MariaDB, Redis, and Supervisor"
  apt_install mariadb-server mariadb-client redis-server supervisor
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    success "Composer already installed: $(composer -V)"
    return
  fi

  info "Installing Composer with installer checksum verification"
  local tmp_dir expected_checksum actual_checksum installer
  tmp_dir="$(mktemp -d)"
  installer="${tmp_dir}/composer-setup.php"

  expected_checksum="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o "$installer"
  actual_checksum="$(php -r "echo hash_file('sha384', '${installer}');")"

  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    rm -rf "$tmp_dir"
    error "Composer installer checksum mismatch"
  fi

  php "$installer" --install-dir=/usr/local/bin --filename=composer
  rm -rf "$tmp_dir"
  success "Composer installed: $(composer -V)"
}

install_nodejs_24() {
  local current_major=""

  if command -v node >/dev/null 2>&1; then
    current_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || true)"
  fi

  if [[ "$current_major" == "24" ]]; then
    success "Node.js 24 already installed: $(node -v)"
    return
  fi

  info "Installing Node.js 24 from NodeSource apt repository"
  install -d -m 0755 /etc/apt/keyrings

  local key_tmp keyring_tmp
  key_tmp="$(mktemp)"
  keyring_tmp="$(mktemp)"
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$key_tmp"
  gpg --dearmor < "$key_tmp" > "$keyring_tmp"
  install -m 0644 "$keyring_tmp" /etc/apt/keyrings/nodesource.gpg
  rm -f "$key_tmp" "$keyring_tmp"

  write_file_if_changed /etc/apt/sources.list.d/nodesource.list 0644 <<'NODESOURCE'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
NODESOURCE

  apt-get update
  apt_install nodejs

  current_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || true)"
  [[ "$current_major" == "24" ]] || error "Expected Node.js 24, got $(node -v 2>/dev/null || echo unknown)"
  success "Node.js installed: $(node -v)"
}

install_certbot() {
  info "Installing Certbot and Nginx plugin"
  apt_install certbot python3-certbot-nginx
}

create_directories() {
  info "Creating server directory structure"
  install -d -m 0755 /var/www
  install -d -m 0755 /etc/nginx/snippets/laravel
  install -d -m 0750 "$LOG_DIR"

  write_file_if_changed /etc/nginx/snippets/laravel/security.conf 0644 <<'NGINX'
location ~ /\.(?!well-known).* {
    deny all;
}

location ~* /(bootstrap/cache|storage|vendor|node_modules)/.*\.php$ {
    deny all;
}
NGINX
}

configure_ufw() {
  info "Configuring UFW firewall"
  ufw allow OpenSSH

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local ssh_port
    ssh_port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    if [[ "$ssh_port" =~ ^[0-9]+$ ]]; then
      ufw allow "${ssh_port}/tcp" comment "current SSH session"
    fi
  fi

  ufw allow "Nginx Full"
  ufw --force enable
  success "UFW enabled"
}

enable_services() {
  local php_service="php${PHP_DEFAULT_VERSION}-fpm"

  info "Enabling services"
  systemctl enable --now nginx
  systemctl enable --now "$php_service"
  systemctl enable --now mariadb
  systemctl enable --now redis-server
  systemctl enable --now supervisor

  systemctl restart "$php_service"
  systemctl reload nginx

  if [[ "$INSTALL_FAIL2BAN" == true ]]; then
    apt_install fail2ban
    systemctl enable --now fail2ban
  fi
}

print_versions() {
  cat <<'HEADER'

Installed versions:
HEADER
  nginx -v 2>&1 || true
  php -v | head -n 1 || true
  composer -V || true
  node -v || true
  npm -v || true
  mysql --version || true
  redis-server --version || true
}

main() {
  info "Laravel production server installation started"
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  check_os
  set_timezone
  install_base_packages
  install_nginx
  install_php_packages "$PHP_DEFAULT_VERSION"
  configure_php "$PHP_DEFAULT_VERSION"
  check_laravel_extensions "$PHP_DEFAULT_VERSION"
  install_optional_php84
  install_mariadb_redis_supervisor
  install_composer
  install_nodejs_24
  install_certbot
  create_directories
  configure_ufw
  enable_services
  print_versions
  success "Installation complete. Log saved to $LOG_FILE"
}

main "$@"
