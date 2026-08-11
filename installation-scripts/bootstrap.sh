#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Bootstrap — fully automated first-time deployment
#
# Usage:
#   ./installation-scripts/bootstrap.sh \
#     --host padsign.client.com \
#     --company-role "ClientName" \
#     --admin-pass "StrongKeycloakAdminPass" \
#     --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
#     --cert-key ./installation-scripts/certs/padsign.client.com.key
#
# What it does (end-to-end):
#   1) Backs up config files
#   2) Pre-flight TLS cert validation (chain, key match, expiry, hostname)
#   3) Rewrites all config/nginx for the hostname
#   4) Creates signed-output and docs directories
#   5) Starts Keycloak, bootstraps realm/clients/roles/users
#   6) Writes backend client secret into config
#   7) Pulls Docker images and starts all services
#   8) Verifies everything is running correctly
# ============================================================================

host=""
realm="padsign"
company_role=""
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-}"
users_csv=""
enable_routing="false"
enable_demo="false"
enable_local_eseal="false"
cert_crt=""
cert_key=""
allow_self_signed="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/bootstrap.sh \
    --host example.com \
    --company-role "Acme" \
    --admin-pass "StrongPassword" \
    [--cert-crt path/to/cert.crt] \
    [--cert-key path/to/cert.key] \
    [--realm padsign] \
    [--admin-user admin] \
    [--users "alice:Passw0rd!:padsign-admin,bob:Passw0rd!:psapp-integration"] \
    [--enable-routing] \
    [--enable-demo] \
    [--enable-local-eseal] \
    [--allow-self-signed]

Required:
  --host           Hostname for the deployment (e.g., padsign.client.com)
  --company-role   Company name / Keycloak realm role (e.g., "Acme")
  --admin-pass     Keycloak admin password (do NOT use default "admin" in production)

Optional:
  --cert-crt/--cert-key   TLS certificate files (or place in installation-scripts/certs/)
  --realm                 Keycloak realm name (default: padsign)
  --admin-user            Keycloak admin username (default: admin)
  --users                 Additional users as CSV: "user1:pass1:role,user2:pass2:role"
  --enable-routing        Enable filesystem document routing after signing
  --enable-demo           Enable DEMO mode in client
  --enable-local-eseal    Provision the local e-sealing stack (dmss-digital-stamping-service
                          container + demo seal.p12) and switch STAMP_MODE to "local".
                          External e-sealing remains the default when this flag is omitted.
  --allow-self-signed     Skip cert chain verification (use for dev/test self-signed certs).
                          All other cert checks (format, key match, expiry, hostname) still run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --users) users_csv="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --enable-routing) enable_routing="true"; shift 1;;
    --enable-demo) enable_demo="true"; shift 1;;
    --enable-local-eseal) enable_local_eseal="true"; shift 1;;
    --allow-self-signed) allow_self_signed="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

# --- Validate required params ---
missing=()
[[ -z "$host" ]] && missing+=("--host")
[[ -z "$company_role" ]] && missing+=("--company-role")
[[ -z "$admin_pass" ]] && missing+=("--admin-pass")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}" >&2
  usage
  exit 2
fi

if [[ "$admin_pass" == "admin" ]]; then
  echo "WARNING: Using default admin password 'admin' is insecure. Consider --admin-pass with a strong password." >&2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="${repo_root}/installation-scripts"

# --- Dependency checks ---
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd awk
need_cmd perl
need_cmd python3
need_cmd curl
need_cmd openssl

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Missing dependency: docker compose (Compose v2)" >&2
  exit 1
fi

echo "========================================"
echo "PadSign Bootstrap"
echo "  Host:         ${host}"
echo "  Company:      ${company_role}"
echo "  Realm:        ${realm}"
echo "  Demo mode:    ${enable_demo}"
echo "  Doc routing:  ${enable_routing}"
echo "  Local eseal:  ${enable_local_eseal}"
echo "========================================"
echo ""

# ── Step 1: Backup ──
echo "Step 1/8: Backing up config files..."
for f in "${repo_root}/config/config.js" "${repo_root}/config/constants.json" "${repo_root}/nginx/nginx.conf" "${repo_root}/docker-compose.yml"; do
  if [[ -f "$f" ]]; then
    cp -f "$f" "${f}.bak"
  fi
done
echo "  Backups created (*.bak)"

# ── Step 2: Pre-flight TLS validation ──
echo "Step 2/8: Validating TLS certificate..."
effective_crt="${cert_crt:-${scripts_dir}/certs/${host}.crt}"
effective_key="${cert_key:-${scripts_dir}/certs/${host}.key}"
if [[ -f "$effective_crt" && -f "$effective_key" ]]; then
  validate_args=(--host "$host" --cert-crt "$effective_crt" --cert-key "$effective_key")
  [[ "$allow_self_signed" == "true" ]] && validate_args+=(--allow-self-signed)
  "${scripts_dir}/validate-certs.sh" "${validate_args[@]}"
else
  echo "  INFO: No certs found at ${effective_crt} — skipping pre-flight validation."
  echo "        nginx will fail to start until certs are placed in nginx/certs/."
fi

# ── Step 3: Configure hostname ──
echo "Step 3/8: Configuring files for hostname '${host}'..."
configure_args=(--host "${host}" --company-role "${company_role}" --admin-user "${admin_user}" --admin-pass "${admin_pass}")
[[ -n "$cert_crt" ]] && configure_args+=(--cert-crt "$cert_crt")
[[ -n "$cert_key" ]] && configure_args+=(--cert-key "$cert_key")
[[ "$enable_routing" == "true" ]] && configure_args+=(--enable-routing)
[[ "$enable_demo" == "true" ]] && configure_args+=(--enable-demo)
[[ "$enable_local_eseal" == "true" ]] && configure_args+=(--enable-local-eseal)
"${scripts_dir}/configure-host.sh" "${configure_args[@]}"

# ── Step 4: Create signed-output and docs directories ──
echo "Step 4/8: Setting up signed-output and docs directories..."
mkdir -p "${repo_root}/signed-output"
chmod 777 "${repo_root}/signed-output" 2>/dev/null || true
echo "  Created ${repo_root}/signed-output"
mkdir -p "${repo_root}/docs"
chmod 777 "${repo_root}/docs" 2>/dev/null || true
echo "  Created ${repo_root}/docs (mounted by dmss-archive-services-fallback)"

# ── Step 5: Bootstrap Keycloak ──
echo "Step 5/8: Bootstrapping Keycloak (realm/clients/roles/users)..."
secret_file="$(mktemp)"
chmod 600 "$secret_file"
trap 'rm -f "$secret_file"' EXIT

set +e
bootstrap_out="$(
  KC_HOSTNAME="${host}" \
  KEYCLOAK_ADMIN="${admin_user}" \
  KEYCLOAK_ADMIN_PASSWORD="${admin_pass}" \
  "${scripts_dir}/keycloak-bootstrap.sh" \
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

# Show output but filter secrets
printf '%s\n' "${bootstrap_out}" | grep -v '^BACKEND_CLIENT_SECRET='
if [[ $rc -ne 0 ]]; then
  echo "ERROR: Keycloak bootstrap failed (exit ${rc})." >&2
  echo "  Restore backups with: for f in config/config.js config/constants.json nginx/nginx.conf docker-compose.yml; do cp \"\${f}.bak\" \"\$f\"; done" >&2
  exit $rc
fi

backend_secret="$(printf '%s\n' "${bootstrap_out}" | awk -F= '/^BACKEND_CLIENT_SECRET=/{print $2; exit}')"
if [[ -z "${backend_secret}" ]]; then
  echo "ERROR: Failed to parse backend secret from keycloak-bootstrap output." >&2
  exit 1
fi

# ── Step 6: Write backend secret ──
echo "Step 6/8: Writing backend client secret into config..."
"${scripts_dir}/configure-host.sh" --host "${host}" --backend-secret "${backend_secret}"

# ── Step 7: Pull images and start stack ──
echo "Step 7/8: Pulling Docker images and starting services..."
cd "${repo_root}"
docker compose pull
docker compose up -d
echo "  All services started"

# ── Step 8: Verify ──
echo "Step 8/8: Verifying deployment..."
echo "  Waiting for services to initialize..."
sleep 5

# Check ps-server is responding
for i in $(seq 1 30); do
  if docker compose logs ps-server 2>/dev/null | grep -q "PadSign Server listening"; then
    echo "  ps-server: OK"
    break
  fi
  sleep 2
  if [[ "$i" == "30" ]]; then
    echo "  WARNING: ps-server may not have started. Check: docker compose logs ps-server" >&2
  fi
done

# Check redirect
redirect_status="$(curl -ksI "https://localhost/" 2>/dev/null | head -1 || true)"
if echo "$redirect_status" | grep -q "301"; then
  echo "  Root redirect: OK (301 -> /portal/)"
else
  echo "  WARNING: Root redirect not working. Check nginx config." >&2
fi

# Check containers
echo ""
echo "  Running containers:"
docker ps --format '  {{.Names}}: {{.Image}} ({{.Status}})' | sort

echo ""
echo "========================================"
echo "Bootstrap complete!"
echo ""
echo "  Portal:    https://${host}/portal/"
echo "  Keycloak:  https://${host}/auth/admin/"
echo "  API:       https://${host}/api/"
echo ""
echo "  Admin user: ${admin_user}"
echo "  Test user:  test (see keycloak-bootstrap output for password)"
echo "  WARNING: Delete 'test' user before production use!"
echo ""
echo "  Certs: ensure ${host}.crt and ${host}.key are in nginx/certs/"
echo "========================================"
