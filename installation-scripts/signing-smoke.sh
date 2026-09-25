#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign production-safe signing smoke test (psapp-saas#12).
#
# Signs ONE synthetic document on a live deployment as a real Keycloak user,
# checks the result, proves nothing was routed, and cleans up. Design, the
# options that were rejected, and what it deliberately does not do:
# documentation/40-05-production-safe-signing-smoke-test.md.
#
# The smoke user's password is never handed to this script (same rule as
# smoke-user.sh): the operator logs in on Keycloak's own device-verification
# page in their browser (OAuth 2.0 device authorization grant) and the script
# only ever holds a short-lived access token, in a mode-600 file.
#
# Routing safety is structural: the document is uploaded through the demo
# path, and its in-memory user entry is dropped before anything that routes
# (/api/stamp) is called, while /api/finalize-signing is never called. With no
# user entry ps-server has nobody to route the document for, whatever
# DOCUMENT_ROUTING.skipDemo says.
#
# Exit codes: 0 all checks passed, 1 a check failed, 2 usage/dependency error.
# Cleanup runs in every case.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"
# shellcheck source=lib/kcadm.sh
. "${scripts_dir}/lib/kcadm.sh"

usage() {
  cat <<'EOF'
Usage:
  KEYCLOAK_ADMIN_PASSWORD=... ./installation-scripts/signing-smoke.sh --host padsign.client.com
                                  [--realm padsign] [--admin-user admin]
                                  [--username smoke-xxxxxxxx] [--with-seal]
                                  [--cacert ca.pem] [--approve-timeout 300]

Signs one synthetic "PADSIGN SMOKE TEST" PDF as a disposable smoke user and
verifies it, without the document reaching routing destinations, webhooks or
the receive-back buffer, then removes everything it created.

  --host             public hostname of the deployment (host[:port]); required
  --realm            Keycloak realm (default: padsign)
  --admin-user       Keycloak admin user (default: $KEYCLOAK_ADMIN or admin)
  --username         use this existing smoke-* user (from smoke-user.sh create)
                     instead of creating one; it is logged out afterwards,
                     not deleted
  --with-seal        also seal the document with the deployment's CONFIGURED
                     e-seal (external provider or local keystore). Off by
                     default: a production seal on a test document is a real
                     signature by the customer's legal entity
  --cacert           CA bundle to trust for the host's certificate (test
                     stacks); TLS is always verified
  --approve-timeout  seconds to wait for the browser approval (default: 300)

The Keycloak admin password is read from KEYCLOAK_ADMIN_PASSWORD, or prompted
for (hidden) when a terminal is attached. It is never accepted as a flag.
Without --username an interactive terminal is required: the new smoke user's
password is shown there once by smoke-user.sh, and nowhere else.
EOF
}

host=""
realm="padsign"
admin_user="${KEYCLOAK_ADMIN:-admin}"
existing_user=""
with_seal=false
cacert=""
approve_timeout=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --username) existing_user="${2:-}"; shift 2;;
    --with-seal) with_seal=true; shift;;
    --cacert) cacert="${2:-}"; shift 2;;
    --approve-timeout) approve_timeout="${2:-}"; shift 2;;
    --admin-pass)
      echo "ERROR: --admin-pass is not accepted here (secrets never go on a command line)." >&2
      echo "       Export KEYCLOAK_ADMIN_PASSWORD, or run at a terminal to be prompted." >&2
      exit 2;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host." >&2
  usage
  exit 2
fi
if ! [[ "$approve_timeout" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --approve-timeout must be a whole number of seconds." >&2
  exit 2
fi
if [[ -n "$existing_user" && "$existing_user" != smoke-* ]]; then
  echo "ERROR: --username must be a smoke-* user created by smoke-user.sh (got '${existing_user}')." >&2
  exit 2
fi
if [[ -n "$cacert" && ! -f "$cacert" ]]; then
  echo "ERROR: --cacert file not found: ${cacert}" >&2
  exit 2
fi
for cmd in docker curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: ${cmd}" >&2
    exit 2
  fi
done

have_tty=false
if { : > /dev/tty; } 2>/dev/null; then have_tty=true; fi

if [[ -z "$existing_user" && "$have_tty" != true ]]; then
  echo "ERROR: no interactive terminal attached, so a new smoke user's password could" >&2
  echo "       not be shown to you. Create one at a terminal with" >&2
  echo "       ./installation-scripts/smoke-user.sh create ... and pass --username." >&2
  exit 2
fi

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  if [[ "$have_tty" == true ]]; then
    printf 'Keycloak admin password for %s (not echoed): ' "$admin_user" > /dev/tty
    IFS= read -rs KEYCLOAK_ADMIN_PASSWORD < /dev/tty
    printf '\n' > /dev/tty
  fi
  if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
    echo "ERROR: set KEYCLOAK_ADMIN_PASSWORD (or run at a terminal to be prompted)." >&2
    exit 2
  fi
fi
# smoke-user.sh reads it from the environment too, so it never needs a flag.
export KEYCLOAK_ADMIN_PASSWORD

cd "$repo_root"

base="https://${host}"
run_id="$(date -u +%Y%m%d%H%M%S)-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 6)"
marker="PADSIGN-SMOKE-${run_id}"
smoke_role="padsign-smoke"
smoke_client="padsign-smoke-${run_id}"

umask 077
work="$(mktemp -d "${TMPDIR:-/tmp}/padsign-signing-smoke.XXXXXX")"
auth_hdr="${work}/auth.hdr"
curl_opts=(--silent --show-error --max-time 60)
[[ -n "$cacert" ]] && curl_opts+=(--cacert "$cacert")

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
skip() { printf '  SKIP %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; }

# State the cleanup trap acts on. Each is set only once the thing exists.
kc_logged_in=false
client_created=false
role_created=false
user_created=false
smoke_user=""
docid=""
user_entry_dropped=false

# ── helpers ──────────────────────────────────────────────────────────────────

# api <method> <path> <out-file> [curl args...] -> prints the HTTP status.
# The token reaches curl as -H @file, never as a process argument.
api() {
  local method="$1" path="$2" out="$3"; shift 3
  curl "${curl_opts[@]}" -X "$method" -H @"$auth_hdr" -o "$out" -w '%{http_code}' "$@" "${base}${path}" 2>"${work}/curl.err" || true
}

json_field() {  # <file> <dotted.key> -> value or empty
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1], encoding="utf-8"))
    for k in sys.argv[2].split("."):
        v = v[k]
    print(v if not isinstance(v, bool) else str(v).lower())
except Exception:
    pass
PY
}

ps_server_node() {  # runs a node snippet inside ps-server; extra -e VAR=... before it
  local -a envs=()
  while [[ "${1:-}" == -e ]]; do envs+=("$1" "$2"); shift 2; done
  # MSYS_NO_PATHCONV stops Git Bash (Windows dev hosts) rewriting /usr/...
  # stdin is /dev/null: `exec -T` still forwards stdin (see lib/kcadm.sh kc_exec).
  MSYS_NO_PATHCONV=1 docker compose exec -T "${envs[@]}" ps-server node -e "$1" </dev/null
}

# kc_step <what> <kcadm command...>: kcadm's chatter ("Logging into ...",
# "Created new ... with id") stays out of the report; on failure its last
# stderr line is shown and the run stops (cleanup still runs).
kc_step() {
  local what="$1"; shift
  if ! kc_exec "$*" >/dev/null 2>"${work}/kc.err"; then
    bad "${what} failed: $(tr -d '\r' < "${work}/kc.err" | tail -1)"
    exit 1
  fi
}

kc_relogin() { kc_login "${admin_user}" "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null 2>&1; }

cleanup() {
  local rc=$?
  set +e
  trap - EXIT INT TERM
  echo ""
  echo "== Cleanup =="
  local leftovers=0

  if [[ -n "$docid" ]]; then
    if [[ -s "$auth_hdr" ]]; then
      local code
      code="$(api GET "/api/cleanupUser?doc=${docid}" "${work}/cleanup.json")"
      if [[ "$user_entry_dropped" == true ]]; then
        ok "ps-server user entry for ${docid} was removed during the run (re-check: removedCount=$(json_field "${work}/cleanup.json" removedCount))"
      elif [[ "$code" == "200" ]]; then
        ok "ps-server user entry for ${docid} removed (removedCount=$(json_field "${work}/cleanup.json" removedCount))"
      else
        warn "could not remove ps-server's user entry for ${docid} (HTTP ${code}); it expires on its own after USER_ENTRY_TTL_MS / PAD_ARRIVAL_TIMEOUT_MS"
        leftovers=1
      fi
    fi
    archive_delete || leftovers=1
  fi

  if [[ "$kc_logged_in" == true ]]; then
    # smoke-user.sh removes the shared kcadm session on its own exit, so log
    # in again rather than assume the earlier session is still there.
    kc_relogin
    if [[ "$client_created" == true ]]; then
      local cuuid
      cuuid="$(kc_client_uuid "$realm" "$smoke_client")"
      if [[ -n "$cuuid" ]] && kc_exec "/opt/keycloak/bin/kcadm.sh delete clients/${cuuid} -r ${realm}" >/dev/null 2>&1; then
        ok "temporary Keycloak client ${smoke_client} deleted"
      else
        warn "could not delete temporary Keycloak client ${smoke_client} - delete it in the admin console"
        leftovers=1
      fi
    fi
    if [[ -n "$smoke_user" ]]; then
      if [[ "$user_created" == true ]]; then
        local del_out
        if del_out="$("${scripts_dir}/smoke-user.sh" delete --host "$host" --realm "$realm" --admin-user "$admin_user" --username "$smoke_user" 2>&1)" \
           && grep -q "^Deleted user '${smoke_user}'" <<<"$del_out"; then
          ok "smoke user ${smoke_user} deleted"
        else
          warn "could not delete smoke user ${smoke_user}: ./installation-scripts/smoke-user.sh delete --host ${host} --username ${smoke_user}"
          leftovers=1
        fi
        kc_relogin
      else
        local uid
        uid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${smoke_user} -q exact=true --fields id --format csv")"
        if [[ -n "$uid" && "$uid" != "id" ]] && kc_exec "/opt/keycloak/bin/kcadm.sh create users/${uid}/logout -r ${realm}" >/dev/null 2>&1; then
          ok "existing smoke user ${smoke_user} logged out (kept, as requested)"
        else
          warn "could not log out ${smoke_user}'s sessions"
        fi
      fi
    fi
    if [[ "$role_created" == true ]]; then
      if kc_exec "/opt/keycloak/bin/kcadm.sh delete roles/${smoke_role} -r ${realm}" >/dev/null 2>&1; then
        ok "realm role ${smoke_role} (created by this run) deleted"
      else
        warn "could not delete realm role ${smoke_role}"
        leftovers=1
      fi
    fi
    kc_logout
  fi

  rm -rf "$work"
  ok "temporary directory (held the access token) removed"

  echo ""
  echo "================================"
  if [[ "$rc" -eq 0 && "$fail" -eq 0 ]]; then
    if [[ "$leftovers" -ne 0 ]]; then
      echo "Signing smoke test passed, but cleanup left something behind (WARN above)."
      exit 1
    fi
    echo "Signing smoke test passed (run ${run_id})."
    exit 0
  fi
  echo "Signing smoke test FAILED (run ${run_id}). Review above."
  [[ "$rc" -eq 2 ]] && exit 2
  exit 1
}

# Deletes the smoke document from the archive ps-server writes to
# (ARCHIVE_API_BASE_URL). The call runs inside the ps-server container, like
# ps-server's own archive calls: a hardened host restricts /archive/api at
# nginx to the Docker subnet plus Basic auth (documentation/22), which this
# script has no credential for, by design. The archive's
# DELETE /api/document/{id} needs no credential of its own on the pinned
# image; if it refuses, the leftover is reported, not hidden.
archive_delete() {
  local del_js out status
  del_js='
let c=null;
for (const p of ["/usr/src/app/config.js", require("path").join(process.cwd(),"config.js")]) { try { c=require(p); break; } catch (e) {} }
if (!c||!c.ARCHIVE_API_BASE_URL) { console.log("error=ARCHIVE_API_BASE_URL not readable"); process.exit(0); }
const u=c.ARCHIVE_API_BASE_URL.replace(/\/?$/,"/")+"document/"+encodeURIComponent(process.env.SMOKE_DOCID);
const go=m=>fetch(u+(m==="GET"?"/download":""),{method:m}).then(r=>r.status);
go("DELETE").then(async d=>{ console.log("delete="+d); console.log("after="+await go("GET")); }).catch(e=>console.log("error="+e.message));
'
  local -a tls_env=()
  [[ "${insecure_tls:-false}" == true ]] && tls_env=(-e NODE_TLS_REJECT_UNAUTHORIZED=0)
  out="$(ps_server_node "${tls_env[@]}" -e "SMOKE_DOCID=${docid}" "$del_js" 2>/dev/null || echo "error=docker compose exec into ps-server failed")"
  status="$(sed -n 's/^delete=//p' <<<"$out")"
  if grep -q '^error=' <<<"$out"; then
    warn "archive document ${docid} not deleted: $(sed -n 's/^error=//p' <<<"$out")"
    return 1
  elif [[ "$status" =~ ^2 && "$(sed -n 's/^after=//p' <<<"$out")" != 200 ]]; then
    ok "archive document ${docid} deleted (DELETE -> ${status}; download now -> $(sed -n 's/^after=//p' <<<"$out"))"
  else
    warn "archive document ${docid} not deleted (DELETE -> ${status:-?}, download after -> $(sed -n 's/^after=//p' <<<"$out")). It is a labelled synthetic document with no customer data."
    return 1
  fi
}

# ── run ──────────────────────────────────────────────────────────────────────

echo "PadSign Signing Smoke Test"
echo "================================"
echo "Host:   ${host}"
echo "Run id: ${run_id}"
echo "Seal:   $([[ "$with_seal" == true ]] && echo "YES - the deployment's configured e-seal will be applied (--with-seal)" || echo "no (pass --with-seal to include the e-seal step)")"
echo ""

echo "== 1. Preflight (read-only) =="
if [[ -z "$(docker compose ps -q ps-server 2>/dev/null)" ]]; then
  echo "  FAIL ps-server is not running in this compose project (run from the deployment directory)"
  exit 1
fi
preflight_js='
let c=null;
for (const p of ["/usr/src/app/config.js", require("path").join(process.cwd(),"config.js")]) { try { c=require(p); break; } catch (e) {} }
if (!c) { console.log("error=config.js not readable"); process.exit(0); }
const r=c.DOCUMENT_ROUTING||{}, s=(r.strategies||[]).filter(x=>x&&x.enabled);
console.log("routing_enabled="+!!r.enabled);
console.log("skip_demo="+(r.skipDemo!==false));
console.log("strategies="+s.map(x=>x.type+(x.company?"(company-scoped)":"(global)")).join(","));
console.log("stamp_mode="+(["external","local"].includes(c.STAMP_MODE)?c.STAMP_MODE:"external"));
console.log("privileged_roles="+(Array.isArray(c.PRIVILEGED_API_ROLES)?c.PRIVILEGED_API_ROLES:[]).join(","));
console.log("insecure_tls="+(c.ALLOW_INSECURE_TLS===true||process.env.ALLOW_INSECURE_TLS==="true"));
'
preflight="$(ps_server_node "$preflight_js" 2>/dev/null || echo "error=docker compose exec into ps-server failed")"
if grep -q '^error=' <<<"$preflight"; then
  echo "  FAIL could not read ps-server's config: $(sed -n 's/^error=//p' <<<"$preflight")"
  exit 1
fi
pf() { sed -n "s/^$1=//p" <<<"$preflight"; }
stamp_mode="$(pf stamp_mode)"
privileged_roles="padsign-admin,psapp-integration,$(pf privileged_roles)"
insecure_tls="$(pf insecure_tls)"
ok "ps-server config read: routing enabled=$(pf routing_enabled), skipDemo=$(pf skip_demo), enabled strategies=[$(pf strategies)], STAMP_MODE=${stamp_mode}"
if [[ "$(pf routing_enabled)" == true && "$(pf skip_demo)" != true ]]; then
  warn "skipDemo is false: demo documents WOULD be routed if a routing call ran. This test never makes one (its user entry is dropped before /api/stamp and /api/finalize-signing is never called), and step 9 verifies it."
fi
start_epoch="$(date -u +%s)"
start_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! curl "${curl_opts[@]}" -o "${work}/constants.json" "${base}/portal/constants.json" 2>"${work}/curl.err"; then
  echo "  FAIL cannot reach ${base} over verified TLS: $(tr -d '\r' < "${work}/curl.err" | tail -1)"
  [[ -z "$cacert" ]] && echo "       (test stack with a private CA? pass --cacert)"
  exit 1
fi
ok "${base} reachable over verified TLS"
echo ""

trap cleanup EXIT
trap 'exit 1' INT TERM

echo "== 2. Temporary Keycloak client and smoke identity =="
kc_wait_ready >/dev/null || { bad "Keycloak is not ready"; exit 1; }
if ! kc_login "${admin_user}" "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null 2>"${work}/kc.err"; then
  bad "Keycloak admin login as '${admin_user}' failed"
  exit 1
fi
kc_logged_in=true

# Device grant ONLY: no standard/implicit/direct-access grants, so this client
# can never accept a password. Short-lived codes and tokens.
kc_step "creating the temporary client" "/opt/keycloak/bin/kcadm.sh create clients -r ${realm} \
  -s clientId=${smoke_client} -s name='PadSign signing smoke test (temporary)' \
  -s 'description=Created by signing-smoke.sh run ${run_id}; deleted at the end of the run' \
  -s enabled=true -s publicClient=true -s consentRequired=false \
  -s standardFlowEnabled=false -s implicitFlowEnabled=false \
  -s directAccessGrantsEnabled=false -s serviceAccountsEnabled=false \
  -s 'attributes.\"oauth2.device.authorization.grant.enabled\"=true' \
  -s 'attributes.\"oauth2.device.code.lifespan\"=${approve_timeout}' \
  -s 'attributes.\"oauth2.device.polling.interval\"=5' \
  -s 'attributes.\"access.token.lifespan\"=300'"
client_created=true
client_uuid="$(kc_client_uuid "$realm" "$smoke_client")"
[[ -n "$client_uuid" ]] || { bad "created client ${smoke_client} but could not look it up"; exit 1; }
kc_backend_audience_create "$realm" "$client_uuid" "padsign-backend" 2>"${work}/kc.err" \
  || { bad "adding the padsign-backend audience mapper failed: $(tail -1 "${work}/kc.err")"; exit 1; }
ok "temporary client ${smoke_client} (device grant only, 5-minute tokens, padsign-backend audience)"

if [[ -n "$existing_user" ]]; then
  uid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${existing_user} -q exact=true --fields id --format csv")"
  if [[ -z "$uid" || "$uid" == "id" ]]; then
    bad "user '${existing_user}' does not exist in realm '${realm}'"
    exit 1
  fi
  smoke_user="$existing_user"
  ok "using existing smoke user ${smoke_user}"
else
  if ! kc_role_exists "$realm" "$smoke_role"; then
    kc_step "creating realm role ${smoke_role}" "/opt/keycloak/bin/kcadm.sh create roles -r ${realm} -s name=${smoke_role} -s 'description=Signing smoke test identity (signing-smoke.sh). Grants nothing by itself.'"
    role_created=true
    ok "realm role ${smoke_role} created for this run"
  else
    ok "realm role ${smoke_role} already exists"
  fi
  echo "  Creating a disposable smoke user (smoke-user.sh; its password is shown on your terminal only):"
  "${scripts_dir}/smoke-user.sh" create --host "$host" --realm "$realm" --admin-user "$admin_user" --company-role "$smoke_role" \
    > "${work}/smoke-user.out" 2> >(grep -vE '^WARNING: Using default admin|^ Container |^Logging into |^Created new ' >&2) || true
  sed 's/^/    /' "${work}/smoke-user.out"
  smoke_user="$(sed -n 's/^  Username: *//p' "${work}/smoke-user.out" | tr -d '\r')"
  if [[ -z "$smoke_user" ]]; then
    bad "smoke-user.sh create did not report a username"
    exit 1
  fi
  user_created=true
  # smoke-user.sh logged the shared kcadm session out on exit.
  kc_relogin || { bad "Keycloak admin re-login failed"; exit 1; }
fi
echo ""

echo "== 3. Operator approval (OAuth device authorization) =="
device_code_file="${work}/device.json"
if ! curl "${curl_opts[@]}" -o "$device_code_file" \
     --data-urlencode "client_id=${smoke_client}" --data-urlencode "scope=openid" \
     "${base}/auth/realms/${realm}/protocol/openid-connect/auth/device" 2>"${work}/curl.err"; then
  bad "device authorization request failed: $(tail -1 "${work}/curl.err")"
  exit 1
fi
user_code="$(json_field "$device_code_file" user_code)"
verify_uri="$(json_field "$device_code_file" verification_uri)"
verify_uri_complete="$(json_field "$device_code_file" verification_uri_complete)"
interval="$(json_field "$device_code_file" interval)"; [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
if [[ -z "$user_code" ]]; then
  bad "Keycloak did not return a device code: $(head -c 300 "$device_code_file")"
  exit 1
fi
# device_code goes to curl from a file, never as an argument.
python3 - "$device_code_file" "${work}/device_code.form" "$smoke_client" <<'PY'
import json, sys, urllib.parse
d = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w").write(urllib.parse.urlencode({
    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
    "device_code": d["device_code"], "client_id": sys.argv[3]}))
PY
cat <<EOF

  In a PRIVATE browser window, open:

      ${verify_uri_complete:-$verify_uri}

  confirm the code ${user_code}, and log in as:  ${smoke_user}
  (the password shown on your terminal when that user was created).
  Waiting up to ${approve_timeout}s ...

EOF
deadline=$(( $(date +%s) + approve_timeout ))
token_file="${work}/token.json"
while :; do
  code="$(curl "${curl_opts[@]}" -o "$token_file" -w '%{http_code}' --data @"${work}/device_code.form" \
          "${base}/auth/realms/${realm}/protocol/openid-connect/token" 2>/dev/null || true)"
  [[ "$code" == "200" ]] && break
  err="$(json_field "$token_file" error)"
  case "$err" in
    authorization_pending) ;;
    slow_down) interval=$(( interval + 5 )) ;;
    *) bad "device approval failed: ${err:-HTTP ${code}}"; exit 1 ;;
  esac
  if (( $(date +%s) >= deadline )); then
    bad "no approval within ${approve_timeout}s"
    exit 1
  fi
  sleep "$interval"
done
# Keep only the access token (as a curl header file); drop the refresh and ID
# tokens straight away. Print claims, never the token.
claims="$(python3 - "$token_file" "$auth_hdr" <<'PY'
import base64, json, sys
t = json.load(open(sys.argv[1], encoding="utf-8"))["access_token"]
with open(sys.argv[2], "w") as f:
    f.write("Authorization: Bearer " + t + "\n")
p = t.split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
roles = list(c.get("realm_access", {}).get("roles", []))
for v in (c.get("resource_access") or {}).values():
    roles += v.get("roles", [])
aud = c.get("aud") or []
aud = [aud] if isinstance(aud, str) else aud
print("username=" + str(c.get("preferred_username", "")))
print("email=" + str(c.get("email", "")))
print("roles=" + ",".join(roles))
print("aud=" + ",".join(aud))
print("exp_in=" + str(int(c.get("exp", 0)) - int(c.get("iat", 0))))
PY
)"
rm -f "$token_file" "${work}/device_code.form" "$device_code_file"
cl() { sed -n "s/^$1=//p" <<<"$claims"; }
ok "approved; access token received (valid $(cl exp_in)s, held in a mode-600 file only)"
echo ""

echo "== 4. Identity guard (before any API call) =="
token_user="$(cl username)"
if [[ "$token_user" != "$smoke_user" ]]; then
  bad "the browser approval was made as '${token_user}', not the smoke user '${smoke_user}' - stopping before any API call"
  exit 1
fi
ok "token belongs to ${token_user}"
priv_hit=""
IFS=',' read -r -a _roles <<<"$(cl roles)"
IFS=',' read -r -a _priv <<<"$privileged_roles"
for r in "${_roles[@]}"; do
  for p in "${_priv[@]}"; do [[ -n "$p" && "$r" == "$p" ]] && priv_hit+="${r} "; done
done
if [[ -n "$priv_hit" ]]; then
  bad "the smoke user holds privileged role(s): ${priv_hit}- stopping"
  exit 1
fi
ok "no privileged roles (roles: $(cl roles))"
if [[ ",$(cl aud)," != *",padsign-backend,"* ]]; then
  bad "token audience lacks padsign-backend (aud=$(cl aud)); ps-server introspection would reject it"
  exit 1
fi
ok "token audience includes padsign-backend"
[[ -n "$(cl email)" ]] || { bad "token has no email claim (required by /api/demo/upload)"; exit 1; }
echo ""

echo "== 5. Authenticated API access =="
code="$(api GET /api/health "${work}/health.json")"
if [[ "$code" == "200" ]]; then
  ok "GET /api/health with the smoke user's token -> 200"
else
  bad "GET /api/health with a valid token -> ${code} (expected 200)"
  exit 1
fi
echo ""

echo "== 6. Upload a synthetic document (demo path) =="
python3 - "${work}/smoke.pdf" "${work}/signature.png" "$marker" <<'PY'
import struct, sys, zlib
pdf_path, png_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]
lines = ["PADSIGN SMOKE TEST - NOT A REAL DOCUMENT", marker,
         "Generated by installation-scripts/signing-smoke.sh.",
         "Contains no customer data. Safe to delete."]
text = "BT /F1 16 Tf 72 770 Td 22 TL " + " ".join("(%s) '" % l for l in lines) + " ET"
stream = text.encode("latin-1")
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ("<< /Title (%s) /Producer (padsign signing-smoke.sh) >>" % marker).encode("latin-1"),
]
out = bytearray(b"%PDF-1.7\n")
offsets = []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offsets:
    out += b"%010d 00000 n \n" % off
out += b"trailer\n<< /Size %d /Root 1 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, len(objs), xref)
open(pdf_path, "wb").write(out)

# Signature image: a transparent 300x100 RGBA PNG with a dark stroke.
w, h = 300, 100
rows = []
for y in range(h):
    row = bytearray(b"\x00")
    for x in range(w):
        on = abs((y - 50) - int(30 * __import__("math").sin(x / 25.0))) < 3 and 20 < x < 280
        row += b"\x10\x10\x40\xff" if on else b"\x00\x00\x00\x00"
    rows.append(bytes(row))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
open(png_path, "wb").write(png)
PY
code="$(api POST /api/demo/upload "${work}/upload.json" \
        -F "file=@${work}/smoke.pdf;type=application/pdf;filename=padsign-smoke-${run_id}.pdf" \
        -F "clientName=PadSign smoke test ${run_id}")"
docid="$(json_field "${work}/upload.json" docId)"
if [[ "$code" == "201" && -n "$docid" && "$(json_field "${work}/upload.json" demo)" == "true" ]]; then
  ok "POST /api/demo/upload -> 201, docId ${docid}, demo=true"
else
  bad "POST /api/demo/upload -> ${code}: $(head -c 300 "${work}/upload.json" 2>/dev/null)"
  exit 1
fi
echo ""

echo "== 7. Visual signature =="
python3 - "${work}/constants.json" "${work}/signature.png" "$docid" "$run_id" "${work}/sign.json" <<'PY'
import base64, json, sys
try:
    c = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    c = {}
def num(k, d):
    v = c.get(k, d)
    return v if isinstance(v, (int, float)) else d
body = {
    "docid": sys.argv[3],
    "pdfSignatureIsVisible": True,
    "signatureProfile": "B",
    "signatureContactInfo": "PadSign smoke test",
    "pdfSignatureVisuals": {
        "signatureText": "PadSign smoke test %s\nDate: {date}" % sys.argv[4],
        "signatureImage": base64.b64encode(open(sys.argv[2], "rb").read()).decode(),
        "signatureXAxis": num("PDF_SIGNATURE_X", -250),
        "signatureYAxis": num("PDF_SIGNATURE_Y", -100),
        "signatureZoom": num("PDF_SIGNATURE_ZOOM", 100),
        "signaturePage": num("PDF_SIGNATURE_PAGE", 10000),
    },
}
json.dump(body, open(sys.argv[5], "w"))
PY
code="$(api PUT /api/visual-signature "${work}/sign.out" -H 'Content-Type: application/json' --data-binary @"${work}/sign.json")"
if [[ "$code" =~ ^2 ]]; then
  ok "PUT /api/visual-signature -> ${code}"
else
  bad "PUT /api/visual-signature -> ${code}: $(head -c 300 "${work}/sign.out" 2>/dev/null)"
  exit 1
fi

# Drop the in-memory user entry BEFORE anything that can route: /api/stamp
# routes only for a document that still has one, and /api/finalize-signing
# (never called here) 404s without one.
code="$(api GET "/api/cleanupUser?doc=${docid}" "${work}/drop.json")"
if [[ "$code" == "200" && "$(json_field "${work}/drop.json" removedCount)" -ge 1 ]] 2>/dev/null; then
  user_entry_dropped=true
  ok "user entry dropped before sealing/finalizing (removedCount=$(json_field "${work}/drop.json" removedCount)) - ps-server can no longer route this document"
else
  bad "could not drop the user entry (HTTP ${code}: $(head -c 200 "${work}/drop.json" 2>/dev/null)) - stopping before any routing-capable call"
  exit 1
fi
echo ""

echo "== 8. E-seal (opt-in) =="
if [[ "$with_seal" == true ]]; then
  code="$(api POST /api/stamp "${work}/stamp.json" -H 'Content-Type: application/json' --data-binary "{\"docid\":\"${docid}\"}")"
  if [[ "$code" == "200" && "$(json_field "${work}/stamp.json" stampStatus)" != "skipped" ]]; then
    ok "POST /api/stamp -> 200, sealed with the deployment's STAMP_MODE=${stamp_mode} seal"
  else
    bad "POST /api/stamp -> ${code} $(head -c 300 "${work}/stamp.json" 2>/dev/null)"
  fi
else
  skip "e-seal not applied (default: never seal a test document with the production seal; opt in with --with-seal)"
fi
echo ""

echo "== 9. Download and verify the signed document =="
# With the user's token, as the pad does: a hardened host only lets the
# download route through with it (documentation/22).
dl_code="$(api GET "/archive/api/document/${docid}/download" "${work}/signed.pdf")"
if [[ "$dl_code" != "200" ]]; then
  bad "GET /archive/api/document/${docid}/download -> ${dl_code}"
else
  min_sigs=1; [[ "$with_seal" == true ]] && min_sigs=2
  if verify_out="$(python3 - "${work}/smoke.pdf" "${work}/signed.pdf" "$marker" "$min_sigs" <<'PY'
import hashlib, sys
orig, signed = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
marker, min_sigs = sys.argv[3].encode(), int(sys.argv[4])
problems = []
if not signed.startswith(b"%PDF-"):
    problems.append("not a PDF")
if hashlib.sha256(orig).digest() == hashlib.sha256(signed).digest():
    problems.append("identical to the unsigned input")
if marker not in signed:
    problems.append("run id %s not found (wrong document?)" % sys.argv[3])
sigs = signed.count(b"/ByteRange")
if sigs < min_sigs:
    problems.append("%d signature dictionar%s (/ByteRange), expected >= %d" % (sigs, "y" if sigs == 1 else "ies", min_sigs))
print("%d bytes, %d signature dictionar%s, run id present=%s" % (len(signed), sigs, "y" if sigs == 1 else "ies", marker in signed))
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
)"; then
    ok "signed PDF: $(head -1 <<<"$verify_out")"
  else
    bad "signed PDF check failed: $(tr '\n' ' ' <<<"$verify_out")"
  fi
fi
echo ""

echo "== 10. Nothing reached routing destinations, webhooks or the buffer =="
scan_js='
const fs=require("fs"),path=require("path");
let c=null;
for (const p of ["/usr/src/app/config.js", path.join(process.cwd(),"config.js")]) { try { c=require(p); break; } catch (e) {} }
if (!c) { console.log("error=config.js not readable"); process.exit(0); }
const since=Number(process.env.SMOKE_SINCE)*1000-2000, needles=process.env.SMOKE_NEEDLES.split(",");
const roots=[];
for (const s of ((c.DOCUMENT_ROUTING||{}).strategies||[])) {
  if (!s||!s.enabled||s.type!=="filesystem"||!s.basePath) continue;
  for (const r of [s.basePath, s.bufferPath]) if (r && !roots.includes(r)) roots.push(r);
}
let changed=0; const hits=[]; const stack=roots.filter(r=>fs.existsSync(r));
while (stack.length) {
  const d=stack.pop(); let ents;
  try { ents=fs.readdirSync(d,{withFileTypes:true}); } catch (e) { continue; }
  for (const e of ents) {
    const f=path.join(d,e.name);
    if (e.name.includes(needles[0])) hits.push(f);
    if (e.isDirectory()) { stack.push(f); continue; }
    let st; try { st=fs.statSync(f); } catch (e) { continue; }
    if (st.mtimeMs<since) continue;
    changed++;
    try { const b=fs.readFileSync(f); if (needles.some(n=>b.includes(n))) hits.push(f); } catch (e) {}
  }
}
console.log("roots="+roots.join(","));
console.log("changed="+changed);
console.log("hits="+[...new Set(hits)].join(","));
'
scan="$(ps_server_node -e "SMOKE_SINCE=${start_epoch}" -e "SMOKE_NEEDLES=${docid},${marker}" "$scan_js" 2>/dev/null || echo "error=docker compose exec into ps-server failed")"
sc() { sed -n "s/^$1=//p" <<<"$scan"; }
if grep -q '^error=' <<<"$scan"; then
  bad "could not scan routing destinations: $(sc error)"
elif [[ -z "$(sc roots)" ]]; then
  ok "no enabled filesystem strategy (no routing folder, no receive-back buffer to check)"
elif [[ -n "$(sc hits)" ]]; then
  bad "the smoke document reached a routing destination or the buffer: $(sc hits)"
else
  ok "routing folders and receive-back buffer ($(sc roots)): no file names or contains ${docid} / the run id ($(sc changed) file(s) changed during the run, from other traffic)"
fi
# ps-server logs routing events as multi-line objects ("[documentRouting:
# webhook] delivered {" with the docid a few lines down), so match per block:
# a tagged line plus the lines that follow it up to the closing brace.
routing_lines="$(docker compose logs --no-color --no-log-prefix --since "$start_iso" ps-server 2>/dev/null \
  | python3 -c '
import sys
docid, block, hits = sys.argv[1], [], []
def flush():
    if block and any(docid in l for l in block):
        hits.append(" / ".join(l.strip() for l in block)[:300])
for line in sys.stdin:
    if "[documentRouting" in line or "[signedPdfBuffer" in line:
        flush(); block = [line]
    elif block:
        block.append(line)
        if line.startswith("}") or len(block) > 20:
            flush(); block = []
flush()
print("\n".join(hits[:5]))
' "$docid" || true)"
if [[ -n "$routing_lines" ]]; then
  bad "ps-server logged routing activity for ${docid}:"
  sed 's/^/         /' <<<"$routing_lines"
else
  ok "no documentRouting / buffer log entry for ${docid} (so no webhook was called for it)"
fi
