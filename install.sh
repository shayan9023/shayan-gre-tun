#!/usr/bin/env bash
set -euo pipefail

MANAGER_URL="https://raw.githubusercontent.com/shayan9023/shayan-gre-tun/main/shayan.sh"
DEST="/usr/local/bin/shayan"
COMMAND_LINK="/usr/bin/shayan"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run the installer as root (use sudo -i first).\n' >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || { printf 'curl is required. Install it first.\n' >&2; exit 1; }
install -d -m 0755 /usr/local/bin
TMP="$(mktemp /usr/local/bin/.shayan.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

curl -fsSL --retry 3 --connect-timeout 10 "$MANAGER_URL" -o "$TMP"
[[ -s "$TMP" ]] || { printf 'Downloaded manager is empty. Existing installation was not changed.\n' >&2; exit 1; }
bash -n "$TMP" || { printf 'Downloaded manager has a syntax error. Existing installation was not changed.\n' >&2; exit 1; }
chmod 0755 "$TMP"
mv -f "$TMP" "$DEST"
trap - EXIT

if [[ -L $COMMAND_LINK && $(readlink "$COMMAND_LINK" 2>/dev/null || true) == "$DEST" ]]; then
  :
elif [[ -e $COMMAND_LINK || -L $COMMAND_LINK ]]; then
  printf 'A different command already exists at %s; it was left untouched.\n' "$COMMAND_LINK" >&2
else
  ln -s "$DEST" "$COMMAND_LINK" || printf 'Could not create %s; the manager is still available at %s.\n' \
    "$COMMAND_LINK" "$DEST" >&2
fi

ensure_command_in_path() {
  local resolved directory candidate
  local -a path_dirs=()

  resolved=$(command -v shayan 2>/dev/null || true)
  if [[ $resolved == "$DEST" ]] ||
     [[ -L $resolved && $(readlink "$resolved" 2>/dev/null || true) == "$DEST" ]]; then
    return 0
  fi
  if [[ -n $resolved ]]; then
    printf 'A different shayan command already exists at %s; it was left untouched. Run %s directly or resolve the command-name conflict.\n' \
      "$resolved" "$DEST" >&2
    return 0
  fi

  IFS=: read -r -a path_dirs <<< "${PATH:-}"
  for directory in "${path_dirs[@]}"; do
    [[ $directory == /* && $directory != /usr/local/bin && -d $directory && -w $directory ]] || continue
    candidate="$directory/shayan"
    if [[ -L $candidate && $(readlink "$candidate" 2>/dev/null || true) == "$DEST" ]]; then
      resolved=$(command -v shayan 2>/dev/null || true)
      [[ $resolved == "$candidate" ]] && return 0
      continue
    fi
    [[ ! -e $candidate && ! -L $candidate ]] || continue
    ln -s "$DEST" "$candidate" || continue
    resolved=$(command -v shayan 2>/dev/null || true)
    [[ $resolved == "$candidate" ]] && return 0
  done

  printf 'Manager installed at %s, but no free directory in PATH could expose the shayan command. Add /usr/local/bin to PATH or run %s directly.\n' \
    "$DEST" "$DEST" >&2
}

ensure_command_in_path
exec "$DEST" "$@"
