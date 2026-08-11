#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Keycloak Bootstrap — idempotent realm/client/role/user creation
# ============================================================================

realm="padsign"
host="${KC_HOSTNAME:-}"
company_role=""
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
users_csv=""
skip_test_user="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/keycloak-bootstrap.sh --host example.com --company-role "Acme"
                                 [--realm padsign]
                                 [--admin-user admin] [--admin-pass secret]
                                 [--users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!"]
                                 [--skip-test-user]

What it does (idempotent):
  - starts keycloak via docker compose
  - creates realm, roles, clients, test user (unless --skip-test-user)
  - prints backend client secret (captured by bootstrap.sh)

--skip-test-user: don't touch the demo 'test' account at all. Used by
  update-hostname.sh (deployment-wizard Settings feature) when re-running
  this script against an ALREADY-LIVE deployment just to sync the Keycloak
  client's redirect URIs for a new hostname — without this flag, every such
  run would silently delete+recreate the demo 'test' user with a fresh
  random password, which is fine on a first bootstrap but a surprising
  side effect on a live stack.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --users) users_csv="${2:-}"; shift 2;;
    --skip-test-user) skip_test_user="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host (or set KC_HOSTNAME)." >&2
  exit 2
fi
if [[ -z "$company_role" ]]; then
  echo "ERROR: Missing --company-role." >&2
  exit 2
fi

portal_base="https://${host}/portal"
post_logout_uris="${portal_base}/*##${portal_base}/##${portal_base}"

echo "Bootstrapping Keycloak realm '${realm}' for host '${host}'..."

docker compose up -d keycloak >/dev/null

kc_exec() {
  docker compose exec -T keycloak sh -lc "$*"
}

# Wait for Keycloak readiness via a TCP check run INSIDE the keycloak
# container itself (docker compose exec), not a curl from wherever this
# script happens to execute. This script runs both directly on a bare host
# (traditional CLI use) and inside the deployment-wizard container (which
# talks to keycloak only as a sibling container via the mounted Docker
# socket) — "localhost:8080" only resolves to the right place in the first
# case. `docker compose exec` always reaches the correct container via the
# Docker API regardless of the caller's own network namespace, matching how
# kc_exec() below already works. The keycloak image ships bash (no curl/wget),
# so /dev/tcp is the check, not an HTTP request — found via a real E2E test
# where the wizard ran as an actual container for the first time.
echo "  Waiting for Keycloak to become ready..."
for i in $(seq 1 120); do
  if kc_exec "bash -c 'echo > /dev/tcp/localhost/8080'" >/dev/null 2>&1; then
    echo "  Keycloak ready (${i}s)"
    break
  fi
  sleep 1
  if [[ "$i" == "120" ]]; then
    echo "ERROR: Keycloak did not become ready within 120s" >&2
    exit 1
  fi
done

kc_csv_last() {
  local cmd="$1"
  kc_exec "$cmd" | tail -n 1 | tr -d '\r"'
}

kc_exec "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user '${admin_user}' --password '${admin_pass}'" >/dev/null

kc_exec "/opt/keycloak/bin/kcadm.sh get realms/${realm} >/dev/null 2>&1 || /opt/keycloak/bin/kcadm.sh create realms -s realm=${realm} -s enabled=true" >/dev/null

ensure_role() {
  local name="$1"
  # ${name} is single-quoted inside the nested `sh -lc "..."` string (kc_exec)
  # so a multi-word company/role name (e.g. "Acme Corp") survives as one
  # token instead of word-splitting into a bogus extra kcadm argument.
  #
  # Existence check is a full-list-plus-exact-match, NOT `kcadm get
  # roles/<name>` (a raw URL path segment) — kcadm/Keycloak reject a literal
  # space there ("Illegal character in path"), so a multi-word name always
  # fell through to `create`, which then failed on a duplicate-name conflict
  # for any role that already existed. Found via a live E2E test of the
  # Settings feature's update-hostname.sh re-running this script against an
  # already-bootstrapped realm. `-q name=` isn't a supported server-side
  # filter on the roles endpoint (it silently returns everything), so the
  # exact match happens client-side via `grep -qxF` instead.
  kc_exec "/opt/keycloak/bin/kcadm.sh get roles -r ${realm} --fields name --format csv | tr -d '\r\"' | grep -qxF '${name}' || /opt/keycloak/bin/kcadm.sh create roles -r ${realm} -s name='${name}'" >/dev/null
}

ensure_role "padsign-admin"
ensure_role "psapp-integration"
ensure_role "${company_role}"

# Generate random test password (12 chars alphanumeric)
test_user="test"
test_pass=""
test_email=""
if [[ "$skip_test_user" != "true" ]]; then
  test_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)"
  test_email="test@$(printf '%s' "${company_role}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-').padsign"

  # Recreate test user to ensure correct role assignment
  kc_exec "
    TEST_UID=\$(/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${test_user} --fields id --format csv | tail -n 1 | tr -d '\r\"')
    if [ -n \"\$TEST_UID\" ] && [ \"\$TEST_UID\" != \"id\" ]; then
      /opt/keycloak/bin/kcadm.sh delete users/\$TEST_UID -r ${realm} >/dev/null
    fi
    /opt/keycloak/bin/kcadm.sh create users -r ${realm} -s username=${test_user} -s enabled=true -s email='${test_email}' >/dev/null
    TEST_UID=\$(/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${test_user} --fields id --format csv | tail -n 1 | tr -d '\r\"')
    /opt/keycloak/bin/kcadm.sh set-password -r ${realm} --userid \$TEST_UID --new-password '${test_pass}' --temporary=false >/dev/null
    /opt/keycloak/bin/kcadm.sh add-roles -r ${realm} --uusername ${test_user} --rolename '${company_role}' >/dev/null
  " >/dev/null
fi

# --- Frontend client ---
client_frontend="padsign-client"
redirect_uris="[\"${portal_base}/*\",\"${portal_base}/\",\"${portal_base}\"]"
web_origins="[\"${portal_base}/\",\"${portal_base}\"]"

frontend_cid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get clients -r ${realm} -q clientId=${client_frontend} --fields id --format csv")"
if [[ -z "${frontend_cid}" || "${frontend_cid}" == "id" ]]; then
  kc_exec "
    /opt/keycloak/bin/kcadm.sh create clients -r ${realm} \
      -s clientId=${client_frontend} \
      -s name=${client_frontend} \
      -s enabled=true \
      -s publicClient=true \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=false \
      -s implicitFlowEnabled=false \
      -s 'redirectUris=${redirect_uris}' \
      -s 'webOrigins=${web_origins}' \
      -s rootUrl=${portal_base}/ \
      -s baseUrl=${portal_base}/ \
      -s adminUrl=${portal_base}/ \
      -s \"attributes.\\\"post.logout.redirect.uris\\\"=${post_logout_uris}\" >/dev/null
  " >/dev/null
  frontend_cid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get clients -r ${realm} -q clientId=${client_frontend} --fields id --format csv")"
fi

kc_exec "
  /opt/keycloak/bin/kcadm.sh update clients/${frontend_cid} -r ${realm} \
    -s name=${client_frontend} \
    -s 'redirectUris=${redirect_uris}' \
    -s 'webOrigins=${web_origins}' \
    -s rootUrl=${portal_base}/ \
    -s baseUrl=${portal_base}/ \
    -s adminUrl=${portal_base}/ \
    -s \"attributes.\\\"post.logout.redirect.uris\\\"=${post_logout_uris}\" >/dev/null
" >/dev/null

# --- Backend client ---
client_backend="padsign-backend"
backend_cid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get clients -r ${realm} -q clientId=${client_backend} --fields id --format csv")"
if [[ -z "${backend_cid}" || "${backend_cid}" == "id" ]]; then
  kc_exec "
    /opt/keycloak/bin/kcadm.sh create clients -r ${realm} \
      -s clientId=${client_backend} \
      -s name=${client_backend} \
      -s enabled=true \
      -s publicClient=false \
      -s bearerOnly=false \
      -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false >/dev/null
  " >/dev/null
  backend_cid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get clients -r ${realm} -q clientId=${client_backend} --fields id --format csv")"
fi

kc_exec "/opt/keycloak/bin/kcadm.sh update clients/${backend_cid} -r ${realm} -s name=${client_backend}" >/dev/null
backend_secret="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get clients/${backend_cid}/client-secret -r ${realm} --fields value --format csv")"

# --- Additional users (IFS-safe parsing) ---
if [[ -n "$users_csv" ]]; then
  while IFS=',' read -r -d '' entry || [[ -n "$entry" ]]; do
    entry="$(echo "$entry" | tr -d '[:space:]')"
    [[ -z "$entry" ]] && continue
    IFS=':' read -r username password role <<< "$entry"
    if [[ -z "${username:-}" || -z "${password:-}" ]]; then
      echo "WARNING: Invalid --users entry: ${entry}" >&2
      continue
    fi

    kc_exec "
      /opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${username} --fields id,username | grep -q '\"id\"' || \
      /opt/keycloak/bin/kcadm.sh create users -r ${realm} -s username=${username} -s enabled=true >/dev/null
    " >/dev/null

    uid="$(
      kc_exec "/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${username} --fields id --format csv | tail -n 1" | tr -d '\r"'
    )"

    kc_exec "/opt/keycloak/bin/kcadm.sh set-password -r ${realm} --userid ${uid} --new-password '${password}' --temporary=false" >/dev/null
    if [[ -n "${role:-}" ]]; then
      ensure_role "${role}"
      kc_exec "/opt/keycloak/bin/kcadm.sh add-roles -r ${realm} --uusername ${username} --rolename ${role}" >/dev/null
    fi
  done <<< "$(printf '%s' "$users_csv" | tr ',' '\0')"
fi

echo
echo "Keycloak bootstrap complete."
echo "  Realm:            ${realm}"
echo "  Frontend client:  ${client_frontend}"
echo "  Backend client:   ${client_backend}"
if [[ "$skip_test_user" == "true" ]]; then
  echo "  Test user:        (--skip-test-user: left untouched)"
else
  echo "  Test user:        ${test_user} / ${test_pass} (email: ${test_email})"
  echo
  echo "  WARNING: Delete 'test' user before production use!"
fi
echo
echo "BACKEND_CLIENT_SECRET=${backend_secret}"
