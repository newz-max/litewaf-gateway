#!/bin/sh
set -eu

repo="${LITEWAF_TEST_REPO:-/workspace}"
agent="$repo/litewaf-activation-agent.sh"
contract_cli="$repo/scripts/activation-contract-cli.lua"
fake_openresty="$repo/scripts/testdata/fake-activation-openresty.sh"
fake_curl="$repo/scripts/testdata/fake-activation-curl.sh"

fail() {
  echo "activation-agent-test failed: $1" >&2
  exit 1
}

sha() {
  printf 'sha256:%s' "$(sha256sum "$1" | awk '{print $1}')"
}

create_candidate() {
  root="$1"
  version="$2"
  marker="${3:-}"
  candidate="$root/releases/$version"
  mkdir -p "$candidate/listeners"
  printf '{"version":"%s","applications":[]}\n' "$version" > "$candidate/active.json"
  printf 'pid /var/run/litewaf-nginx.pid; events {} http {}\n' > "$candidate/nginx.conf"
  printf '# applications\n' > "$candidate/listeners/applications.conf"
  printf 'client_max_body_size 50m;\n' > "$candidate/listeners/body-size.conf"
  if [ "$marker" != "" ]; then
    : > "$candidate/$marker"
  fi
  cat > "$candidate/manifest.json" <<EOF
{"schema_version":1,"version":"$version","generated_at":"2026-07-14T10:00:00Z","artifacts":[{"path":"active.json","sha256":"$(sha "$candidate/active.json")","size":$(stat -c %s "$candidate/active.json")},{"path":"nginx.conf","sha256":"$(sha "$candidate/nginx.conf")","size":$(stat -c %s "$candidate/nginx.conf")},{"path":"listeners/applications.conf","sha256":"$(sha "$candidate/listeners/applications.conf")","size":$(stat -c %s "$candidate/listeners/applications.conf")},{"path":"listeners/body-size.conf","sha256":"$(sha "$candidate/listeners/body-size.conf")","size":$(stat -c %s "$candidate/listeners/body-size.conf")}],"listeners":[{"port":18080,"protocol":"http","host":"app.example.test"}]}
EOF
}

write_request() {
  root="$1"
  version="$2"
  previous="$3"
  checksum="${4:-$(sha "$root/releases/$version/manifest.json")}"
  mkdir -p "$root/control"
  tmp="$root/control/activate.json.tmp"
  printf '{"schema_version":1,"version":"%s","checksum":"%s","requested_at":"2026-07-14T10:00:01Z","previous_version":"%s"}\n' "$version" "$checksum" "$previous" > "$tmp"
  mv "$tmp" "$root/control/activate.json"
}

setup_root() {
  root="$(mktemp -d)"
  mkdir -p "$root/releases" "$root/control"
  create_candidate "$root" "ruleset-0001"
  ln -s "releases/ruleset-0001" "$root/current"
  printf '%s\n' "$root"
}

run_agent() {
  root="$1"
  env \
    LITEWAF_ROOT="$root" \
    LITEWAF_CURRENT_LINK="$root/current" \
    LITEWAF_ACTIVATION_CONTRACT_CLI="$contract_cli" \
    LITEWAF_ACTIVATION_REQUIRE_MASTER=false \
    LITEWAF_ACTIVATION_ONCE=true \
    LITEWAF_ACTIVATION_PROBE_TIMEOUT=1 \
    LITEWAF_RELEASE_RETENTION_COUNT=10 \
    LITEWAF_RELEASE_RETENTION_MAX_BYTES=1048576 \
    OPENRESTY_BIN="$fake_openresty" \
    CURL_BIN="$fake_curl" \
    FAKE_RELOAD_LOG="$root/reload.log" \
    /bin/sh "$agent"
}

assert_status() {
  root="$1"
  expected="$2"
  expected_version="$3"
  if ! grep -Fq "\"status\":\"$expected\"" "$root/control/activation-status.json"; then
    fail "expected status $expected, got $(cat "$root/control/activation-status.json" 2>/dev/null || true)"
  fi
  if ! grep -Fq "\"version\":\"$expected_version\"" "$root/control/activation-status.json"; then
    fail "expected status version $expected_version, got $(cat "$root/control/activation-status.json" 2>/dev/null || true)"
  fi
}

assert_current() {
  root="$1"
  expected="$2"
  actual="$(basename "$(readlink "$root/current")")"
  if [ "$actual" != "$expected" ]; then
    fail "expected current $expected, got $actual"
  fi
}

run_case() {
  name="$1"
  marker="$2"
  expected_status="$3"
  expected_current="$4"
  root="$(setup_root)"
  create_candidate "$root" "ruleset-0002" "$marker"
  write_request "$root" "ruleset-0002" "ruleset-0001"
  run_agent "$root"
  assert_status "$root" "$expected_status" "ruleset-0002"
  assert_current "$root" "$expected_current"
  rm -rf "$root"
  echo "$name passed"
}

run_case "success" "" "activated" "ruleset-0002"

root="$(setup_root)"
create_candidate "$root" "ruleset-0002"
write_request "$root" "ruleset-0002" "ruleset-0001" "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_agent "$root"
assert_status "$root" "validation_failed" "ruleset-0002"
assert_current "$root" "ruleset-0001"
rm -rf "$root"
echo "manifest checksum passed"

root="$(setup_root)"
create_candidate "$root" "ruleset-0002"
printf 'corrupt\n' >> "$root/releases/ruleset-0002/active.json"
write_request "$root" "ruleset-0002" "ruleset-0001"
run_agent "$root"
assert_status "$root" "validation_failed" "ruleset-0002"
assert_current "$root" "ruleset-0001"
rm -rf "$root"
echo "artifact checksum passed"

run_case "nginx validation" "fail-validation" "validation_failed" "ruleset-0001"
run_case "reload recovery" "fail-reload" "reload_failed" "ruleset-0001"
run_case "old version probe recovery" "old-probe" "probe_failed" "ruleset-0001"
run_case "probe timeout recovery" "fail-probe" "probe_failed" "ruleset-0001"
run_case "occupied port recovery" "occupied-port" "probe_failed" "ruleset-0001"

root="$(setup_root)"
: > "$root/releases/ruleset-0001/fail-reload"
create_candidate "$root" "ruleset-0002" "fail-probe"
write_request "$root" "ruleset-0002" "ruleset-0001"
run_agent "$root"
assert_status "$root" "rollback_failed" "ruleset-0002"
assert_current "$root" "ruleset-0001"
rm -rf "$root"
echo "rollback failure passed"

root="$(setup_root)"
create_candidate "$root" "ruleset-0002" "slow-validation"
create_candidate "$root" "ruleset-0003"
write_request "$root" "ruleset-0002" "ruleset-0001"
env \
  LITEWAF_ROOT="$root" \
  LITEWAF_CURRENT_LINK="$root/current" \
  LITEWAF_ACTIVATION_CONTRACT_CLI="$contract_cli" \
  LITEWAF_ACTIVATION_REQUIRE_MASTER=false \
  LITEWAF_ACTIVATION_ONCE=true \
  LITEWAF_ACTIVATION_PROBE_TIMEOUT=1 \
  LITEWAF_RELEASE_RETENTION_COUNT=10 \
  OPENRESTY_BIN="$fake_openresty" \
  CURL_BIN="$fake_curl" \
  /bin/sh "$agent" &
agent_pid=$!
sleep 1
write_request "$root" "ruleset-0003" "ruleset-0001"
wait "$agent_pid"
assert_status "$root" "superseded" "ruleset-0002"
assert_current "$root" "ruleset-0001"
rm -rf "$root"
echo "superseded request passed"

root="$(setup_root)"
create_candidate "$root" "ruleset-0002"
index=1
while [ "$index" -le 12 ]; do
  mkdir -p "$root/releases/old-$index"
  index=$((index + 1))
done
write_request "$root" "ruleset-0002" "ruleset-0001"
run_agent "$root"
count="$(find "$root/releases" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [ "$count" -gt 10 ] || [ ! -d "$root/releases/ruleset-0001" ] || [ ! -d "$root/releases/ruleset-0002" ]; then
  fail "retention safety failed with count=$count"
fi
rm -rf "$root"
echo "retention safety passed"

echo "activation-agent-test passed"
