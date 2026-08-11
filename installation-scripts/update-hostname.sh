#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Update Hostname — change the deployed hostname on an ALREADY-LIVE
# stack (deployment-wizard Settings feature, see documentation/37-*).
#
# Usage:
#   ./installation-scripts/update-hostname.sh \
#     --host padsign.newclient.com \
#     --admin-pass "CurrentKeycloakAdminPassword" \
#     [--cert-crt path/to/new.crt --cert-key path/to/new.key] \
#     [--admin-user admin] [--realm padsign] [--allow-self-signed]
#
# What it does (end-to-end):
#   1) Backs up config files
#   2) Rewrites nginx/config files for the new hostname (+ cert, if given)
#   3) Syncs the Keycloak client's redirect URIs to the new hostname
#   4) Restarts nginx + ps-server and verifies
#
# Deliberately does NOT: touch Keycloak's own admin bootstrap credentials
# (docker-compose.yml's KEYCLOAK_ADMIN*), change any --enable-*/--disable-*
# feature flags (configure-host.sh's flags are additive-only, so omitting
# them is already a true no-op against existing feature state), reset the
# demo 'test' Keycloak user (see keycloak-bootstrap.sh --skip-test-user), or
# touch KC_HOSTNAME on the keycloak compose service (inert today given
# KC_HOSTNAME_STRICT=false + KC_PROXY=edge) — it changes ONLY the hostname.
# ============================================================================

host=""
admin_user="admin"
admin_pass=""
realm="padsign"
cert_crt=""
cert_key=""
allow_self_signed="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/update-hostname.sh --host padsign.newclient.com \
    --admin-pass "CurrentKeycloakAdminPassword" \
    [--cert-crt path/to/new.crt --cert-key path/to/new.key] \
    [--admin-user admin] [--realm padsign] [--allow-self-signed]

Required:
  --host         New hostname for the deployment
  --admin-pass   The CURRENT Keycloak admin password (used to log in to
                 Keycloak, not to change it — see documentation/37-05-*)

Optional:
  --cert-crt/--cert-key   New TLS certificate for the new hostname. If
                          omitted, a cert must already exist at
                          nginx/certs/<new-host>.{crt,key} (e.g. a wildcard
                          cert placed there ahead of time) — configure-host.sh
                          always points nginx at the new hostname's cert
                          path, so nginx will fail to start without one.
  --admin-user            Keycloak admin username (default: admin)
  --realm                 Keycloak realm name (default: padsign)
  --allow-self-signed     Currently informational only (pre-flight cert
                          chain checking for the new cert happens in the
                          wizard before this script runs; kept here so the
                          same flag set as bootstrap.sh/validate-certs.sh
                          works if this is invoked directly).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-self-signed) allow_self_signed="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

missing=()
[[ -z "$host" ]] && missing+=("--host")
[[ -z "$admin_pass" ]] && missing+=("--admin-pass")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}" >&2
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="${repo_root}/installation-scripts"
config_js="${repo_root}/config/config.js"
cert_staging_dir="${scripts_dir}/certs"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}
need_cmd docker
need_cmd perl
need_cmd python3
need_cmd curl
need_cmd sed

# A cert must resolve for the NEW host before anything else is touched:
# configure-host.sh's nginx.conf cert-path rewrite is unconditional (points
# nginx at /etc/nginx/certs/<new-host>.{crt,key} regardless of whether that
# file exists), so failing loudly here beats leaving nginx unable to start.
# Default fallback is the STAGING path (installation-scripts/certs/), the
# same one configure-host.sh itself defaults to and the same one
# certValidator.js's validateCert() writes a freshly-uploaded/validated cert
# to — NOT nginx/certs/ (that's the DEPLOYED path, what's already live for
# the OLD hostname, which is exactly what we're about to replace).
effective_crt="${cert_crt:-${cert_staging_dir}/${host}.crt}"
effective_key="${cert_key:-${cert_staging_dir}/${host}.key}"
if [[ ! -f "$effective_crt" || ! -f "$effective_key" ]]; then
  echo "ERROR: No certificate available for '${host}'." >&2
  echo "       Pass --cert-crt/--cert-key, or place ${host}.{crt,key} in installation-scripts/certs/ first." >&2
  echo "       (configure-host.sh always points nginx at the new hostname's cert path.)" >&2
  exit 2
fi

echo "========================================"
echo "PadSign Update Hostname"
echo "  New host: ${host}"
echo "========================================"
echo ""

# ── Step 1: Backup ──
echo "Step 1/4: Backing up config files..."
for f in "${config_js}" "${repo_root}/config/constants.json" "${repo_root}/nginx/nginx.conf" "${repo_root}/docker-compose.yml"; do
  if [[ -f "$f" ]]; then
    cp -f "$f" "${f}.bak"
  fi
done
echo "  Backups created (*.bak)"

# ── Step 2: Configure files for the new hostname ──
echo "Step 2/4: Configuring files for hostname '${host}'..."
configure_args=(--host "${host}")
[[ -n "$cert_crt" ]] && configure_args+=(--cert-crt "$cert_crt")
[[ -n "$cert_key" ]] && configure_args+=(--cert-key "$cert_key")
"${scripts_dir}/configure-host.sh" "${configure_args[@]}"

# ── Step 3: Sync Keycloak client ──
echo "Step 3/4: Syncing Keycloak client for '${host}'..."
company_role="$(sed -nE 's/^\s*DEMO_COMPANY_ROLE:\s*"([^"]*)".*/\1/p' "$config_js" | head -1)"
if [[ -z "$company_role" ]]; then
  echo "ERROR: Could not determine the existing company/role from config/config.js (DEMO_COMPANY_ROLE)." >&2
  echo "       Restore from backup and investigate: cp ${config_js}.bak ${config_js}" >&2
  exit 1
fi
"${scripts_dir}/keycloak-bootstrap.sh" \
  --host "${host}" \
  --company-role "${company_role}" \
  --realm "${realm}" \
  --admin-user "${admin_user}" \
  --admin-pass "${admin_pass}" \
  --skip-test-user

# ── Step 4: Restart and verify ──
echo "Step 4/4: Restarting nginx + ps-server and verifying..."
cd "${repo_root}"
restart_at="$(date +%s)"
docker compose restart nginx ps-server

# --since filters to lines emitted AFTER this restart — docker compose
# restart reuses the same container, so its log history still contains
# "listening" lines from before the restart, which would otherwise make
# this check pass even if the new process crashed on start. Poll rather
# than a single fixed sleep — a one-shot check was observed to
# false-positive-WARN under load (the restart itself was fine; the app
# just hadn't printed its startup banner yet).
ps_server_ok="false"
for i in $(seq 1 15); do
  if docker compose logs --since "$restart_at" ps-server 2>/dev/null | grep -q "PadSign Server listening"; then
    ps_server_ok="true"
    break
  fi
  sleep 1
done
if [[ "$ps_server_ok" == "true" ]]; then
  echo "  ps-server: OK"
else
  echo "  WARNING: ps-server may not have restarted correctly. Check: docker compose logs ps-server" >&2
fi

redirect_status="$(curl -ksI "https://localhost/" 2>/dev/null | head -1 || true)"
if echo "$redirect_status" | grep -q "301"; then
  echo "  Root redirect: OK (301 -> /portal/)"
else
  echo "  WARNING: Root redirect not verified. Check: docker compose logs nginx" >&2
fi

echo ""
echo "========================================"
echo "Hostname update complete!"
echo "  Portal:   https://${host}/portal/"
echo "  Keycloak: https://${host}/auth/admin/"
echo "========================================"
