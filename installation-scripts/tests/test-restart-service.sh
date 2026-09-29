#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for restart-service.sh, which the Deployment Wizard's per-service
# Restart button runs (and an operator can run by hand):
#
#   - usage: --service is required, --health-timeout must be a whole number,
#     the name must be a service of the current compose model (exit 2);
#   - the wizard is refused before anything is restarted (exit 2);
#   - docker compose restart <service>, then a wait until it is healthy:
#     exit 0 with the "Step N/M:" and "  <name>: OK" lines the wizard's
#     outputParser reads;
#   - a failed restart, a service that turns unhealthy, and a service with
#     no container at all: exit 1, with an ERROR line on stderr.
#
# Usage:
#   ./installation-scripts/tests/test-restart-service.sh
#
# Hermetic. `docker` is a stub driven by environment variables (the
# restart's exit code, what inspect reports, whether a container exists)
# that records its argv, so a case can tell whether a restart was attempted.
# The script under test runs from this checkout, with </dev/null and a short
# --health-timeout.
#
# Exit codes: 0 all passed, 1 a case failed, 124 the watchdog
# (lib/watchdog.sh) stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="${src_root}/installation-scripts/restart-service.sh"
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR \
  STUB_RESTART_RC STUB_INSPECT STUB_NO_CONTAINER STUB_CONFIG_ERR

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/       | /'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }  # <text> <fixed string>

# ── stub ────────────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log"
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "${1:-}" == compose ]]; then
  shift
  case "${1:-}" in
    config)
      if [[ -n "${STUB_CONFIG_ERR:-}" ]]; then printf '%s\n' "$STUB_CONFIG_ERR" "second line" >&2; exit 1; fi
      [[ " $* " == *" --services "* ]] && printf '%s\n' ps-server nginx wizard ;;
    restart) exit "${STUB_RESTART_RC:-0}" ;;
    ps) [[ -z "${STUB_NO_CONTAINER:-}" ]] && echo "cid-${*: -1}" ;;
    logs) echo "ps-server  | PadSign Server listening on port 3001" ;;
  esac
  exit 0
fi
case "${1:-}" in
  inspect)
    if [[ "$*" == *'.State.Status'* ]]; then echo "${STUB_INSPECT:-running healthy 0}"; fi ;;
esac
exit 0
STUB
chmod +x "${bin}/docker"
export PATH="${bin}:${PATH}"

rc=0; out=""; err=""
run() {  # [args...]: sets rc, out (stdout) and err (stderr); clears the argv log
  : > "$STUB_LOG"
  rc=0
  bash "$script" "$@" </dev/null >"${work}/out" 2>"${work}/err" || rc=$?
  out="$(cat "${work}/out")"; err="$(cat "${work}/err")"
}
restarted() { grep -q '^compose restart' "$STUB_LOG"; }

echo "== usage =="
run
if [[ "$rc" == 2 ]] && has "$err" "--service" && ! restarted; then
  ok_case "no --service: exit 2, nothing restarted"
else
  fail_case "no --service (rc=${rc})" "$out"$'\n'"$err"
fi

run --service nope
if [[ "$rc" == 2 ]] && has "$err" "ERROR: unknown service 'nope'. Services: ps-server, nginx" && ! has "$err" "wizard" && ! restarted; then
  ok_case "--service nope: exit 2, 'ERROR: unknown service 'nope'. Services: ps-server, nginx', nothing restarted"
else
  fail_case "--service nope (rc=${rc})" "$out"$'\n'"$err"
fi

run --service wizard
if [[ "$rc" == 2 ]] && has "$err" "ERROR: the wizard cannot restart itself; on the host run: docker compose restart wizard" && ! restarted; then
  ok_case "--service wizard: exit 2 with the host command, no docker compose restart"
else
  fail_case "--service wizard (rc=${rc})" "$out"$'\n'"$err"$'\n'"docker calls: $(cat "$STUB_LOG")"
fi

bad=""
for t in abc 5s -1 ""; do
  run --service ps-server --health-timeout "$t"
  if [[ "$rc" != 2 ]] || restarted; then bad+="--health-timeout '${t}': rc=${rc}"$'\n'; fi
done
if [[ -z "$bad" ]]; then
  ok_case "--health-timeout abc / 5s / -1 / empty: exit 2, nothing restarted"
else
  fail_case "--health-timeout validation" "$bad"
fi

run --service ps-server --health-timeout 12345678901234567890
if [[ "$rc" == 2 ]] && has "$err" "at most 6 digits" && ! restarted; then
  ok_case "--health-timeout with 20 digits: exit 2, nothing restarted"
else
  fail_case "--health-timeout with 20 digits (rc=${rc})" "$out"$'\n'"$err"
fi

run --service ps-server --health-timeout 08
if [[ "$rc" == 0 ]] && has "$out" "Step 2/2: Waiting for ps-server to become healthy (up to 8s)"; then
  ok_case "--health-timeout 08: read as 8 seconds (not octal), exit 0"
else
  fail_case "--health-timeout 08 (rc=${rc})" "$out"$'\n'"$err"
fi

STUB_CONFIG_ERR="yaml: line 3: did not find expected key" run --service ps-server --health-timeout 5
if [[ "$rc" == 1 ]] \
   && has "$err" "ERROR: could not list the services (docker compose config --services failed in " \
   && has "$err" "): yaml: line 3: did not find expected key" && ! has "$err" "second line" && ! restarted; then
  ok_case "docker compose config fails: exit 1, its first stderr line in the ERROR message, nothing restarted"
else
  fail_case "docker compose config fails (rc=${rc})" "$out"$'\n'"$err"
fi

echo ""
echo "== restart =="
run --service ps-server --health-timeout 5
want=$'PadSign service restart\n================================\nStep 1/2: Restarting ps-server\nStep 2/2: Waiting for ps-server to become healthy (up to 5s)\n  ps-server: OK (running and healthy)\nRestart complete.'
if [[ "$rc" == 0 && "$out" == "$want" ]]; then
  ok_case "healthy after the restart: exit 0, the exact output lines"
else
  fail_case "healthy after the restart (rc=${rc})" "$out"$'\n'"$err"
fi
if [[ "$(grep -cx 'compose restart ps-server' "$STUB_LOG")" == 1 ]]; then
  ok_case "ran 'docker compose restart ps-server' (keeps the container), once"
else
  fail_case "docker compose restart ps-server not run as expected" "$(cat "$STUB_LOG")"
fi
# The wizard's outputParser: STEP_RE and COLON_CHECK_RE.
steps="$(grep -cE '^Step [0-9]+[a-z]?/[0-9]+:[[:space:]]*.+$' <<< "$out")"
checks="$(grep -cE '^ {2}[^:]+:[[:space:]]*(OK|WARNING)([^A-Za-z0-9_]|$)' <<< "$out")"
if [[ "$steps" == 2 && "$checks" == 1 ]]; then
  ok_case "two 'Step N/M:' lines and one '  <name>: OK' check, as the wizard's outputParser reads them"
else
  fail_case "outputParser lines: ${steps} steps, ${checks} checks" "$out"
fi

run --service nginx
if [[ "$rc" == 0 ]] && has "$out" "Step 2/2: Waiting for nginx to become healthy (up to 480s)"; then
  ok_case "default --health-timeout: 480 s"
else
  fail_case "default --health-timeout (rc=${rc})" "$out"$'\n'"$err"
fi

STUB_RESTART_RC=1 run --service ps-server --health-timeout 5
if [[ "$rc" == 1 ]] && has "$err" "ERROR: docker compose restart ps-server failed" && ! has "$out" "Step 2/2"; then
  ok_case "docker compose restart fails: exit 1, ERROR on stderr, no health wait"
else
  fail_case "failed restart (rc=${rc})" "$out"$'\n'"$err"
fi

STUB_INSPECT='running unhealthy 0' run --service ps-server --health-timeout 5
if [[ "$rc" == 1 ]] && has "$err" "unhealthy" \
   && has "$err" "ERROR: ps-server is not healthy after the restart - see the output above" \
   && ! has "$out" "Restart complete."; then
  ok_case "unhealthy after the restart: exit 1, the health wait's reason and the ERROR line on stderr"
else
  fail_case "unhealthy after the restart (rc=${rc})" "$out"$'\n'"$err"
fi

STUB_INSPECT='running starting 0' run --service ps-server --health-timeout 3
if [[ "$rc" == 1 ]] && has "$err" "not healthy after 3s" \
   && has "$err" "ERROR: ps-server is not healthy after the restart - see the output above" \
   && ! has "$out" "Restart complete."; then
  ok_case "still starting when --health-timeout 3 runs out: exit 1, 'not healthy after 3s' and the ERROR line"
else
  fail_case "health wait timeout (rc=${rc})" "$out"$'\n'"$err"
fi

STUB_NO_CONTAINER=1 run --service ps-server --health-timeout 5
if [[ "$rc" == 1 ]] && has "$err" "ERROR: ps-server has no container" && ! restarted; then
  ok_case "a service with no container: exit 1 before any restart (docker compose up -d creates it)"
else
  fail_case "no container (rc=${rc})" "$out"$'\n'"$err"
fi

echo ""
echo "== lint =="
if bash -n "$script"; then ok_case "bash -n restart-service.sh"; else fail_case "bash -n restart-service.sh"; fi

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
exit $(( failed > 0 ))
