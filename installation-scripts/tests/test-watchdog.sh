#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Tests for the whole-suite watchdog every test suite here sources
# (installation-scripts/tests/lib/watchdog.sh): a suite that blocks is
# stopped at TEST_WATCHDOG_SECS with exit 124 and the command it was stuck
# in, still removes its throwaway copy, and leaves no process behind. A
# suite that finishes is neither delayed nor changed by it.
#
# Usage:
#   ./installation-scripts/tests/test-watchdog.sh
#
# Runs small suites shaped like the real ones (set -euo pipefail, a
# throwaway directory removed by an EXIT trap) in a temporary directory,
# with a limit of a few seconds. Nothing outside it is touched.
#
# Exit codes: 0 all passed, 1 a case failed, 124 the watchdog stopped this suite.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="${src_root}/installation-scripts/tests/lib/watchdog.sh"

# Every process a case starts carries one of these in its command line, so a
# leftover one can be found (and is stopped on exit whatever happened).
markers=("sleep 917" "sleep 918")
running_with() {  # <text> -> the pids whose command line contains <text>
  local f
  local -a argv
  for f in /proc/[0-9]*/cmdline; do
    { mapfile -d '' -t argv < "$f"; } 2>/dev/null || continue
    [[ " ${argv[*]} " == *" $1 "* ]] && { f="${f#/proc/}"; echo "${f%%/*}"; }
  done
  return 0
}
work="$(mktemp -d)"
cleanup() {
  local m
  for m in "${markers[@]}"; do
    # shellcheck disable=SC2046 # one pid per word
    kill -KILL $(running_with "$m") 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
# shellcheck source=lib/watchdog.sh
. "$lib"
watchdog_start

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() {
  failed=$((failed + 1)); printf '  FAIL %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/       | /'; fi
  return 0
}

# fake_suite <name> <body>: a suite like the real ones, with <body> after
# watchdog_start. Its throwaway directory is ${work}/<name>.tmp.
fake_suite() {
  cat > "${work}/$1.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
tmp="${work}/$1.tmp"
mkdir -p "\$tmp"
trap 'rm -rf "\$tmp"' EXIT
. "${lib}"
watchdog_start
$2
EOF
}
# run_suite <name> [VAR=value]...: runs it with its output in ${work}/<name>.out
# and its exit code in $rc, without the caller's TEST_WATCHDOG_SECS. The outer
# `timeout` only keeps this suite from hanging when the watchdog fails: it
# kills with SIGKILL (exit 137), never 124.
run_suite() {
  local name="$1"; shift
  set +e
  env -u TEST_WATCHDOG_SECS "$@" timeout -s KILL 90 bash "${work}/${name}.sh" > "${work}/${name}.out" 2>&1 < /dev/null
  rc=$?
  set -e
}

echo ""
echo "A suite that blocks:"

fake_suite stuck-cmd 'echo started; sleep 917; echo reached > "$tmp/../stuck-cmd.next"'
t0=$SECONDS
run_suite stuck-cmd TEST_WATCHDOG_SECS=3
took=$((SECONDS - t0))
out="$(cat "${work}/stuck-cmd.out")"
if [[ $rc -eq 124 ]] && grep -q "WATCHDOG: stuck-cmd.sh still running after 3s" <<< "$out" \
   && grep -qE '^ +[0-9]+ sleep 917$' <<< "$out" && [[ ! -e "${work}/stuck-cmd.next" && $took -lt 60 ]]; then
  ok_case "blocked in a command: exit 124 after the limit, names the command, does not go on"
else
  fail_case "blocked command (rc=${rc}, ${took}s)" "$out"
fi
if [[ ! -d "${work}/stuck-cmd.tmp" && -z "$(running_with "sleep 917")" ]]; then
  ok_case "its EXIT trap removed its throwaway copy, and nothing it started is left running"
else
  fail_case "cleanup after the stop (tmp left: $([[ -d "${work}/stuck-cmd.tmp" ]] && echo yes || echo no), still running: $(running_with "sleep 917"))"
fi

# The harness pattern: a script run in a command substitution with errexit
# off, its output checked afterwards. The stop must not reach the check.
fake_suite stuck-subst 'set +e
out="$(bash -c "echo inner; sleep 918; echo done")"; rc=$?
set -e
echo "checked rc=$rc" > "$tmp/../stuck-subst.next"'
run_suite stuck-subst TEST_WATCHDOG_SECS=3
out="$(cat "${work}/stuck-subst.out")"
if [[ $rc -eq 124 && ! -e "${work}/stuck-subst.next" && ! -d "${work}/stuck-subst.tmp" ]] \
   && grep -qE '^ +[0-9]+ bash -c echo inner; sleep 918; echo done$' <<< "$out" && grep -qE '^ +[0-9]+ sleep 918$' <<< "$out" \
   && [[ -z "$(running_with "sleep 918")" ]]; then
  ok_case "blocked two levels down in \$(...): the tree is printed, the next line never runs"
else
  fail_case "blocked command substitution (rc=${rc})" "$out"
fi

# A read that never gets data (a script waiting on a terminal), in the
# shell itself: nothing runs under the suite, and the signal ends the read.
fake_suite stuck-read 'mkfifo "$tmp/in"; exec 3<>"$tmp/in"
read -r answer <&3
echo "got ${answer}" > "$tmp/../stuck-read.next"'
run_suite stuck-read TEST_WATCHDOG_SECS=3
out="$(cat "${work}/stuck-read.out")"
if [[ $rc -eq 124 && ! -e "${work}/stuck-read.next" && ! -d "${work}/stuck-read.tmp" ]] \
   && grep -q "no process under it" <<< "$out"; then
  ok_case "blocked in the shell's own read: exit 124, says nothing runs under it"
else
  fail_case "blocked read (rc=${rc})" "$out"
fi

# An outside `timeout` sends TERM to the suite and then to its whole process
# group, the watchdog included. The second TERM used to cut the EXIT trap
# short under Git Bash; on Linux, the background watchdog made bash skip it
# now and then. 8 s: well after the suite has set its traps, even under Git Bash.
fake_suite outer-kill 'echo started; sleep 918'
set +e
env -u TEST_WATCHDOG_SECS timeout -s TERM 8 bash "${work}/outer-kill.sh" > "${work}/outer-kill.out" 2>&1 < /dev/null
rc=$?
set -e
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -d "${work}/outer-kill.tmp" ]] || break; sleep 0.5; done
if [[ $rc -eq 124 && ! -d "${work}/outer-kill.tmp" ]]; then
  ok_case "stopped from outside by timeout: its own EXIT trap still removes its copy"
else
  fail_case "outside timeout (rc=${rc}, tmp left: $([[ -d "${work}/outer-kill.tmp" ]] && echo yes || echo no))" "$(cat "${work}/outer-kill.out")"
fi

echo ""
echo "A suite that finishes:"

fake_suite fine 'echo "work done"; printf "%s\n" "$EPOCHREALTIME" > "$tmp/../fine.end"'
set +e
bash "${work}/fine.sh" 2>&1 < /dev/null | cat > "${work}/fine.out"
rc="${PIPESTATUS[0]}"
set -e
closed="$EPOCHREALTIME"
lag="$(awk -v a="$(cat "${work}/fine.end")" -v b="$closed" 'BEGIN { printf "%.1f", b - a }')"
out="$(cat "${work}/fine.out")"
if [[ $rc -eq 0 && "$out" == "work done" && ! -d "${work}/fine.tmp" ]] && awk -v l="$lag" 'BEGIN { exit !(l < 3) }'; then
  ok_case "exit 0, output unchanged, its EXIT trap still runs, and a pipe after it closes at once (${lag}s)"
else
  fail_case "normal suite (rc=${rc}, pipe closed ${lag}s after its last line)" "$out"
fi

fake_suite jobs 'jobs -p > "$tmp/../jobs.list"'
run_suite jobs
default_jobs="$(wc -l < "${work}/jobs.list")"
run_suite jobs TEST_WATCHDOG_SECS=0
off_jobs="$(wc -l < "${work}/jobs.list")"
if [[ $rc -eq 0 && "$default_jobs" -eq 1 && "$off_jobs" -eq 0 ]]; then
  ok_case "TEST_WATCHDOG_SECS=0 starts no watchdog (the default starts one)"
else
  fail_case "TEST_WATCHDOG_SECS=0 (rc=${rc}, background jobs: default ${default_jobs}, off ${off_jobs})"
fi

run_suite jobs TEST_WATCHDOG_SECS=soon
out="$(cat "${work}/jobs.out")"
if [[ $rc -eq 2 ]] && grep -q "TEST_WATCHDOG_SECS must be a whole number of seconds" <<< "$out"; then
  ok_case "a TEST_WATCHDOG_SECS that is not a number: exit 2 before any case"
else
  fail_case "invalid TEST_WATCHDOG_SECS (rc=${rc})" "$out"
fi

echo ""
echo "${pass} passed, ${failed} failed."
[[ "$failed" -eq 0 ]]
