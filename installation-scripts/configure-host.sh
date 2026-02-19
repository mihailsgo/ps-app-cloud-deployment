#!/usr/bin/env bash
set -euo pipefail

host=""
backend_secret=""
allow_encrypted_key="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/configure-host.sh --host example.com [--backend-secret <secret>]
                                     [--cert-crt ./installation-scripts/certs/example.com.crt]
                                     [--cert-key ./installation-scripts/certs/example.com.key]
                                     [--allow-encrypted-key]

What it edits in-place:
  - nginx/nginx.conf: server_name + cert file names
  - config/constants.json: KEYCLOAK_URL + redirect URIs + download/test URLs
  - config/config.js: Keycloak auth-server-url + service base URLs + ALLOWED_ORIGINS (+ optional backend secret)

Notes:
  - certificates are expected at nginx/certs/<host>.crt and nginx/certs/<host>.key (same pattern as current repo)
  - if you provide --cert-crt/--cert-key (or place them under installation-scripts/certs/), the script copies them into nginx/certs/
  - nginx cannot start non-interactively with a password-protected private key unless you add ssl_password_file support
  - run this once per new server/hostname before starting compose
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --backend-secret) backend_secret="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-encrypted-key) allow_encrypted_key="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "Missing --host" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nginx_conf="${repo_root}/nginx/nginx.conf"
constants_json="${repo_root}/config/constants.json"
config_js="${repo_root}/config/config.js"

# Optional certificate copy: source is either explicit flags or installation-scripts/certs/<host>.crt|.key.
cert_crt="${cert_crt:-${repo_root}/installation-scripts/certs/${host}.crt}"
cert_key="${cert_key:-${repo_root}/installation-scripts/certs/${host}.key}"
nginx_certs_dir="${repo_root}/nginx/certs"
dest_crt="${nginx_certs_dir}/${host}.crt"
dest_key="${nginx_certs_dir}/${host}.key"

if [[ ! -f "$nginx_conf" || ! -f "$constants_json" || ! -f "$config_js" ]]; then
  echo "Expected files not found. Run from repo or keep standard layout." >&2
  exit 1
fi

echo "Configuring hostname: ${host}"

# If source certs exist, copy them into nginx/certs/.
mkdir -p "$nginx_certs_dir"
if [[ -f "$cert_crt" && -f "$cert_key" ]]; then
  cp -f "$cert_crt" "$dest_crt"
  cp -f "$cert_key" "$dest_key"
  chmod 600 "$dest_key" 2>/dev/null || true
  echo "Copied certs:"
  echo "  - ${dest_crt}"
  echo "  - ${dest_key}"

  if grep -q "ENCRYPTED" "$dest_key"; then
    if [[ "$allow_encrypted_key" != "true" ]]; then
      echo "ERROR: Private key appears to be encrypted (password-protected): ${dest_key}" >&2
      echo "NGINX will not be able to start non-interactively with an encrypted key." >&2
      echo "" >&2
      echo "Fix options:" >&2
      echo "1) Provide an unencrypted PEM key (recommended)." >&2
      echo "   Example: openssl pkey -in <encrypted.key> -out installation-scripts/certs/${host}.key" >&2
      echo "2) Add NGINX ssl_password_file support and mount a password file (more moving parts)." >&2
      echo "" >&2
      echo "To bypass this check (not recommended): add --allow-encrypted-key" >&2
      exit 1
    fi
  fi
fi

# nginx: set server_name and cert filenames.
perl -0777 -i -pe "s/server_name\\s+[^;]+;/server_name ${host};/g; s#ssl_certificate\\s+/etc/nginx/certs/[^;]+;#ssl_certificate     /etc/nginx/certs/${host}.crt;#g; s#ssl_certificate_key\\s+/etc/nginx/certs/[^;]+;#ssl_certificate_key /etc/nginx/certs/${host}.key;#g" "$nginx_conf"

# constants.json: set URLs (keep other keys intact).
python3 - "$constants_json" "$host" <<'PY'
import json, sys
path = sys.argv[1]
host = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
  data = json.load(f)

data["KEYCLOAK_URL"] = f"https://{host}/auth"
data["KEYCLOAK_REDIRECT_URI"] = f"https://{host}/portal/"
data["KEYCLOAK_POST_LOGOUT_REDIRECT_URI"] = f"https://{host}/portal/"
data["PS_DOWNLOAD_API"] = f"https://{host}/archive/api/document/"
data["PDF_TEST_PATH"] = f"https://{host}/template"

with open(path, "w", encoding="utf-8") as f:
  json.dump(data, f, ensure_ascii=False, indent=4)
  f.write("\n")
PY

# config.js: update URL-ish fields and allowed origins.
perl -0777 -i -pe "s#https://[^/\\\"']+/auth#https://${host}/auth#g; s#https://[^/\\\"']+/archive/api/#https://${host}/archive/api/#g; s#https://[^/\\\"']+/container/api/#https://${host}/container/api/#g; s#'https://[^']+:5173'#'https://${host}:5173'#g; s#'https://[^']+'#'https://${host}'#g" "$config_js"

if [[ -n "$backend_secret" ]]; then
  # Replace only the Keycloak client secret line.
  perl -0777 -i -pe "s/(\"secret\"\\s*:\\s*\")[^\"]*(\")/\\1${backend_secret}\\2/" "$config_js"
fi

echo "Updated:"
echo "  - ${nginx_conf}"
echo "  - ${constants_json}"
echo "  - ${config_js}"
