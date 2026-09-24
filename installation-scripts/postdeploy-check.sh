#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Post-Deploy Validator — orchestrates the existing standalone
# verify/validate scripts plus new checks this script owns directly, into
# one pass an operator (or a deployment pipeline) runs right after
# bootstrap.sh / upgrade.sh.
#
# Usage:
#   ./installation-scripts/postdeploy-check.sh --host example.com
#                                   [--company-role "Acme"] [--realm padsign]
#                                   [--admin-user admin] [--admin-pass secret]
#
# --company-role additionally enables the verify-keycloak.sh realm/client
# checks (it needs a role to check the test user against). Without it, those
# checks are skipped with a note — everything else still runs.
#
# Exit codes:
#   0  every check passed (SKIPs are allowed)
#   1  one or more checks FAILED
#   2  argument error
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"
# shellcheck source=lib/deployment-evidence.sh
. "${scripts_dir}/lib/deployment-evidence.sh"

host=""
company_role=""
realm="padsign"
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
signing_smoke=false
signing_smoke_seal=false
# psapp's dev-stack Playwright spec (psapp-saas#9) runs only when its path is
# given explicitly - it is for a dev/staging stack, not a customer host.
smoke_spec_path="${PADSIGN_SIGNING_SMOKE_SPEC:-}"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/postdeploy-check.sh --host example.com
                                  [--company-role "Acme"] [--realm padsign]
                                  [--admin-user admin] [--admin-pass secret]
                                  [--signing-smoke [--signing-smoke-with-seal]]

Runs, in order:
  1. validate-config.sh --host <host>
  2. verify-keycloak.sh --host <host> --company-role <role>   (only if --company-role given)
  3. Redirect check:            https://<host>/ -> 301 -> /portal/
  4. Portal/runtime config:     served /portal/constants.json matches config/constants.json
  5. Keycloak discovery:        /auth/realms/<realm>/.well-known/openid-configuration
  6. Protected API behavior:    unauthenticated /api/health is rejected, not 200
  7. Authorized signing smoke test (opt-in: --signing-smoke): runs
     signing-smoke.sh, which is safe on a production host - a disposable smoke
     user approves in the operator's browser, one synthetic document is signed
     and verified, nothing is routed, everything is cleaned up. Needs an
     interactive terminal and the Keycloak admin password (the --admin-pass
     value or KEYCLOAK_ADMIN_PASSWORD, handed over via the environment). The
     deployment's e-seal is applied only with --signing-smoke-with-seal. See
     documentation/40-05-production-safe-signing-smoke-test.md.
     Dev/staging only: PADSIGN_SIGNING_SMOKE_SPEC=<psapp spec path> instead
     runs psapp's authenticated-sign-flow Playwright spec (psapp-saas#9).
     SKIPPED otherwise.
  8. TLS:                       verify-served-cert.sh
  9. Deployment evidence written (deployment-evidence.json)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --signing-smoke) signing_smoke=true; shift;;
    --signing-smoke-with-seal) signing_smoke=true; signing_smoke_seal=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host." >&2
  usage
  exit 2
fi

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
skip() { printf '  SKIP %s\n' "$*"; }

echo "PadSign Post-Deploy Validator"
echo "================================"
echo "Host: ${host}"
echo ""

# ── 1. Config validation ──
echo "== 1. Config validation (validate-config.sh) =="
if "${scripts_dir}/validate-config.sh" --host "$host"; then
  ok "validate-config.sh passed"
else
  bad "validate-config.sh reported failures (see above)"
fi
echo ""

# ── 2. Keycloak realm/client checks (needs --company-role) ──
echo "== 2. Keycloak realm/client checks (verify-keycloak.sh) =="
if [[ -n "$company_role" ]]; then
  if "${scripts_dir}/verify-keycloak.sh" --host "$host" --company-role "$company_role" \
       --realm "$realm" --admin-user "$admin_user" --admin-pass "$admin_pass"; then
    ok "verify-keycloak.sh passed"
  else
    bad "verify-keycloak.sh reported failures (see above)"
  fi
else
  skip "verify-keycloak.sh (pass --company-role to enable)"
fi
echo ""

# ── 3. Redirect ──
echo "== 3. HTTP -> HTTPS -> /portal/ redirect =="
redirect_code="$(curl -ksI --max-time 10 "https://${host}/" 2>/dev/null | head -1 | awk '{print $2}' || echo "")"
redirect_location="$(curl -ksI --max-time 10 "https://${host}/" 2>/dev/null | tr -d '\r' | grep -i '^location:' | awk '{print $2}' || echo "")"
if [[ "$redirect_code" == "301" && "$redirect_location" == *"/portal/"* ]]; then
  ok "https://${host}/ -> 301 -> ${redirect_location}"
else
  bad "https://${host}/ did not return a 301 to /portal/ (got code='${redirect_code}' location='${redirect_location}')"
fi
echo ""

# ── 4. Portal/runtime config served correctly ──
echo "== 4. Portal runtime config (constants.json served vs on-disk) =="
served_constants="$(curl -ks --max-time 10 "https://${host}/portal/constants.json" 2>/dev/null || echo "")"
if [[ -z "$served_constants" ]]; then
  bad "could not fetch https://${host}/portal/constants.json"
else
  # set -e means a bare command's non-zero exit would abort the whole
  # script right here - wrap in `if` so a genuine field mismatch (exit 1,
  # intentional) just sets `fail` and lets the rest of the checks run.
  if ! CONSTANTS_LOCAL="${repo_root}/config/constants.json" SERVED_JSON="$served_constants" python3 <<'PY'
import json
import os
import sys

fields = [
    "KEYCLOAK_URL",
    "KEYCLOAK_REDIRECT_URI",
    "KEYCLOAK_POST_LOGOUT_REDIRECT_URI",
    "PS_DOWNLOAD_API",
    "PDF_TEST_PATH",
]

try:
    local = json.load(open(os.environ["CONSTANTS_LOCAL"], encoding="utf-8"))
except (OSError, json.JSONDecodeError) as e:
    print(f"  FAIL could not read local config/constants.json: {e}")
    sys.exit(1)

try:
    served = json.loads(os.environ["SERVED_JSON"])
except json.JSONDecodeError as e:
    print(f"  FAIL served constants.json is not valid JSON: {e}")
    sys.exit(1)

failed = False
for field in fields:
    lv, sv = local.get(field), served.get(field)
    if lv != sv:
        print(f"  FAIL served constants.json field {field!r}: local={lv!r} served={sv!r}")
        failed = True
    else:
        print(f"  OK   served constants.json field {field!r} matches ({sv!r})")

sys.exit(1 if failed else 0)
PY
  then
    fail=1
  fi
fi
echo ""

# ── 5. Keycloak discovery through nginx ──
echo "== 5. Keycloak discovery endpoint =="
discovery_url="https://${host}/auth/realms/${realm}/.well-known/openid-configuration"
discovery_body="$(curl -ks --max-time 10 "$discovery_url" 2>/dev/null || echo "")"
if echo "$discovery_body" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('issuer') else 1)" 2>/dev/null; then
  ok "${discovery_url} reachable, issuer present"
else
  bad "${discovery_url} did not return a valid discovery document"
fi
echo ""

# ── 6. Protected API behavior (unauthenticated) ──
echo "== 6. Protected API behavior (unauthenticated request rejected) =="
api_code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}/api/health" 2>/dev/null || echo "000")"
if [[ "$api_code" == "401" || "$api_code" == "403" ]]; then
  ok "unauthenticated GET /api/health rejected (${api_code})"
elif [[ "$api_code" == "200" ]]; then
  bad "unauthenticated GET /api/health returned 200 — protected route is NOT enforcing auth"
else
  bad "unauthenticated GET /api/health returned unexpected code '${api_code}' (expected 401/403)"
fi
echo ""

# ── 7. Authorized signing smoke test ──
echo "== 7. Authorized signing smoke test =="
if [[ "$signing_smoke" == true ]]; then
  smoke_args=(--host "$host" --realm "$realm" --admin-user "$admin_user")
  [[ "$signing_smoke_seal" == true ]] && smoke_args+=(--with-seal)
  # The admin password goes through the environment, never argv.
  if KEYCLOAK_ADMIN_PASSWORD="$admin_pass" "${scripts_dir}/signing-smoke.sh" "${smoke_args[@]}" 2>&1 | sed 's/^/  /'; [[ "${PIPESTATUS[0]}" -eq 0 ]]; then
    ok "production-safe signing smoke test passed"
  else
    bad "production-safe signing smoke test FAILED (see above)"
  fi
elif [[ -n "$smoke_spec_path" ]]; then
  # Dev/staging only (documentation/40-02): the spec is excluded from psapp's
  # default playwright.config.js (testIgnore) and only runs under
  # client/playwright.auth.config.js, which reads the target from
  # PADSIGN_STACK_URL - so both have to be passed, from the client/ dir.
  smoke_client_dir="$(cd "$(dirname "$smoke_spec_path")/../.." 2>/dev/null && pwd || true)"
  if [[ ! -f "$smoke_spec_path" || ! -f "${smoke_client_dir}/playwright.auth.config.js" ]]; then
    bad "PADSIGN_SIGNING_SMOKE_SPEC=${smoke_spec_path} (and its client/playwright.auth.config.js) not found"
  elif ! command -v npx >/dev/null 2>&1; then
    bad "dev-stack signing spec requested but npx is not installed"
  else
    echo "  Running ${smoke_spec_path} against https://${host} (dev/staging spec) ..."
    if (cd "$smoke_client_dir" && PADSIGN_STACK_URL="https://${host}" npx playwright test --config=playwright.auth.config.js --reporter=line); then
      ok "dev-stack authenticated signing spec passed"
    else
      bad "dev-stack authenticated signing spec FAILED"
    fi
  fi
else
  skip "authorized signing smoke test (opt-in: pass --signing-smoke; needs an interactive terminal)"
fi
echo ""

# ── 8. TLS (wire-level) ──
echo "== 8. TLS certificate (verify-served-cert.sh) =="
if "${scripts_dir}/verify-served-cert.sh" --host "$host"; then
  ok "verify-served-cert.sh passed"
else
  bad "verify-served-cert.sh reported failures (see above)"
fi
echo ""

# ── 9. Deployment evidence ──
echo "== 9. Deployment evidence =="
write_deployment_evidence "postdeploy-check"
echo ""

echo "================================"
if [[ "$fail" -eq 0 ]]; then
  echo "All post-deploy checks passed (SKIPs are informational, not failures)."
  exit 0
else
  echo "Some post-deploy checks FAILED. Review above."
  exit 1
fi
