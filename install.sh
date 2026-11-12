#!/usr/bin/env bash
set -euo pipefail

MANAGER_URL="https://raw.githubusercontent.com/shayan9023/shayan-gre-tun/main/shayan.sh"
DEST="/usr/local/bin/shayan"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run the installer as root (use sudo -i first).\n' >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { printf 'curl is required. Install it first.\n' >&2; exit 1; }
install -d -m 0755 /usr/local/bin
TMP="$(mktemp /usr/local/bin/.shayan.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --retry 3 --connect-timeout 10 "$MANAGER_URL" -o "$TMP"
chmod 0755 "$TMP"
mv -f "$TMP" "$DEST"
trap - EXIT
exec "$DEST" "$@"
