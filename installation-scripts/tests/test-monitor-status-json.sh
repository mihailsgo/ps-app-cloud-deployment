#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for monitor-status.sh --format json, the read-only machine form of
# report mode that the Deployment Wizard's Monitoring page reads:
#
#   - refused (exit 2) together with --alert or --test-webhook, and for any
#     format other than text or json;
#   - exactly one JSON document on stdout and exit 0, with no state directory
#     created and no webhook POST, even with ALERT_WEBHOOK_URL set;
#   - schema 1: services (the wizard left out), certificate, failure counts
#     and samples, disk stores and filesystems, the receive-back buffer and
#     the alerts the thresholds fire, as the text report evaluates them;
#   - every branch is valid JSON: ps-server without a container, host
#     unknown, certificate missing, a named-volume store, the buffer
#     unreadable or not in use;
#   - --format text, and no --format, still print the text report.
#
# Usage:
#   ./installation-scripts/tests/test-monitor-status-json.sh
#
# Hermetic. Works on a throwaway copy of this checkout's tracked files (edits
# included) whose nginx.conf names padsign.example.com, with a 30-day
# self-signed certificate for it. `docker` is a stub for a ps-server + nginx
# stack (compose also lists the wizard, which the report leaves out); `curl`
# is a stub that only records that it ran. The compose model is read from the
# files (PADSIGN_DIGEST_GATE_NO_DOCKER=1), never from a daemon.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency,
# 124 the watchdog (lib/watchdog.sh) stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 openssl git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done

# The caller's environment must not steer the script under test.
unset ALERT_WEBHOOK_URL ALERT_WEBHOOK_FORMAT ALERT_WEBHOOK_AUTH_HEADER \
  ALERT_RESTART_DELTA ALERT_CERT_DAYS ALERT_BUFFER_MAX ALERT_BUFFER_MAX_AGE_HOURS ALERT_FAILURE_MIN \
  COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR
export PADSIGN_DIGEST_GATE_NO_DOCKER=1
# This machine's real disk use must not add a disk_pressure alert.
export ALERT_DISK_PCT=101

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/       | /'; return 0; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}

# ── the throwaway copy ──────────────────────────────────────────────────────
host="padsign.example.com"
repo="${work}/repo"
mkdir -p "$repo"
(cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
  | (cd "$src_root" && xargs -0 cp --parents -t "$repo" 2>/dev/null) || true
if [[ ! -f "${repo}/installation-scripts/monitor-status.sh" || ! -f "${repo}/nginx/nginx.conf" ]]; then
  echo "ERROR: could not copy the checkout" >&2; exit 2
fi
sed -i -E "s/server_name[[:space:]]+[^;]*;/server_name ${host};/" "${repo}/nginx/nginx.conf"
mkdir -p "${repo}/nginx/certs"
# MSYS_NO_PATHCONV: Git Bash would turn -subj /CN=... into a Windows path.
if ! MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=${host}" \
     -keyout "$(native "${work}/cert.key")" -out "$(native "${repo}/nginx/certs/${host}.crt")" >/dev/null 2>&1; then
  echo "ERROR: openssl could not create the test certificate" >&2; exit 2
fi

# ── stubs ───────────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log" CURL_LOG="${work}/curl.log"
: > "$STUB_LOG"

# ps-server (cid1) running, healthy, 3 restarts; nginx (cid2) running,
# unhealthy. STUB_NO_PS_SERVER: ps-server has no container at all.
# STUB_EXEC: ok (default) | none (no filesystem strategy) | fail.
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "${1:-}" == compose ]]; then
  shift
  case "${1:-}" in
    config) [[ " $* " == *" --services "* ]] && printf '%s\n' ps-server nginx wizard ;;
    ps)
      svc="${*: -1}"
      if [[ -z "${STUB_NO_PS_SERVER:-}" && "$svc" == ps-server ]]; then echo cid1; fi
      if [[ " $* " == *" -a "* && "$svc" == nginx ]]; then echo cid2; fi ;;
    logs)
      printf '%s\n' "ps-server  | GET /api/latestUser 200" "ps-server  | Error proxying stamp: boom" ;;
    exec)
      cat >/dev/null
      case "${STUB_EXEC:-ok}" in
        ok)   printf 'roots=/signed-output\ncount=2\noldest_age_hours=5\n' ;;
        none) printf 'roots=\ncount=0\noldest_age_hours=\n' ;;
        fail) exit 1 ;;
      esac ;;
  esac
  exit 0
fi
case "${1:-}" in
  inspect)
    case "${*: -1}" in
      cid1) echo "running healthy 3" ;;
      cid2) echo "running unhealthy 0" ;;
    esac ;;
esac
exit 0
STUB
cat > "${bin}/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
cat >/dev/null
printf '\n200\n'
STUB
chmod +x "${bin}/docker" "${bin}/curl"
export PATH="${bin}:${PATH}"

# The expressions are this suite's own literals below, never script output.
cat > "${work}/q.py" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(json.dumps(eval(sys.argv[2], {"d": d}), sort_keys=True, separators=(",", ":")))
PY
q() {  # <json file> <python expression over d>: its value, as compact sorted JSON
  MSYS_NO_PATHCONV=1 python3 "$(native "${work}/q.py")" "$(native "$1")" "$2" 2>&1 | tr -d '\r'
}
jeq() {  # <case name> <json file> <expression> <expected, compact sorted JSON>
  local got
  got="$(q "$2" "$3")"
  if [[ "$got" == "$4" ]]; then
    ok_case "$1"
  else
    fail_case "$1" "expression: $3"$'\n'"expected:   $4"$'\n'"got:        $got"
  fi
}
valid_json() { python3 -c 'import json,sys; json.load(sys.stdin)' < "$1" >/dev/null 2>&1; }

rc=0
monitor() {  # <stdout file> <stderr file> [args...]: from the copy's root; sets rc
  local o="$1" e="$2"; shift 2
  rc=0
  (cd "$repo" && bash ./installation-scripts/monitor-status.sh "$@" </dev/null >"$o" 2>"$e") || rc=$?
}
o="${work}/out.txt"
e="${work}/err.txt"

echo "== usage =="
bad=""
for args in "--format json --alert" "--format json --test-webhook" "--format yaml" "--format"; do
  # shellcheck disable=SC2086 # word splitting intended
  monitor "$o" "$e" $args
  if [[ "$rc" != 2 ]] || ! grep -q '^ERROR:' "$e"; then
    bad+="${args}: rc=${rc}, stderr: $(cat "$e")"$'\n'
  fi
done
if [[ -z "$bad" ]]; then
  ok_case "--format json with --alert / --test-webhook, --format yaml, --format without a value: ERROR on stderr, exit 2"
else
  fail_case "usage errors" "$bad"
fi

echo ""
echo "== --format json: read-only, one document =="
j="${work}/main.json"
ALERT_WEBHOOK_URL=https://hooks.example.com/x monitor "$j" "$e" --format json
check "exit 0 (rc=${rc})" test "$rc" = 0
if valid_json "$j"; then
  ok_case "stdout is exactly one JSON document"
else
  fail_case "stdout is not one JSON document" "$(head -c 2000 "$j")"$'\n'"stderr: $(cat "$e")"
fi
check "ALERT_WEBHOOK_URL set: curl never ran (nothing posted)" test ! -e "$CURL_LOG"
check "no state directory created (.monitor-state/)" test ! -e "${repo}/.monitor-state"

jeq "top-level keys" "$j" 'sorted(d)' '["alerts","buffer","certificate","disk","failures","generated","host","schema","services","thresholds"]'
jeq "schema == 1" "$j" 'd["schema"]' '1'
jeq "host from nginx.conf" "$j" 'd["host"]' "\"${host}\""
jeq "generated is an RFC 3339 UTC timestamp" "$j" \
  'bool(__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["generated"]))' 'true'
jeq "thresholds: the defaults (ALERT_DISK_PCT=101 set by this suite)" "$j" 'd["thresholds"]' \
  '{"bufferMax":100,"bufferMaxAgeHours":72,"certDays":14,"diskPct":101,"failureMin":1,"restartDelta":2}'
jeq "services: ps-server and nginx, the wizard left out" "$j" '[s["service"] for s in d["services"]]' '["ps-server","nginx"]'
jeq "services: nginx health unhealthy" "$j" '[s["health"] for s in d["services"] if s["service"] == "nginx"]' '["unhealthy"]'
jeq "services: ps-server running, healthy, 3 restarts" "$j" '[s for s in d["services"] if s["service"] == "ps-server"]' \
  '[{"health":"healthy","restarts":3,"service":"ps-server","state":"running"}]'

jeq "certificate: found, path under nginx/certs/, notAfter a string" "$j" \
  '[d["certificate"]["found"], d["certificate"]["host"], d["certificate"]["path"].endswith("/nginx/certs/'"${host}"'.crt"), isinstance(d["certificate"]["notAfter"], str)]' \
  "[true,\"${host}\",true,true]"
jeq "certificate: daysLeft 28-30 for a 30-day certificate" "$j" '28 <= d["certificate"]["daysLeft"] <= 30' 'true'
jeq "certificate: no certificate_risk alert at ALERT_CERT_DAYS=14" "$j" '[a for a in d["alerts"] if a["key"] == "certificate_risk"]' '[]'

jeq "alerts include service_unhealthy and stamping_failure" "$j" \
  '[k in [a["key"] for a in d["alerts"]] for k in ("service_unhealthy", "stamping_failure")]' '[true,true]'
jeq "stamping_failure alert: one sample, the 'boom' line" "$j" \
  '[len(a["samples"]) == 1 and "boom" in a["samples"][0] for a in d["alerts"] if a["key"] == "stamping_failure"]' '[true]'
jeq "alerts: key, message, samples" "$j" 'sorted(set(k for a in d["alerts"] for k in a))' '["key","message","samples"]'
jeq "failures: window and the five categories" "$j" '[d["failures"]["window"], [c["key"] for c in d["failures"]["counts"]]]' \
  '["in the last 500 log lines",["archive_failure","stamping_failure","routing_webhook_permanent_failure","routing_failure","circuit_open"]]'
jeq "failures: stamping_failure count 1, labelled" "$j" '[c for c in d["failures"]["counts"] if c["key"] == "stamping_failure"]' \
  '[{"count":1,"key":"stamping_failure","label":"stamping failures"}]'
jeq "buffer: ok, 2 entries, oldest 5 h" "$j" 'd["buffer"]' '{"count":2,"error":null,"oldestAgeHours":5,"state":"ok"}'
jeq "no repeated_restarts alert (report mode has no baseline)" "$j" '[a for a in d["alerts"] if a["key"] == "repeated_restarts"]' '[]'
jeq "disk stores: signed-output and docs, in the checkout, not volumes" "$j" \
  '[[s["name"], s["inTree"], s["volume"], s["path"].endswith("/" + s["name"]), isinstance(s["exists"], bool)] for s in d["disk"]["stores"]]' \
  '[["signed-output",true,false,true,true],["docs",true,false,true,true]]'
jeq "disk filesystems: mount, path, usedPct (integer or null)" "$j" \
  'isinstance(d["disk"]["filesystems"], list) and all(sorted(f) == ["mount", "path", "usedPct"] and (f["usedPct"] is None or isinstance(f["usedPct"], int)) for f in d["disk"]["filesystems"])' 'true'

j60="${work}/cert60.json"
ALERT_CERT_DAYS=60 monitor "$j60" "$e" --format json
jeq "ALERT_CERT_DAYS=60: one certificate_risk alert, thresholds.certDays 60" "$j60" \
  '[len([a for a in d["alerts"] if a["key"] == "certificate_risk"]), d["thresholds"]["certDays"]]' '[1,60]'

echo ""
echo "== --format json: the other branches =="
jd="${work}/down.json"
STUB_NO_PS_SERVER=1 monitor "$jd" "$e" --format json
if [[ "$rc" == 0 ]] && valid_json "$jd"; then
  ok_case "ps-server without a container: exit 0, valid JSON"
else
  fail_case "ps-server without a container (rc=${rc})" "$(head -c 2000 "$jd")"$'\n'"stderr: $(cat "$e")"
fi
jeq "... ps-server state missing, health and restarts null" "$jd" '[s for s in d["services"] if s["service"] == "ps-server"]' \
  '[{"health":null,"restarts":null,"service":"ps-server","state":"missing"}]'
jeq "... failures null, buffer not-running, a service_down alert" "$jd" \
  '[d["failures"], d["buffer"], "service_down" in [a["key"] for a in d["alerts"]]]' \
  '[null,{"count":null,"error":null,"oldestAgeHours":null,"state":"not-running"},true]'

vol="${work}/vol"
mkdir -p "$vol"
cat > "${vol}/docker-compose.yml" <<'EOF'
services:
  ps-server:
    image: busybox:1.36
    volumes:
      - signed_output_data:/signed-output
  dmss-archive-services-fallback:
    image: busybox:1.36
    volumes:
      - ./docs:/docs
volumes:
  signed_output_data:
EOF
jv="${work}/vol.json"
STUB_EXEC=fail monitor "$jv" "$e" --format json --compose-dir "$vol"
if [[ "$rc" == 0 ]] && valid_json "$jv"; then
  ok_case "no nginx.conf, a named volume, the buffer unreadable: exit 0, valid JSON"
else
  fail_case "host unknown / named volume / buffer error (rc=${rc})" "$(head -c 2000 "$jv")"$'\n'"stderr: $(cat "$e")"
fi
jeq "... host null, certificate null" "$jv" '[d["host"], d["certificate"]]' '[null,null]'
jeq "... signed-output a named volume: path, exists and size null" "$jv" 'd["disk"]["stores"][0]' \
  '{"exists":null,"inTree":false,"name":"signed-output","path":null,"size":null,"volume":true}'
jeq "... docs does not exist: exists false, size null" "$jv" \
  '[d["disk"]["stores"][1][k] for k in ("name", "exists", "size", "volume")] + [d["disk"]["stores"][1]["path"].endswith("/docs")]' \
  '["docs",false,null,false,true]'
jeq "... buffer error with the reason" "$jv" 'd["buffer"]' \
  '{"count":null,"error":"docker compose exec into ps-server failed","oldestAgeHours":null,"state":"error"}'

jm="${work}/missing-cert.json"
STUB_EXEC=none monitor "$jm" "$e" --format json --host other.example.com
if [[ "$rc" == 0 ]] && valid_json "$jm"; then
  ok_case "--host without a certificate, no filesystem strategy: exit 0, valid JSON"
else
  fail_case "certificate missing / buffer not in use (rc=${rc})" "$(head -c 2000 "$jm")"$'\n'"stderr: $(cat "$e")"
fi
jeq "... certificate found false, notAfter and daysLeft null, a certificate_risk alert" "$jm" \
  '[d["certificate"]["host"], d["certificate"]["found"], d["certificate"]["notAfter"], d["certificate"]["daysLeft"], d["certificate"]["path"].endswith("/nginx/certs/other.example.com.crt"), "certificate_risk" in [a["key"] for a in d["alerts"]]]' \
  '["other.example.com",false,null,null,true,true]'
jeq "... buffer not-in-use" "$jm" 'd["buffer"]' '{"count":null,"error":null,"oldestAgeHours":null,"state":"not-in-use"}'
check "no json run posted anything or created a state directory" \
  bash -c '[[ ! -e "$1" && ! -e "$2/.monitor-state" ]]' _ "$CURL_LOG" "$repo"

echo ""
echo "== text report =="
t1="${work}/text-default.txt"
t2="${work}/text-format.txt"
monitor "$t1" "$e"
rc1="$rc"
monitor "$t2" "$e" --format text
check "no --format: exit 0, starts with 'PadSign Status Report', ends with 'Report complete.'" \
  bash -c '[[ "$1" == 0 && "$(head -1 "$2")" == "PadSign Status Report" && "$(tail -1 "$2")" == "Report complete." ]]' _ "$rc1" "$t1"
check "--format text: exit 0, starts with 'PadSign Status Report'" \
  bash -c '[[ "$1" == 0 && "$(head -1 "$2")" == "PadSign Status Report" ]]' _ "$rc" "$t2"
if diff <(grep -v '^Generated: ' "$t1") <(grep -v '^Generated: ' "$t2") >/dev/null; then
  ok_case "--format text prints the same report as no --format"
else
  fail_case "--format text differs from no --format" "$(diff <(grep -v '^Generated: ' "$t1") <(grep -v '^Generated: ' "$t2"))"
fi

echo ""
echo "== lint =="
check "bash -n monitor-status.sh" bash -n "${src_root}/installation-scripts/monitor-status.sh"

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
exit $(( failed > 0 ))
