#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-Asia/Jakarta}"
PHP_DEFAULT_VERSION="${PHP_DEFAULT_VERSION:-8.3}"
INSTALL_PHP84=false
INSTALL_PHP84_PPA=false
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
  --php=8.3                Set default PHP-FPM version: 8.3 or 8.4. Default: 8.3
  --with-php84             Install PHP 8.4 if it is available from configured apt repositories
  --with-php84-ppa         Add ppa:ondrej/php if PHP 8.4 is not available
  --with-fail2ban          Install and enable Fail2ban
  -h, --help               Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --timezone=*) DEFAULT_TIMEZONE="${arg#*=}" ;;
    --php=*) PHP_DEFAULT_VERSION="${arg#*=}" ;;
    --with-php84) INSTALL_PHP84=true ;;
    --with-php84-ppa) INSTALL_PHP84=true; INSTALL_PHP84_PPA=true ;;
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

run_interactive_wizard() {
  is_tty || error "Interactive mode needs a terminal. Use --yes and options for non-interactive use."

  cat > /dev/tty <<'INTRO'
Laravel server install wizard
Press Enter to accept the value in brackets.

INTRO

  DEFAULT_TIMEZONE="$(prompt_text "Timezone server" "$DEFAULT_TIMEZONE")"
  PHP_DEFAULT_VERSION="$(prompt_text "Versi PHP default untuk website baru, pilih 8.3 atau 8.4" "$PHP_DEFAULT_VERSION")"

  if [[ "$PHP_DEFAULT_VERSION" == "8.4" ]]; then
    INSTALL_PHP84=true
  fi

  if [[ "$INSTALL_PHP84" != true ]] && prompt_yes_no "Install PHP 8.4 juga jika tersedia dari apt repository?" "n"; then
    INSTALL_PHP84=true
  fi

  if [[ "$INSTALL_PHP84" == true && "$INSTALL_PHP84_PPA" != true ]] \
    && prompt_yes_no "Jika PHP 8.4 tidak ada di repo Ubuntu, tambah PPA ppa:ondrej/php?" "n"; then
    INSTALL_PHP84_PPA=true
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
  PHP 8.4 PPA:   ${INSTALL_PHP84_PPA}
  Fail2ban:      ${INSTALL_FAIL2BAN}
  log:           ${LOG_FILE}

EOF

  if ! prompt_yes_no "Lanjut install stack production Laravel sekarang?" "y"; then
    error "Installation cancelled"
  fi
}

validate_options() {
  [[ "$PHP_DEFAULT_VERSION" =~ ^8\.[34]$ ]] || error "--php must be 8.3 or 8.4"

  if [[ "$PHP_DEFAULT_VERSION" == "8.4" ]]; then
    INSTALL_PHP84=true
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
  if [[ "$version" == "$PHP_DEFAULT_VERSION" ]]; then
    apt_install php-fpm php-cli php-common
  fi
  apt_install "${packages[@]}"

  for extension in redis imagick; do
    if apt-cache show "php${version}-${extension}" >/dev/null 2>&1; then
      apt_install "php${version}-${extension}"
    else
      apt_install "php-${extension}"
    fi
  done
}

add_ondrej_php_ppa() {
  if grep -Rqs "ppa.launchpadcontent.net/ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    success "ppa:ondrej/php is already configured"
    return
  fi

  warn "Adding third-party PHP repository: ppa:ondrej/php"
  add-apt-repository -y ppa:ondrej/php
  apt-get update
}

ensure_default_php_available() {
  local package="php${PHP_DEFAULT_VERSION}-fpm"

  info "Checking default PHP package availability: ${package}"
  if apt-cache show "$package" >/dev/null 2>&1; then
    return
  fi

  if [[ "$PHP_DEFAULT_VERSION" == "8.4" && "$INSTALL_PHP84_PPA" == true ]]; then
    add_ondrej_php_ppa
  fi

  if ! apt-cache show "$package" >/dev/null 2>&1; then
    if [[ "$PHP_DEFAULT_VERSION" == "8.4" ]]; then
      error "PHP 8.4 is not available. Re-run with --php=8.4 --with-php84-ppa to allow ppa:ondrej/php."
    fi
    error "Default PHP package is not available: ${package}"
  fi
}

install_optional_php84() {
  if [[ "$INSTALL_PHP84" != true ]]; then
    return
  fi

  if [[ "$PHP_DEFAULT_VERSION" == "8.4" ]]; then
    success "PHP 8.4 is already installed as the default PHP version"
    return
  fi

  info "Checking PHP 8.4 availability from configured apt repositories"
  apt-get update
  if ! apt-cache show php8.4-fpm >/dev/null 2>&1; then
    if [[ "$INSTALL_PHP84_PPA" == true ]]; then
      add_ondrej_php_ppa
    else
      warn "PHP 8.4 is not available from configured apt repositories. Re-run with --with-php84-ppa to add ppa:ondrej/php."
      return
    fi
  fi

  if ! apt-cache show php8.4-fpm >/dev/null 2>&1; then
    error "PHP 8.4 is still not available after apt repository update"
  fi

  install_php_packages "8.4"
  configure_php "8.4"
  check_laravel_extensions "8.4"
  systemctl enable --now php8.4-fpm
  success "PHP 8.4 installed"
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
  local tmp_dir expected_checksum actual_checksum installer php_bin
  tmp_dir="$(mktemp -d)"
  installer="${tmp_dir}/composer-setup.php"
  php_bin="$(command -v "php${PHP_DEFAULT_VERSION}" || command -v php)"

  expected_checksum="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL https://getcomposer.org/installer -o "$installer"
  actual_checksum="$("$php_bin" -r "echo hash_file('sha384', '${installer}');")"

  if [[ "$actual_checksum" != "$expected_checksum" ]]; then
    rm -rf "$tmp_dir"
    error "Composer installer checksum mismatch"
  fi

  "$php_bin" "$installer" --install-dir=/usr/local/bin --filename=composer
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

validate_nodejs_24() {
  local current_major npm_version

  command -v node >/dev/null 2>&1 || error "Node.js binary not found after install"
  command -v npm >/dev/null 2>&1 || error "npm binary not found after install"

  current_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || true)"
  [[ "$current_major" == "24" ]] || error "Expected active Node.js 24, got $(node -v 2>/dev/null || echo unknown)"

  npm_version="$(npm -v 2>/dev/null || true)"
  success "Node.js 24 active: node $(node -v), npm ${npm_version}"
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

service_health_line() {
  local service="$1"
  local status

  status="$(systemctl is-active "$service" 2>/dev/null || true)"
  if [[ "$status" == "active" ]]; then
    printf '  %-24s active\n' "$service"
  else
    printf '  %-24s %s\n' "$service" "${status:-unknown}"
  fi
}

print_health_summary() {
  cat <<'HEADER'

Service health:
HEADER
  service_health_line nginx
  service_health_line "php${PHP_DEFAULT_VERSION}-fpm"
  if [[ "$PHP_DEFAULT_VERSION" != "8.4" ]] && systemctl list-unit-files php8.4-fpm.service --no-pager --no-legend 2>/dev/null | grep -q '^php8.4-fpm.service'; then
    service_health_line php8.4-fpm
  fi
  service_health_line mariadb
  service_health_line redis-server
  service_health_line supervisor
  if systemctl list-unit-files fail2ban.service --no-pager --no-legend 2>/dev/null | grep -q '^fail2ban.service'; then
    service_health_line fail2ban
  fi

  if nginx -t >/dev/null 2>&1; then
    printf '  %-24s ok\n' "nginx config"
  else
    printf '  %-24s check failed\n' "nginx config"
  fi
}

print_versions() {
  cat <<'HEADER'

Installed versions:
HEADER
  nginx -v 2>&1 || true
  php -v | head -n 1 || true
  if command -v php8.4 >/dev/null 2>&1; then
    php8.4 -v | head -n 1 || true
  fi
  composer -V || true
  node -v || true
  npm -v || true
  mysql --version || true
  redis-server --version || true
}

print_next_steps() {
  cat <<EOF

Next steps:
  1. Open the menu: larastack
  2. Create an empty handoff site: sudo larastack create-site --domain=example.com --site-user=example --handoff
  3. List sites: sudo larastack list-sites --summary
  4. Check health: sudo larastack check-site --all
EOF
}

install_larastack_command() {
  local script_dir installer
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  installer="${script_dir}/install-larastack-command.sh"

  if [[ ! -f "$installer" ]]; then
    warn "Global larastack command installer not found: $installer"
    return
  fi

  info "Installing global larastack commands"
  bash "$installer"
}

main() {
  info "Laravel production server installation started"
  if [[ "$INTERACTIVE" == true ]]; then
    run_interactive_wizard
  fi

  validate_options
  check_os
  set_timezone
  install_base_packages
  install_nginx
  ensure_default_php_available
  install_php_packages "$PHP_DEFAULT_VERSION"
  configure_php "$PHP_DEFAULT_VERSION"
  check_laravel_extensions "$PHP_DEFAULT_VERSION"
  install_optional_php84
  install_mariadb_redis_supervisor
  install_composer
  install_nodejs_24
  validate_nodejs_24
  install_certbot
  create_directories
  configure_ufw
  enable_services
  print_versions
  print_health_summary
  install_larastack_command
  print_next_steps
  success "Installation complete. Log saved to $LOG_FILE"
}

main "$@"
