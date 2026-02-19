#!/usr/bin/env bash
set -euo pipefail

realm="padsign"
host="${KC_HOSTNAME:-}"
company_role=""
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
users_csv="" # format: username:password[:role],username2:password2[:role]

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/keycloak-bootstrap.sh --host example.com --company-role "Acme"
                                 [--realm padsign]
                                 [--admin-user admin] [--admin-pass secret]
                                 [--users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!:psapp-integration"]

What it does (idempotent):
  - starts keycloak via docker compose
  - creates realm
  - creates roles: padsign-admin, psapp-integration, <company-role>
  - creates a test user:
    - username: test
    - password: <company-role lowercased>
    - realm roles: only <company-role>
  - creates/updates clients: padsign-client (public) and padsign-backend (confidential bearer-only)
  - sets client "name" fields (same as client IDs)
  - optionally creates users and assigns a realm role (if provided per user)
  - prints backend client secret
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
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "Missing --host (or set KC_HOSTNAME)." >&2
  exit 2
fi
if [[ -z "$company_role" ]]; then
  echo "Missing --company-role (company name role to create in Keycloak)." >&2
  exit 2
fi

portal_base="https://${host}/portal"
post_logout_uris="${portal_base}/*##${portal_base}/##${portal_base}"

echo "Bootstrapping Keycloak realm '${realm}' for host '${host}'..."

docker compose up -d keycloak >/dev/null

ready_url="http://localhost:8080/"
for i in $(seq 1 120); do
  if curl -fsS --max-time 3 "$ready_url" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ "$i" == "120" ]]; then
    echo "Keycloak did not become ready at ${ready_url} within 120s" >&2
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

# Recreate 'test' user to ensure it has the company role.
test_user="test"
test_pass="$(printf '%s' "${company_role}" | tr '[:upper:]' '[:lower:]')"
kc_exec "
  TEST_UID=\$(/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${test_user} --fields id --format csv | tail -n 1 | tr -d '\r\"')
  if [ -n \"\$TEST_UID\" ] && [ \"\$TEST_UID\" != \"id\" ]; then
    /opt/keycloak/bin/kcadm.sh delete users/\$TEST_UID -r ${realm} >/dev/null
  fi
  /opt/keycloak/bin/kcadm.sh create users -r ${realm} -s username=${test_user} -s enabled=true >/dev/null
  TEST_UID=\$(/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${test_user} --fields id --format csv | tail -n 1 | tr -d '\r\"')
  /opt/keycloak/bin/kcadm.sh set-password -r ${realm} --userid \$TEST_UID --new-password '${test_pass}' --temporary=false >/dev/null
  /opt/keycloak/bin/kcadm.sh add-roles -r ${realm} --uusername ${test_user} --rolename '${company_role}' >/dev/null
" >/dev/null

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

if [[ -n "$users_csv" ]]; then
  IFS=',' read -r -a users <<<"$users_csv"
  for entry in "${users[@]}"; do
    IFS=':' read -r username password role <<<"$entry"
    if [[ -z "${username:-}" || -z "${password:-}" ]]; then
      echo "Invalid --users entry: ${entry}" >&2
      exit 2
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
  done
fi

cat <<EOF

Keycloak bootstrap complete.
- KEYCLOAK_URL: https://${host}/auth
- KEYCLOAK_REALM: ${realm}
- KEYCLOAK_CLIENT_ID (frontend): ${client_frontend}
- Backend clientId: ${client_backend}
- Backend client secret: ${backend_secret}
BACKEND_CLIENT_SECRET=${backend_secret}
EOF
