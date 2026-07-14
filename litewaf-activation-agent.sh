#!/bin/sh
set -eu

root="${LITEWAF_ROOT:-/etc/litewaf}"
releases_dir="${LITEWAF_RELEASES_DIR:-$root/releases}"
current_link="${LITEWAF_CURRENT_LINK:-$root/current}"
request_file="${LITEWAF_ACTIVATION_REQUEST_FILE:-$root/control/activate.json}"
status_file="${LITEWAF_ACTIVATION_STATUS_FILE:-$root/control/activation-status.json}"
lock_file="${LITEWAF_ACTIVATION_LOCK_FILE:-$root/control/activation.lock}"
contract_cli="${LITEWAF_ACTIVATION_CONTRACT_CLI:-/usr/local/share/litewaf/activation-contract-cli.lua}"
resty_bin="${RESTY_BIN:-/usr/bin/resty}"
openresty_bin="${OPENRESTY_BIN:-/usr/local/openresty/bin/openresty}"
curl_bin="${CURL_BIN:-/usr/bin/curl}"
poll_interval="${LITEWAF_ACTIVATION_POLL_INTERVAL:-1}"
probe_timeout="${LITEWAF_ACTIVATION_PROBE_TIMEOUT:-5}"
message_max_len="${LITEWAF_ACTIVATION_MESSAGE_MAX_LEN:-480}"
retention_count="${LITEWAF_RELEASE_RETENTION_COUNT:-10}"
retention_max_bytes="${LITEWAF_RELEASE_RETENTION_MAX_BYTES:-1073741824}"
require_master="${LITEWAF_ACTIVATION_REQUIRE_MASTER:-true}"
master_pid_file="${LITEWAF_NGINX_PID_FILE:-/var/run/litewaf-nginx.pid}"
run_once="${LITEWAF_ACTIVATION_ONCE:-false}"

case "$root" in
  /*) ;;
  *) echo "LITEWAF_ROOT must be absolute: $root" >&2; exit 1 ;;
esac
case "$releases_dir:$current_link:$request_file:$status_file" in
  "$root"/*:"$root"/*:"$root"/*:"$root"/*) ;;
  *) echo "activation paths must stay below LITEWAF_ROOT" >&2; exit 1 ;;
esac
case "$poll_interval:$probe_timeout:$message_max_len:$retention_count:$retention_max_bytes" in
  *[!0-9:]*|*::*|:*) echo "activation numeric configuration is invalid" >&2; exit 1 ;;
esac
if [ "$retention_count" -lt 10 ]; then
  echo "LITEWAF_RELEASE_RETENTION_COUNT must be at least 10" >&2
  exit 1
fi

mkdir -p "$releases_dir" "$(dirname "$request_file")" "$(dirname "$status_file")" "$(dirname "$lock_file")"
exec 9>"$lock_file"
if ! flock -n 9; then
  echo "another LiteWaf activation agent holds $lock_file" >&2
  exit 1
fi

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

bounded() {
  printf '%s' "$1" | tr '\r\n' '  ' | cut -c "1-$message_max_len"
}

write_status() (
  version="$1"
  checksum="$2"
  state="$3"
  previous="$4"
  stage="$5"
  message="$(bounded "$6")"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="${status_file}.tmp.$$"
  {
    printf '{'
    printf '"schema_version":1,'
    printf '"version":"%s",' "$(json_escape "$version")"
    printf '"checksum":"%s",' "$(json_escape "$checksum")"
    printf '"status":"%s",' "$(json_escape "$state")"
    if [ "$previous" != "" ]; then
      printf '"previous_version":"%s",' "$(json_escape "$previous")"
    fi
    printf '"stage":"%s",' "$(json_escape "$stage")"
    printf '"message":"%s",' "$(json_escape "$message")"
    printf '"updated_at":"%s"' "$timestamp"
    printf '}\n'
  } > "$tmp"
  mv -f "$tmp" "$status_file"
)

request_identity() {
  sha256sum "$request_file" 2>/dev/null | awk '{print $1}'
}

current_version() (
  target="$(readlink "$current_link" 2>/dev/null || true)"
  basename "$target" 2>/dev/null || true
)

manifest_records() (
  manifest="$1"
  version="$2"
  "$resty_bin" -I /usr/local/openresty/nginx/lua "$contract_cli" manifest "$manifest" "$version"
)

verify_candidate() (
  candidate="$1"
  version="$2"
  checksum="$3"
  records_file="$4"
  manifest="$candidate/manifest.json"
  if [ ! -f "$manifest" ]; then
    echo "candidate manifest is missing"
    return 1
  fi
  actual_manifest_checksum="sha256:$(sha256sum "$manifest" | awk '{print $1}')"
  if [ "$actual_manifest_checksum" != "$checksum" ]; then
    echo "manifest checksum mismatch"
    return 1
  fi
  if ! manifest_records "$manifest" "$version" > "$records_file"; then
    echo "manifest contract validation failed"
    return 1
  fi
  artifact_count=0
  while IFS="$(printf '\t')" read -r kind relative expected size; do
    if [ "$kind" != "artifact" ]; then
      continue
    fi
    artifact_count=$((artifact_count + 1))
    artifact="$candidate/$relative"
    case "$artifact" in
      "$candidate"/*) ;;
      *) echo "artifact escapes candidate directory"; return 1 ;;
    esac
    if [ ! -f "$artifact" ]; then
      echo "candidate artifact is missing: $relative"
      return 1
    fi
    actual="sha256:$(sha256sum "$artifact" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
      echo "candidate artifact checksum mismatch: $relative"
      return 1
    fi
    actual_size="$(stat -c %s "$artifact")"
    if [ "$actual_size" != "$size" ]; then
      echo "candidate artifact size mismatch: $relative"
      return 1
    fi
  done < "$records_file"
  if [ "$artifact_count" -lt 4 ]; then
    echo "candidate artifact list is incomplete"
    return 1
  fi
  "$openresty_bin" -e stderr -p "$candidate/" -c nginx.conf -t
)

probe_records() (
  records_file="$1"
  version="$2"
  deadline=$(( $(date +%s) + probe_timeout ))
  while IFS="$(printf '\t')" read -r kind port protocol host; do
    if [ "$kind" != "listener" ]; then
      continue
    fi
    success=false
    while [ "$(date +%s)" -le "$deadline" ]; do
      if [ "$protocol" = "https" ]; then
        response="$($curl_bin -k -sS --connect-timeout 1 --max-time 2 --resolve "$host:$port:127.0.0.1" "https://$host:$port/.litewaf/internal-ready" 2>/dev/null || true)"
      else
        response="$($curl_bin -sS --connect-timeout 1 --max-time 2 --resolve "$host:$port:127.0.0.1" "http://$host:$port/.litewaf/internal-ready" 2>/dev/null || true)"
      fi
      if printf '%s' "$response" | grep -Fq "\"version\":\"$version\""; then
        success=true
        break
      fi
      sleep 1
    done
    if [ "$success" != "true" ]; then
      echo "listener probe failed for $protocol://$host:$port"
      return 1
    fi
  done < "$records_file"
)

switch_current() (
  version="$1"
  tmp="${current_link}.new"
  rm -f "$tmp"
  ln -s "releases/$version" "$tmp"
  mv -Tf "$tmp" "$current_link"
)

reload_current() {
  "$openresty_bin" -e stderr -p "$current_link/" -c nginx.conf -s reload
}

recover_previous() (
  previous="$1"
  if [ "$previous" = "" ] || [ ! -d "$releases_dir/$previous" ]; then
    echo "previous release is unavailable"
    return 1
  fi
  switch_current "$previous"
  if ! reload_current; then
    echo "previous release reload failed"
    return 1
  fi
  previous_records="$(mktemp)"
  if ! manifest_records "$releases_dir/$previous/manifest.json" "$previous" > "$previous_records"; then
    rm -f "$previous_records"
    echo "previous release manifest is invalid"
    return 1
  fi
  if ! probe_records "$previous_records" "$previous"; then
    rm -f "$previous_records"
    echo "previous release probe failed"
    return 1
  fi
  rm -f "$previous_records"
)

cleanup_releases() (
  protected_current="$(current_version)"
  protected_previous="$1"
  total="$(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  candidates="$(mktemp)"
  find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%f\n' | sort -n > "$candidates"
  while IFS="$(printf '\t')" read -r _ name; do
    if [ "$total" -le "$retention_count" ]; then
      break
    fi
    if [ "$name" = "$protected_current" ] || [ "$name" = "$protected_previous" ]; then
      continue
    fi
    case "$name" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    rm -rf "$releases_dir/$name"
    total=$((total - 1))
  done < "$candidates"
  size="$(du -sb "$releases_dir" | awk '{print $1}')"
  if [ "$size" -gt "$retention_max_bytes" ] && [ "$total" -gt "$retention_count" ]; then
    while IFS="$(printf '\t')" read -r _ name; do
      if [ "$size" -le "$retention_max_bytes" ] || [ "$total" -le "$retention_count" ]; then
        break
      fi
      if [ "$name" = "$protected_current" ] || [ "$name" = "$protected_previous" ] || [ ! -d "$releases_dir/$name" ]; then
        continue
      fi
      case "$name" in
        ''|*[!A-Za-z0-9._-]*) continue ;;
      esac
      rm -rf "$releases_dir/$name"
      total=$((total - 1))
      size="$(du -sb "$releases_dir" | awk '{print $1}')"
    done < "$candidates"
  fi
  rm -f "$candidates"
)

process_request() {
  initial_identity="$1"
  request_values="$($resty_bin -I /usr/local/openresty/nginx/lua "$contract_cli" request "$request_file")" || {
    echo "activation request contract validation failed" >&2
    return 1
  }
  IFS="$(printf '\t')" read -r version checksum requested_previous <<EOF
$request_values
EOF
  previous="$requested_previous"
  if [ "$previous" = "" ]; then
    previous="$(current_version)"
  fi
  candidate="$releases_dir/$version"
  records_file="$(mktemp)"
  write_status "$version" "$checksum" "validating" "$previous" "manifest" "validating candidate manifest and OpenResty configuration"
  validation_output="$(verify_candidate "$candidate" "$version" "$checksum" "$records_file" 2>&1)" || {
    rm -f "$records_file"
    write_status "$version" "$checksum" "validation_failed" "$previous" "manifest" "$validation_output"
    return 1
  }
  latest_identity="$(request_identity)"
  if [ "$latest_identity" != "$initial_identity" ]; then
    rm -f "$records_file"
    write_status "$version" "$checksum" "superseded" "$previous" "request" "a newer activation request arrived before commit"
    return 0
  fi
  write_status "$version" "$checksum" "activating" "$previous" "switch" "switching current release"
  if ! switch_current "$version"; then
    rm -f "$records_file"
    write_status "$version" "$checksum" "reload_failed" "$previous" "switch" "failed to atomically switch current release"
    return 1
  fi
  reload_output="$(reload_current 2>&1)" || {
    if recover_previous "$previous"; then
      write_status "$version" "$checksum" "reload_failed" "$previous" "reload" "$reload_output"
    else
      write_status "$version" "$checksum" "rollback_failed" "$previous" "rollback" "candidate reload failed and previous release recovery failed"
    fi
    rm -f "$records_file"
    return 1
  }
  probe_output="$(probe_records "$records_file" "$version" 2>&1)" || {
    if recover_previous "$previous"; then
      write_status "$version" "$checksum" "probe_failed" "$previous" "probe" "$probe_output"
    else
      write_status "$version" "$checksum" "rollback_failed" "$previous" "rollback" "candidate probe failed and previous release recovery failed"
    fi
    rm -f "$records_file"
    return 1
  }
  rm -f "$records_file"
  write_status "$version" "$checksum" "activated" "$previous" "complete" "all listeners activated"
  cleanup_releases "$previous"
}

last_identity=""
while :; do
  if [ "$require_master" = "true" ] && [ ! -s "$master_pid_file" ]; then
    sleep "$poll_interval"
    continue
  fi
  if [ ! -f "$request_file" ]; then
    if [ "$run_once" = "true" ]; then exit 0; fi
    sleep "$poll_interval"
    continue
  fi
  identity="$(request_identity)"
  if [ "$identity" = "$last_identity" ]; then
    if [ "$run_once" = "true" ]; then exit 0; fi
    sleep "$poll_interval"
    continue
  fi
  process_request "$identity" || true
  last_identity="$identity"
  if [ "$run_once" = "true" ]; then
    exit 0
  fi
done
