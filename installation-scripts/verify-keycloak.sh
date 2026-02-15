#!/usr/bin/env bash
set -euo pipefail

realm="padsign"
host="${KC_HOSTNAME:-}"
company_role=""
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/verify-keycloak.sh --host example.com --company-role "Acme"
                                           [--realm padsign]
                                           [--admin-user admin] [--admin-pass secret]

Verifies (fails non-zero on mismatch):
  - realm exists
  - padsign-client settings (Root/Home/Admin URL, redirect URIs, post-logout URIs, web origins)
  - padsign-backend settings (confidential + service accounts enabled)
  - test user exists and has ONLY the company role
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "Missing --host (or set KC_HOSTNAME)." >&2
  exit 2
fi
if [[ -z "$company_role" ]]; then
  echo "Missing --company-role." >&2
  exit 2
fi

need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing dependency: ${c}" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd python3
if ! docker compose version >/dev/null 2>&1; then
  echo "Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi

portal_base="https://${host}/portal"
expected_redirects=("${portal_base}/*" "${portal_base}/" "${portal_base}")
expected_web_origins=("${portal_base}/" "${portal_base}")
expected_post_logout=("${portal_base}/*" "${portal_base}/" "${portal_base}")

kc_exec() {
  docker compose exec -T keycloak sh -lc "$*"
}

docker compose up -d keycloak >/dev/null
kc_exec "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user '${admin_user}' --password '${admin_pass}'" >/dev/null

fail=0
ok() { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

if kc_exec "/opt/keycloak/bin/kcadm.sh get realms/${realm} >/dev/null 2>&1"; then
  ok "realm '${realm}' exists"
else
  bad "realm '${realm}' missing"
fi

get_client_json() {
  local client_id="$1"
  local cid
  cid="$(kc_exec "/opt/keycloak/bin/kcadm.sh get clients -r ${realm} -q clientId=${client_id} --fields id --format csv | tail -n 1" | tr -d '\r')"
  if [[ -z "$cid" || "$cid" == "id" ]]; then
    return 1
  fi
  kc_exec "/opt/keycloak/bin/kcadm.sh get clients/${cid} -r ${realm}"
}

client_front="padsign-client"
if front_json="$(get_client_json "$client_front" 2>/dev/null)"; then
  ok "client '${client_front}' exists"

  python3 - "$host" "$realm" "$company_role" <<'PY' || exit_code=$?
import json, sys

host, realm, company_role = sys.argv[1:]
portal_base = f"https://{host}/portal"
expected_redirects = {f"{portal_base}/*", f"{portal_base}/", f"{portal_base}"}
expected_web_origins = {f"{portal_base}/", f"{portal_base}"}
expected_post_logout = {f"{portal_base}/*", f"{portal_base}/", f"{portal_base}"}

data = json.load(sys.stdin)
def req_eq(label, got, exp):
  if got != exp:
    print(f"FAIL {label}: got={got!r} expected={exp!r}")
    return 1
  print(f"OK   {label}")
  return 0

rc = 0
rc |= req_eq("padsign-client rootUrl", data.get("rootUrl"), portal_base + "/")
rc |= req_eq("padsign-client baseUrl", data.get("baseUrl"), portal_base + "/")
rc |= req_eq("padsign-client adminUrl", data.get("adminUrl"), portal_base + "/")

redirects = set(data.get("redirectUris") or [])
if redirects != expected_redirects:
  print(f"FAIL padsign-client redirectUris: got={sorted(redirects)!r} expected={sorted(expected_redirects)!r}")
  rc = 1
else:
  print("OK   padsign-client redirectUris")

origins = set(data.get("webOrigins") or [])
if origins != expected_web_origins:
  print(f"FAIL padsign-client webOrigins: got={sorted(origins)!r} expected={sorted(expected_web_origins)!r}")
  rc = 1
else:
  print("OK   padsign-client webOrigins")

attrs = data.get("attributes") or {}
pl = attrs.get("post.logout.redirect.uris") or ""
parts = {p for p in pl.split("##") if p}
if parts != expected_post_logout:
  print(f"FAIL padsign-client post logout redirect URIs: got={sorted(parts)!r} expected={sorted(expected_post_logout)!r}")
  rc = 1
else:
  print("OK   padsign-client post logout redirect URIs")

sys.exit(0 if rc == 0 else 1)
PY <<<"$front_json"
  if [[ ${exit_code:-0} -ne 0 ]]; then fail=1; fi
else
  bad "client '${client_front}' missing"
fi

client_back="padsign-backend"
unset exit_code
if back_json="$(get_client_json "$client_back" 2>/dev/null)"; then
  ok "client '${client_back}' exists"

  python3 - <<'PY' || exit_code=$?
import json, sys
data = json.load(sys.stdin)
checks = [
  ("padsign-backend publicClient", data.get("publicClient"), False),
  ("padsign-backend bearerOnly", data.get("bearerOnly"), False),
  ("padsign-backend serviceAccountsEnabled", data.get("serviceAccountsEnabled"), True),
  ("padsign-backend standardFlowEnabled", data.get("standardFlowEnabled"), False),
  ("padsign-backend implicitFlowEnabled", data.get("implicitFlowEnabled"), False),
  ("padsign-backend directAccessGrantsEnabled", data.get("directAccessGrantsEnabled"), False),
]
rc = 0
for label, got, exp in checks:
  if got != exp:
    print(f"FAIL {label}: got={got!r} expected={exp!r}")
    rc = 1
  else:
    print(f"OK   {label}")
sys.exit(rc)
PY <<<"$back_json"
  if [[ ${exit_code:-0} -ne 0 ]]; then fail=1; fi
else
  bad "client '${client_back}' missing"
fi

# Verify test user role mapping is ONLY company_role.
unset exit_code
test_uid="$(kc_exec "/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=test --fields id --format csv | tail -n 1" | tr -d '\r')"
if [[ -z "$test_uid" || "$test_uid" == "id" ]]; then
  bad "user 'test' missing"
else
  ok "user 'test' exists"
  roles_json="$(kc_exec "/opt/keycloak/bin/kcadm.sh get users/${test_uid}/role-mappings/realm -r ${realm}")"
  python3 - "$company_role" <<'PY' || exit_code=$?
import json, sys
company_role = sys.argv[1]
data = json.load(sys.stdin)  # list of roles
names = sorted({r.get("name") for r in data if r.get("name")})
if names != [company_role]:
  print(f"FAIL test user realm roles: got={names!r} expected={[company_role]!r}")
  sys.exit(1)
print("OK   test user realm roles (only company role)")
PY <<<"$roles_json"
  if [[ ${exit_code:-0} -ne 0 ]]; then fail=1; fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

