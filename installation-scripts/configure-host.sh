#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Configure all config files for a specific hostname.
# Safe to re-run — creates .bak backups before each edit.
# ============================================================================

host=""
backend_secret=""
company_role=""
allow_encrypted_key="false"
enable_routing="false"
enable_demo="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/configure-host.sh --host example.com \
    [--company-role "Acme"] \
    [--backend-secret <secret>] \
    [--cert-crt path/to/cert.crt] [--cert-key path/to/cert.key] \
    [--allow-encrypted-key] \
    [--enable-routing] [--enable-demo]

Edits in-place (with .bak backup):
  - nginx/nginx.conf: server_name, cert filenames, root→/portal/ redirect
  - config/constants.json: Keycloak URLs, redirect URIs, download URLs
  - config/config.js: Keycloak URLs, service URLs, ALLOWED_ORIGINS, DEMO_COMPANY_ROLE
  - docker-compose.yml: ensures signed-output volume mount exists
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --backend-secret) backend_secret="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-encrypted-key) allow_encrypted_key="true"; shift 1;;
    --enable-routing) enable_routing="true"; shift 1;;
    --enable-demo) enable_demo="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host" >&2
  exit 2
fi

# --- Dependency checks ---
need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}
need_cmd perl
need_cmd python3

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nginx_conf="${repo_root}/nginx/nginx.conf"
constants_json="${repo_root}/config/constants.json"
config_js="${repo_root}/config/config.js"
compose_yml="${repo_root}/docker-compose.yml"

# Verify expected files exist
for f in "$nginx_conf" "$constants_json" "$config_js" "$compose_yml"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: Expected file not found: $f" >&2
    exit 1
  fi
done

# Escape hostname for use in perl regex (dots become literal)
host_escaped="$(printf '%s' "$host" | sed 's/[.]/\\./g')"

echo "Configuring hostname: ${host}"

# --- Certificates ---
cert_crt="${cert_crt:-${repo_root}/installation-scripts/certs/${host}.crt}"
cert_key="${cert_key:-${repo_root}/installation-scripts/certs/${host}.key}"
nginx_certs_dir="${repo_root}/nginx/certs"
dest_crt="${nginx_certs_dir}/${host}.crt"
dest_key="${nginx_certs_dir}/${host}.key"

mkdir -p "$nginx_certs_dir"
if [[ -f "$cert_crt" && -f "$cert_key" ]]; then
  cp -f "$cert_crt" "$dest_crt"
  cp -f "$cert_key" "$dest_key"
  chmod 600 "$dest_key" 2>/dev/null || true
  echo "  Copied certs to nginx/certs/"

  if grep -q "ENCRYPTED" "$dest_key" && [[ "$allow_encrypted_key" != "true" ]]; then
    echo "ERROR: Private key is encrypted. NGINX cannot start non-interactively." >&2
    echo "  Decrypt: openssl pkey -in <encrypted.key> -out installation-scripts/certs/${host}.key" >&2
    echo "  Or use --allow-encrypted-key to bypass." >&2
    exit 1
  fi
fi

# --- Backup helper ---
backup() {
  local f="$1"
  cp -f "$f" "${f}.bak" 2>/dev/null || true
}

# --- nginx.conf ---
backup "$nginx_conf"
perl -0777 -i -pe "
  s/server_name\\s+[^;]+;/server_name ${host};/g;
  s#ssl_certificate\\s+/etc/nginx/certs/[^;]+;#ssl_certificate     /etc/nginx/certs/${host}.crt;#g;
  s#ssl_certificate_key\\s+/etc/nginx/certs/[^;]+;#ssl_certificate_key /etc/nginx/certs/${host}.key;#g;
" "$nginx_conf"

# Ensure root location redirects to /portal/ (replace any existing location / block in HTTPS server)
python3 - "$nginx_conf" <<'PY'
import sys, re

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

# Find the last "location / {" block (in the HTTPS server) and replace it
# Match: location / { ... } — non-greedy, handles multi-line
pattern = r'(    # (?:Serve static|Redirect root|Or, if you want)[^\n]*\n)?    location / \{[^}]+\}'
replacement = '    # Redirect root to /portal/\n    location / {\n        return 301 https://$host/portal/;\n    }'

# Replace only the last occurrence
matches = list(re.finditer(pattern, content))
if matches:
    last = matches[-1]
    content = content[:last.start()] + replacement + content[last.end():]

with open(path, "w") as f:
    f.write(content)
PY
echo "  Updated nginx/nginx.conf"

# --- constants.json ---
backup "$constants_json"
python3 - "$constants_json" "$host" "$enable_demo" <<'PY'
import json, sys

path, host, enable_demo = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data["KEYCLOAK_URL"] = f"https://{host}/auth"
data["KEYCLOAK_REDIRECT_URI"] = f"https://{host}/portal/"
data["KEYCLOAK_POST_LOGOUT_REDIRECT_URI"] = f"https://{host}/portal/"
data["PS_DOWNLOAD_API"] = f"https://{host}/archive/api/document/"
data["PDF_TEST_PATH"] = f"https://{host}/template"

if enable_demo == "true":
    data["DEMO_MODE"] = "ENABLE"

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=4)
    f.write("\n")
PY

# Validate JSON
python3 -m json.tool "$constants_json" > /dev/null 2>&1 || {
  echo "ERROR: constants.json is invalid JSON after edit!" >&2
  echo "  Restore from backup: cp ${constants_json}.bak ${constants_json}" >&2
  exit 1
}
echo "  Updated config/constants.json"

# --- config.js ---
backup "$config_js"
perl -0777 -i -pe "
  s#https://[^/\\\"']+/auth#https://${host}/auth#g;
  s#https://[^/\\\"']+/archive/api/#https://${host}/archive/api/#g;
  s#https://[^/\\\"']+/container/api/#https://${host}/container/api/#g;
  s#'https://[^']+:5173'#'https://${host}:5173'#g;
  s#'https://[^']+'#'https://${host}'#g;
" "$config_js"

if [[ -n "$backend_secret" ]]; then
  perl -0777 -i -pe "s/(\"secret\"\\s*:\\s*\")[^\"]*(\")/\${1}${backend_secret}\${2}/" "$config_js"
fi

if [[ -n "$company_role" ]]; then
  perl -i -pe "s/(DEMO_COMPANY_ROLE:\\s*\")[^\"]*(\")$/\${1}${company_role}\${2},/" "$config_js"
fi

# Ensure DOCUMENT_ROUTING exists in config.js
if ! grep -q 'DOCUMENT_ROUTING' "$config_js"; then
  # Insert before closing };
  perl -0777 -i -pe 's/(\n\};)$/\n\n    \/\/ Document Routing (post-signing actions) - disabled by default\n    DOCUMENT_ROUTING: {\n      enabled: false,\n      skipDemo: true,\n      strategies: [\n        {\n          type: "filesystem",\n          enabled: false,\n          basePath: "\/signed-output",\n          pathTemplate: "{company}\/{date:YYYY-MM}\/{company}_{clientName}_{date:YYYY-MM-DD_HHmm}.pdf",\n          createDirectories: true\n        },\n        {\n          type: "webhook",\n          enabled: false,\n          url: "https:\/\/example.com\/api\/signing-status",\n          method: "POST",\n          headers: {},\n          includeFile: false,\n          timeoutMs: 10000,\n          retries: 3,\n          retryBaseDelayMs: 1000\n        }\n      ]\n    },\n};/' "$config_js"
fi

# Enable routing if requested
if [[ "$enable_routing" == "true" ]]; then
  # Enable master switch and filesystem strategy
  perl -i -pe 'if (/DOCUMENT_ROUTING/) { $in_dr=1 } if ($in_dr && /^\s*enabled:\s*false/) { s/false/true/; $in_dr=0 }' "$config_js"
  perl -i -pe 'if (/type:\s*"filesystem"/) { $in_fs=1 } if ($in_fs && /^\s*enabled:\s*false/) { s/false/true/; $in_fs=0 }' "$config_js"
fi

echo "  Updated config/config.js"

# --- docker-compose.yml: ensure signed-output volume mount ---
backup "$compose_yml"
if ! grep -q 'signed-output:/signed-output' "$compose_yml"; then
  sed -i '/config\/config\.js:\/usr\/src\/app\/config\.js/a\      - "./signed-output:/signed-output"' "$compose_yml"
  echo "  Added signed-output volume mount to docker-compose.yml"
fi

echo "  Configuration complete for ${host}"
