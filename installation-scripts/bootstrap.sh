#!/usr/bin/env bash
set -euo pipefail

host=""
realm="padsign"
company_role=""
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
users_csv=""

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/bootstrap.sh --host example.com --company-role "Acme"
                       [--realm padsign]
                       [--admin-user admin]
                       [--admin-pass secret]
                       [--users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!:psapp-integration"]

One-shot bootstrap for a new server hostname:
  1) Rewrites nginx/nginx.conf + config/constants.json + config/config.js for the hostname
  2) Bootstraps Keycloak (realm/clients/roles/users)
  3) Captures the generated backend client secret and writes it into config/config.js
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
  echo "Missing --host" >&2
  exit 2
fi
if [[ -z "$company_role" ]]; then
  echo "Missing --company-role" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

need_cmd() {
  local c="$1"
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "Missing dependency: ${c}" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd awk
need_cmd perl
need_cmd python3

if ! docker compose version >/dev/null 2>&1; then
  echo "Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi

echo "Step 1/3: Configure repo files for host '${host}'"
"${repo_root}/installation-scripts/configure-host.sh" --host "${host}"

echo "Step 2/3: Bootstrap Keycloak (realm/clients/roles/users)"
set +e
bootstrap_out="$(
  KC_HOSTNAME="${host}" \
  KEYCLOAK_ADMIN="${admin_user}" \
  KEYCLOAK_ADMIN_PASSWORD="${admin_pass}" \
  "${repo_root}/installation-scripts/keycloak-bootstrap.sh" \
    --host "${host}" \
    --company-role "${company_role}" \
    --realm "${realm}" \
    --admin-user "${admin_user}" \
    --admin-pass "${admin_pass}" \
    ${users_csv:+--users "${users_csv}"} \
  2>&1
)"
rc=$?
set -e

printf '%s\n' "${bootstrap_out}"
if [[ $rc -ne 0 ]]; then
  echo "Keycloak bootstrap failed (exit ${rc})." >&2
  exit $rc
fi

backend_secret="$(printf '%s\n' "${bootstrap_out}" | awk -F= '/^BACKEND_CLIENT_SECRET=/{print $2; exit}')"
if [[ -z "${backend_secret}" ]]; then
  echo "Failed to parse backend secret from keycloak-bootstrap output." >&2
  exit 1
fi

echo "Step 3/3: Write backend client secret into config/config.js"
"${repo_root}/installation-scripts/configure-host.sh" --host "${host}" --backend-secret "${backend_secret}"

echo ""
echo "Bootstrap complete."
echo "- Certs: place them at installation-scripts/certs/${host}.crt and installation-scripts/certs/${host}.key (preferred), or nginx/certs/"
echo "- Start/update stack: docker compose up -d"
