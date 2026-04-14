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

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/keycloak-bootstrap.sh --host example.com --company-role "Acme"
                                 [--realm padsign]
                                 [--admin-user admin] [--admin-pass secret]
                                 [--users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!"]

What it does (idempotent):
  - starts keycloak via docker compose
  - creates realm, roles, clients, test user
  - prints backend client secret (captured by bootstrap.sh)
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

# Wait for Keycloak readiness (use health endpoint, consistent with PowerShell version)
ready_url="http://localhost:8080/auth/health/ready"
echo "  Waiting for Keycloak at ${ready_url}..."
for i in $(seq 1 120); do
  if curl -fsS --max-time 3 "$ready_url" >/dev/null 2>&1; then
    echo "  Keycloak ready (${i}s)"
    break
  fi
  # Fallback: also try root URL for older Keycloak versions
  if curl -fsS --max-time 3 "http://localhost:8080/" >/dev/null 2>&1; then
    echo "  Keycloak ready via root (${i}s)"
    break
  fi
  sleep 1
  if [[ "$i" == "120" ]]; then
    echo "ERROR: Keycloak did not become ready within 120s" >&2
    exit 1
  fi
done

kc_exec() {
  docker compose exec -T keycloak sh -lc "$*"
}

kc_csv_last() {
  local cmd="$1"
  kc_exec "$cmd" | tail -n 1 | tr -d '\r"'
}

kc_exec "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user '${admin_user}' --password '${admin_pass}'" >/dev/null

kc_exec "/opt/keycloak/bin/kcadm.sh get realms/${realm} >/dev/null 2>&1 || /opt/keycloak/bin/kcadm.sh create realms -s realm=${realm} -s enabled=true" >/dev/null

ensure_role() {
  local name="$1"
  kc_exec "/opt/keycloak/bin/kcadm.sh get roles/${name} -r ${realm} >/dev/null 2>&1 || /opt/keycloak/bin/kcadm.sh create roles -r ${realm} -s name=${name}" >/dev/null
}

ensure_role "padsign-admin"
ensure_role "psapp-integration"
ensure_role "${company_role}"

# Generate random test password (12 chars alphanumeric)
test_user="test"
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

cat <<EOF

Keycloak bootstrap complete.
  Realm:            ${realm}
  Frontend client:  ${client_frontend}
  Backend client:   ${client_backend}
  Test user:        ${test_user} / ${test_pass} (email: ${test_email})

  WARNING: Delete 'test' user before production use!

BACKEND_CLIENT_SECRET=${backend_secret}
EOF
