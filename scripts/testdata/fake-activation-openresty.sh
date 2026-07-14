#!/bin/sh
set -eu

prefix=""
signal=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p)
      prefix="$2"
      shift 2
      ;;
    -s)
      signal="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prefix="${prefix%/}"
if [ "$signal" = "reload" ]; then
  prefix="${LITEWAF_CURRENT_LINK:?current link is required}"
  if [ -f "$prefix/fail-reload" ]; then
    echo "simulated reload failure" >&2
    exit 1
  fi
  if [ -n "${FAKE_RELOAD_LOG:-}" ]; then
    basename "$(readlink "$prefix")" >> "$FAKE_RELOAD_LOG"
  fi
  echo "simulated reload success"
  exit 0
fi

if [ -f "$prefix/slow-validation" ]; then
  sleep 2
fi
if [ -f "$prefix/fail-validation" ]; then
  echo "simulated nginx validation failure" >&2
  exit 1
fi
echo "simulated nginx validation success"
