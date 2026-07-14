#!/bin/sh
set -eu

current="${LITEWAF_CURRENT_LINK:?current link is required}"
version="$(basename "$(readlink "$current")")"
if [ -f "$current/fail-probe" ] || [ -f "$current/occupied-port" ]; then
  exit 7
fi
if [ -f "$current/old-probe" ]; then
  printf '{"status":"ready","version":"old-version"}\n'
  exit 0
fi
printf '{"status":"ready","version":"%s"}\n' "$version"
