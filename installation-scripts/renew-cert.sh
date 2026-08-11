#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Renew Certificate — swap the TLS cert on an ALREADY-LIVE stack
# without changing the hostname (deployment-wizard Settings feature, see
# documentation/37-*).
#
# Usage:
#   ./installation-scripts/renew-cert.sh \
#     --host padsign.client.com \
#     --cert-crt path/to/renewed.crt --cert-key path/to/renewed.key \
#     [--allow-encrypted-key]
#
# What it does:
#   1) Copies the new cert/key into place via configure-host.sh (host is
#      unchanged, so every OTHER rewrite that script does — nginx server_name,
#      config.js/constants.json URLs — is a byte-for-byte no-op; this is
#      purely a cert swap)
#   2) Restarts nginx (which configure-host.sh never does on its own) and
#      verifies the newly-served certificate's expiry over the wire
# ============================================================================

host=""
cert_crt=""
cert_key=""
allow_encrypted_key="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/renew-cert.sh --host padsign.client.com \
    --cert-crt path/to/renewed.crt --cert-key path/to/renewed.key \
    [--allow-encrypted-key]

Required:
  --host          The CURRENT (unchanged) hostname of the deployment
  --cert-crt      New certificate file (fullchain: leaf + intermediates)
  --cert-key      New private key file, matching --cert-crt

Optional:
  --allow-encrypted-key   Passed through to configure-host.sh — allows an
                          encrypted private key (nginx cannot use one
                          non-interactively; only use if you decrypt it
                          another way before nginx starts).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-encrypted-key) allow_encrypted_key="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

missing=()
[[ -z "$host" ]] && missing+=("--host")
[[ -z "$cert_crt" ]] && missing+=("--cert-crt")
[[ -z "$cert_key" ]] && missing+=("--cert-key")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}" >&2
  usage
  exit 2
fi

if [[ ! -f "$cert_crt" ]]; then
  echo "ERROR: --cert-crt file not found: ${cert_crt}" >&2
  exit 2
fi
if [[ ! -f "$cert_key" ]]; then
  echo "ERROR: --cert-key file not found: ${cert_key}" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="${repo_root}/installation-scripts"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}
need_cmd docker
need_cmd openssl
need_cmd perl
need_cmd python3

echo "========================================"
echo "PadSign Renew Certificate"
echo "  Host: ${host}"
echo "========================================"
echo ""

# ── Step 1: Install the new certificate ──
echo "Step 1/2: Installing new certificate..."
configure_args=(--host "${host}" --cert-crt "${cert_crt}" --cert-key "${cert_key}")
[[ "$allow_encrypted_key" == "true" ]] && configure_args+=(--allow-encrypted-key)
"${scripts_dir}/configure-host.sh" "${configure_args[@]}"

file_expiry="$(openssl x509 -in "${cert_crt}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
if [[ -n "$file_expiry" ]]; then
  echo "  New certificate file: OK (valid until ${file_expiry})"
else
  echo "  WARNING: Could not read the new certificate's expiry from file" >&2
fi

# ── Step 2: Restart nginx and verify ──
echo "Step 2/2: Restarting nginx and verifying..."
cd "${repo_root}"
docker compose restart nginx
sleep 3

# Scoped to THIS compose project (via cwd), not a global `docker ps` name
# match — a customized deployment's nginx container may not literally be
# named "nginx" (some customer compose files already diverge from the repo
# baseline in other ways), and `docker compose ps` resolves the right
# container regardless.
if docker compose ps nginx --format '{{.State}}' 2>/dev/null | grep -qi "running"; then
  echo "  nginx: OK"
else
  echo "  WARNING: nginx does not appear to be running. Check: docker compose logs nginx" >&2
fi

# Confirms nginx actually picked up the new cert over the wire, not just
# that the file on disk changed — nginx only reads its cert at startup, so
# this is the real proof the restart above took effect. Assumes the
# standard host port 443, same convention bootstrap.sh's own root-redirect
# check already relies on. `|| true` is required, not optional: this is a
# real network handshake, and its own transient failure (or `set -e`
# +pipefail catching openssl/sed's exit code) must never abort the whole
# renewal — the cert was already installed and nginx already restarted
# successfully above; this check is purely informational from here on.
# Found live: an intermittent handshake hiccup made an otherwise-successful
# renewal report as a hard failure.
served_expiry="$(echo | openssl s_client -connect localhost:443 -servername "${host}" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || true)"
if [[ -n "$served_expiry" ]]; then
  echo "  TLS handshake: OK (serving cert valid until ${served_expiry})"
else
  echo "  WARNING: Could not verify the served certificate over TLS. Check: docker compose logs nginx" >&2
fi

echo ""
echo "========================================"
echo "Certificate renewal complete!"
echo "========================================"
