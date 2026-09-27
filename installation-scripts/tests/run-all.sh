#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Run every check this repository has, in one go. CI runs exactly this.
#
#   1. bash -n on every tracked shell script
#   2. shellcheck --severity=error (skipped when shellcheck is not installed)
#   3. every installation-scripts/tests/test-*.sh (test-docs.sh included)
#   4. docker compose config for the default, local-eseal and wizard
#      profiles (skipped without docker)
#   5. the Deployment Wizard's own tests: npm ci + npm test in
#      deployment-wizard/ (skipped without npm)
#
# Usage:
#   ./installation-scripts/tests/run-all.sh
#
# Exit codes: 0 everything passed (or was skipped), 1 something failed.
# ============================================================================

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1

failures=()
section() { printf '\n==== %s\n' "$1"; }
record()  { if [[ "$2" == 0 ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; failures+=("$1"); fi; }
skip()    { printf '  skip  %s (%s)\n' "$1" "$2"; }

mapfile -t scripts < <(git ls-files '*.sh')

section "bash -n"
rc=0
for s in "${scripts[@]}"; do bash -n "$s" || { echo "  syntax error: $s"; rc=1; }; done
record "bash -n (${#scripts[@]} scripts)" "$rc"

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error "${scripts[@]}"
  record "shellcheck --severity=error" "$?"
else
  skip "shellcheck" "not installed"
fi

section "test suites"
for t in installation-scripts/tests/test-*.sh; do
  log="$(bash "$t" 2>&1)"; rc=$?
  summary="$(grep -E '[0-9]+ passed' <<< "$log" | tail -n 1)"
  record "$(basename "$t")${summary:+ - ${summary}}" "$rc"
  [[ "$rc" == 0 ]] || grep -E '^\s+FAIL' <<< "$log" | head -n 20
done

section "docker compose config"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  for profile in "" local-eseal wizard; do
    args=(); [[ -n "$profile" ]] && args=(--profile "$profile")
    COMPOSE_PROFILES="" docker compose "${args[@]}" config -q >/dev/null 2>&1 </dev/null
    record "docker compose ${profile:+--profile $profile }config" "$?"
  done
else
  skip "docker compose config" "docker compose not available"
fi

section "deployment-wizard"
if command -v npm >/dev/null 2>&1; then
  (cd deployment-wizard && { [[ -d node_modules ]] || npm ci --no-audit --no-fund >/dev/null; } && npm test >/dev/null 2>&1)
  record "npm test" "$?"
else
  skip "npm test" "npm not installed"
fi

echo ""
if (( ${#failures[@]} )); then
  echo "FAILED: ${failures[*]}"
  exit 1
fi
echo "All checks passed."
