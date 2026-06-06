#!/bin/sh
set -eu

watch_path="${LITEWAF_RELOAD_WATCH_PATH:-/etc/litewaf}"
interval="${LITEWAF_RELOAD_WATCH_INTERVAL:-2}"
debounce="${LITEWAF_RELOAD_WATCH_DEBOUNCE:-1}"
reload_script="${LITEWAF_RELOAD_SCRIPT:-/usr/local/bin/litewaf-reload.sh}"

case "$interval" in
  ''|*[!0-9]*)
    echo "invalid LITEWAF_RELOAD_WATCH_INTERVAL: $interval" >&2
    exit 1
    ;;
esac

case "$debounce" in
  ''|*[!0-9]*)
    echo "invalid LITEWAF_RELOAD_WATCH_DEBOUNCE: $debounce" >&2
    exit 1
    ;;
esac

checksum() {
  if [ ! -d "$watch_path" ]; then
    printf 'missing:%s\n' "$watch_path"
    return
  fi

  find "$watch_path" -type f -print 2>/dev/null |
    sort |
    while IFS= read -r file; do
      cksum "$file" 2>/dev/null || true
    done |
    cksum |
    awk '{print $1 ":" $2}'
}

last="$(checksum)"

while :; do
  sleep "$interval"
  current="$(checksum)"
  if [ "$current" = "$last" ]; then
    continue
  fi

  sleep "$debounce"
  stable="$(checksum)"
  if [ "$stable" != "$current" ]; then
    last="$stable"
    continue
  fi

  if [ -x "$reload_script" ]; then
    "$reload_script" || true
  else
    echo "reload script not executable: $reload_script" >&2
  fi
  last="$stable"
done
