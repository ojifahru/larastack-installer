#!/usr/bin/env bash
set -euo pipefail

PREFIX="/usr/local/bin"

usage() {
  cat <<'USAGE'
Usage:
  sudo bash install-larastack-command.sh [options]

Options:
  --prefix=/usr/local/bin   Install command symlinks here
  -h, --help                Show this help
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#*=}" ;;
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

resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir

  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" == /* ]] || source="${dir}/${source}"
  done

  cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
LAUNCHER="${SCRIPT_DIR}/larastack"

[[ -f "$LAUNCHER" ]] || {
  echo "[ERROR] Launcher not found: $LAUNCHER" >&2
  exit 1
}

install -d -m 0755 "$PREFIX"
chmod +x "$LAUNCHER"
ln -sfn "$LAUNCHER" "${PREFIX}/larastack"
ln -sfn "$LAUNCHER" "${PREFIX}/larastack-installer"

cat <<EOF
[OK] Installed global commands:
  ${PREFIX}/larastack
  ${PREFIX}/larastack-installer

Try:
  larastack
  larastack-installer
EOF
