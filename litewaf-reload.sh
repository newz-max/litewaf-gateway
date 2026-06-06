#!/bin/sh
set -eu

openresty_bin="${OPENRESTY_BIN:-/usr/local/openresty/bin/openresty}"
state_file="${LITEWAF_RELOAD_STATE_FILE:-/var/lib/litewaf/runtime/reload-status.json}"
max_message_len="${LITEWAF_RELOAD_MESSAGE_MAX_LEN:-480}"

mkdir -p "$(dirname "$state_file")"

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

bounded() {
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c "1-$max_message_len"
}

write_state() {
  status="$1"
  message="$2"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${state_file}.tmp"
  {
    printf '{'
    printf '"status":"%s",' "$(json_escape "$status")"
    printf '"message":"%s",' "$(json_escape "$(bounded "$message")")"
    printf '"updated_at":"%s"' "$timestamp"
    printf '}\n'
  } > "$tmp"
  mv "$tmp" "$state_file"
}

validation_output="$("$openresty_bin" -t 2>&1)" || {
  write_state "validation_failed" "$validation_output"
  printf '%s\n' "$validation_output" >&2
  exit 1
}

reload_output="$("$openresty_bin" -s reload 2>&1)" || {
  write_state "reload_failed" "$reload_output"
  printf '%s\n' "$reload_output" >&2
  exit 1
}

write_state "reloaded" "${reload_output:-reload completed}"
printf '%s\n' "${reload_output:-reload completed}"
