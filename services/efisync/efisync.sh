#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: must be run as root." >&2
  exit 1
fi

REQUIRED=(rsync inotifywait flock)
for bin in "${REQUIRED[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Error: missing '$bin'." >&2
    exit 1
  }
done

: "${SRC:=/boot/efi}"
: "${DST:=/boot/efi2}"
: "${LOCK:=/run/efisync.lock}"

do_sync() {
  printf "[%(%F %T)T] syncing...\n" -1
  flock "$LOCK" rsync -a --delete -- "$SRC"/ "$DST"/
  printf "[%(%F %T)T] sync done.\n" -1
}

do_sync

while inotifywait -qq -r -e close_write,create,delete,move,attrib -- "$SRC"; do
  while inotifywait -qq -r -t 1 -e close_write,create,delete,move,attrib -- "$SRC"; do :; done
  do_sync
done
