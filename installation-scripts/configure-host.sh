#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Configure all config files for a specific hostname.
# Safe to re-run — creates .bak backups before each edit.
# ============================================================================

host=""
backend_secret=""
company_role=""
admin_user=""
admin_pass=""
allow_encrypted_key="false"
enable_routing="false"
enable_demo="false"
enable_local_eseal="false"
disable_routing="false"
disable_demo="false"
disable_local_eseal="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/configure-host.sh --host example.com \
    [--company-role "Acme"] \
    [--backend-secret <secret>] \
    [--admin-user admin] [--admin-pass <secret>] \
    [--cert-crt path/to/cert.crt] [--cert-key path/to/cert.key] \
    [--allow-encrypted-key] \
    [--enable-routing | --disable-routing] \
    [--enable-demo | --disable-demo] \
    [--enable-local-eseal | --disable-local-eseal]

Edits in-place (with .bak backup):
  - nginx/nginx.conf: server_name, cert filenames, root→/portal/ redirect
  - config/constants.json: Keycloak URLs, redirect URIs, download URLs
  - config/config.js: Keycloak URLs, service URLs, ALLOWED_ORIGINS, DEMO_COMPANY_ROLE
  - docker-compose.yml: ensures signed-output volume mount exists; when
    --admin-user/--admin-pass are given, syncs the keycloak service's
    KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD to match (see below)

--disable-routing/--disable-demo/--disable-local-eseal: symmetric complements
  to the --enable-* flags, for turning a feature back off on an
  already-deployed instance (deployment-wizard Settings feature). Pure file
  edits only — none of these restart anything themselves; the caller
  (toggle-features.sh) is responsible for restarting/stopping the affected
  containers afterward. --disable-routing only flips DOCUMENT_ROUTING's
  master `enabled` switch to false — per-strategy settings (e.g. a
  configured webhook URL) are left untouched, so re-enabling later restores
  exactly what was there before, not blank defaults.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --backend-secret) backend_secret="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-encrypted-key) allow_encrypted_key="true"; shift 1;;
    --enable-routing) enable_routing="true"; shift 1;;
    --enable-demo) enable_demo="true"; shift 1;;
    --enable-local-eseal) enable_local_eseal="true"; shift 1;;
    --disable-routing) disable_routing="true"; shift 1;;
    --disable-demo) disable_demo="true"; shift 1;;
    --disable-local-eseal) disable_local_eseal="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host" >&2
  exit 2
fi

if [[ "$enable_routing" == "true" && "$disable_routing" == "true" ]]; then
  echo "ERROR: Cannot pass both --enable-routing and --disable-routing" >&2
  exit 2
fi
if [[ "$enable_demo" == "true" && "$disable_demo" == "true" ]]; then
  echo "ERROR: Cannot pass both --enable-demo and --disable-demo" >&2
  exit 2
fi
if [[ "$enable_local_eseal" == "true" && "$disable_local_eseal" == "true" ]]; then
  echo "ERROR: Cannot pass both --enable-local-eseal and --disable-local-eseal" >&2
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
python3 - "$constants_json" "$host" "$enable_demo" "$disable_demo" <<'PY'
import json, sys

path, host, enable_demo, disable_demo = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

data["KEYCLOAK_URL"] = f"https://{host}/auth"
data["KEYCLOAK_REDIRECT_URI"] = f"https://{host}/portal/"
data["KEYCLOAK_POST_LOGOUT_REDIRECT_URI"] = f"https://{host}/portal/"
data["PS_DOWNLOAD_API"] = f"https://{host}/archive/api/document/"
data["PDF_TEST_PATH"] = f"https://{host}/template"

if enable_demo == "true":
    data["DEMO_MODE"] = "ENABLE"
elif disable_demo == "true":
    data["DEMO_MODE"] = "DISABLE"

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
  # No `$`-anchor and no hardcoded trailing comma in the replacement (matches
  # the --backend-secret substitution above) — the real config.js has this
  # field mid-object with its own trailing comma already in place, which an
  # end-of-line anchor here doesn't account for. The anchored version below
  # silently never matched, so DEMO_COMPANY_ROLE stayed at its "CHANGE_ME"
  # template default no matter what --company-role was passed. Found via a
  # live E2E test of the Settings feature's update-hostname.sh, which reads
  # this field back and re-uses it — a stale "CHANGE_ME" was being passed to
  # keycloak-bootstrap.sh instead of the real company name.
  perl -i -pe "s/(DEMO_COMPANY_ROLE:\\s*\")[^\"]*(\")/\${1}${company_role}\${2}/" "$config_js"
fi

# Ensure DOCUMENT_ROUTING exists in config.js
if ! grep -q 'DOCUMENT_ROUTING' "$config_js"; then
  # Insert before closing };
  #
  # The anchor tolerates \r and the inserted text adopts the file's existing
  # line endings. The previous bare /(\n\};)$/ never matched a config.js with
  # CRLF endings (which ends "};\r\n"), so on those deployments this insert
  # silently did nothing — and upgrade.sh's equivalent still reported success.
  DR_BLOCK=$(cat <<'BLOCK'

    // Document Routing (post-signing actions) - disabled by default
    DOCUMENT_ROUTING: {
      enabled: false,
      skipDemo: true,
      strategies: [
        {
          type: "filesystem",
          enabled: false,
          basePath: "/signed-output",
          pathTemplate: "{company}/{date:YYYY-MM}/{company}_{clientName}_{date:YYYY-MM-DD_HHmm}.pdf",
          createDirectories: true
        },
        {
          type: "webhook",
          enabled: false,
          url: "https://example.com/api/signing-status",
          method: "POST",
          headers: {},
          includeFile: false,
          timeoutMs: 10000,
          retries: 3,
          retryBaseDelayMs: 1000
        }
      ]
    },
BLOCK
)
  DR_BLOCK="$DR_BLOCK" perl -0777 -i -pe '
    BEGIN { $b = $ENV{DR_BLOCK} }
    $n = /\r\n/ ? "\r\n" : "\n";
    ($t = $b) =~ s/\n/$n/g;
    s/\r?\n\};\r?\n?\z/$n$t$n};$n/;
  ' "$config_js"
  grep -q 'DOCUMENT_ROUTING' "$config_js" \
    || echo "  WARNING: could not locate the closing '};' in config/config.js — DOCUMENT_ROUTING not added" >&2
fi

# Enable routing if requested
if [[ "$enable_routing" == "true" ]]; then
  # Enable master switch and filesystem strategy
  perl -i -pe 'if (/DOCUMENT_ROUTING/) { $in_dr=1 } if ($in_dr && /^\s*enabled:\s*false/) { s/false/true/; $in_dr=0 }' "$config_js"
  perl -i -pe 'if (/type:\s*"filesystem"/) { $in_fs=1 } if ($in_fs && /^\s*enabled:\s*false/) { s/false/true/; $in_fs=0 }' "$config_js"
fi

# Disable routing if requested — master switch ONLY. Per-strategy settings
# (e.g. a customer's configured webhook URL/enabled flag) are deliberately
# left untouched so re-enabling later restores exactly what was there
# before, not blank defaults. Matches on either current value so this is
# idempotent to re-run regardless of whether it's already disabled, and
# stops after the first match so it can never wander into a per-strategy
# `enabled:` line further down the file.
if [[ "$disable_routing" == "true" ]]; then
  perl -i -pe 'if (/DOCUMENT_ROUTING/) { $in_dr=1 } if ($in_dr && /^\s*enabled:\s*(true|false)/) { s/true|false/false/; $in_dr=0 }' "$config_js"
fi

echo "  Updated config/config.js"

# --- docker-compose.yml: ensure signed-output volume mount ---
backup "$compose_yml"
if ! grep -q 'signed-output:/signed-output' "$compose_yml"; then
  sed -i '/config\/config\.js:\/usr\/src\/app\/config\.js/a\      - "./signed-output:/signed-output"' "$compose_yml"
  echo "  Added signed-output volume mount to docker-compose.yml"
fi

# --- docker-compose.yml: sync Keycloak admin bootstrap credentials ---
# The keycloak service's KEYCLOAK_ADMIN/KEYCLOAK_ADMIN_PASSWORD env vars are
# what the container actually creates its master-realm admin account with.
# keycloak-bootstrap.sh's kcadm login uses --admin-user/--admin-pass, so
# these must always match — otherwise Keycloak bootstrap fails with
# "Invalid user credentials" for any admin password other than whatever
# happens to already be in docker-compose.yml. Passed via env vars (not
# interpolated into the perl source) so arbitrary password characters
# (/, &, quotes, backslashes) can never be misread as regex/replacement
# syntax.
if [[ -n "$admin_user" ]]; then
  CFG_ADMIN_USER="$admin_user" perl -i -pe 's/^(\s*-\s*KEYCLOAK_ADMIN=).*/${1}.$ENV{CFG_ADMIN_USER}/e' "$compose_yml"
  echo "  Synced KEYCLOAK_ADMIN in docker-compose.yml"
fi
if [[ -n "$admin_pass" ]]; then
  CFG_ADMIN_PASS="$admin_pass" perl -i -pe 's/^(\s*-\s*KEYCLOAK_ADMIN_PASSWORD=).*/${1}.$ENV{CFG_ADMIN_PASS}/e' "$compose_yml"
  echo "  Synced KEYCLOAK_ADMIN_PASSWORD in docker-compose.yml"
fi

# --- Optional: provision local e-sealing (--enable-local-eseal) ---
# Idempotent: safe to re-run, never overwrites customer artefacts.
if [[ "$enable_local_eseal" == "true" ]]; then
  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets_src="${scripts_dir}/assets/dmss-digital-stamping-service"
  stamping_dst="${repo_root}/dmss-digital-stamping-service"
  csig_yml="${repo_root}/dmss-container-and-signature-services/application.yml"
  env_file="${repo_root}/.env"

  if [[ ! -d "$assets_src" ]]; then
    echo "ERROR: --enable-local-eseal: missing assets at $assets_src" >&2
    exit 3
  fi

  # Stage demo stamping artefacts (cp -n so a customer-supplied seal.p12 is preserved).
  mkdir -p "$stamping_dst/seal"
  cp -n "$assets_src/application.yml"   "$stamping_dst/application.yml"   2>/dev/null || true
  cp -n "$assets_src/seal/seal.p12"     "$stamping_dst/seal/seal.p12"     2>/dev/null || true
  cp -n "$assets_src/seal/README.md"    "$stamping_dst/seal/README.md"    2>/dev/null || true
  echo "  Staged dmss-digital-stamping-service/ demo artefacts"

  # Append the compose service block if absent.
  if ! grep -q 'dmss-digital-stamping-service' "$compose_yml"; then
    if grep -q '^networks:' "$compose_yml"; then
      perl -i -pe 'if (/^networks:/ && !$done) { print "  dmss-digital-stamping-service:\n    container_name: dmss-digital-stamping-service\n    profiles: [\"local-eseal\"]\n    restart: always\n    image: \"trustlynx/digital-stamping-service:24.0.3.0\"\n    environment:\n      - SPRING_CONFIG_ADDITIONAL_LOCATION=file:/conf/\n    volumes:\n      - \"./dmss-digital-stamping-service:/conf:ro\"\n      - \"./dmss-digital-stamping-service/seal:/seal:ro\"\n    extra_hosts:\n      - \"host.docker.internal:host-gateway\"\n\n"; $done=1; }' "$compose_yml"
    else
      cat >>"$compose_yml" <<'COMPOSE_BLOCK'

  dmss-digital-stamping-service:
    container_name: dmss-digital-stamping-service
    profiles: ["local-eseal"]
    restart: always
    image: "trustlynx/digital-stamping-service:24.0.3.0"
    environment:
      - SPRING_CONFIG_ADDITIONAL_LOCATION=file:/conf/
    volumes:
      - "./dmss-digital-stamping-service:/conf:ro"
      - "./dmss-digital-stamping-service/seal:/seal:ro"
    extra_hosts:
      - "host.docker.internal:host-gateway"
COMPOSE_BLOCK
    fi
    echo "  Inserted dmss-digital-stamping-service compose block (profile: local-eseal)"
  fi

  # Pin Spring Security creds on container-signature so basic auth from
  # ps-server is deterministic across restarts.
  if ! grep -q 'SPRING_SECURITY_USER_NAME' "$compose_yml"; then
    # Appends to the service's environment: list rather than inserting before
    # its image: line — the old anchor only produced valid YAML when image:
    # happened to follow environment:. See the fuller note in upgrade.sh.
    SS_LINES=$'      - SPRING_SECURITY_USER_NAME=user\n      - SPRING_SECURITY_USER_PASSWORD=changeit' \
    perl -i -pe '
      BEGIN { $b = $ENV{SS_LINES}; $in = 0; $env = 0; $seen = 0; $done = 0 }
      if (!$done) {
        if (/^  dmss-container-and-signature-services:\s*$/) {
          $in = 1;
        } elsif ($in && /^  \S/) {
          print $seen ? "$b\n" : "    environment:\n$b\n";
          $done = 1; $in = 0; $env = 0;
        }
        if ($in && !$done) {
          if (/^    environment:\s*$/) { $env = 1; $seen = 1 }
          elsif ($env && !/^      -/) { print "$b\n"; $done = 1; $env = 0 }
        }
      }
      END { print "$b\n" if $env && !$done }
    ' "$compose_yml"
    grep -q 'SPRING_SECURITY_USER_NAME' "$compose_yml" \
      || echo "  WARNING: could not locate the container-signature service — SPRING_SECURITY_USER_* not pinned" >&2
    echo "  Pinned Spring Security creds on container-signature"
  fi

  # Patch container-signature -> stamping baseUrl to the in-network hostname.
  if grep -q '^  baseUrl: http://host.docker.internal:8084/api' "$csig_yml"; then
    sed -i 's#^  baseUrl: http://host.docker.internal:8084/api#  baseUrl: http://dmss-digital-stamping-service:8084/api#' "$csig_yml"
    echo "  Patched dmss-container-and-signature-services/application.yml baseUrl"
  fi

  # Flip STAMP_MODE in config.js to "local" and inject STAMP_LOCAL if missing.
  # Three branches kept distinct for byte-for-byte idempotent re-runs (sed -i
  # always rewrites the file even on no-op, and may flip line endings on MSYS).
  if ! grep -q 'STAMP_MODE' "$config_js"; then
    perl -0777 -i -pe 's/(STAMP_API_URL:)/STAMP_MODE: "local",\n    STAMP_LOCAL: {\n      url: "http:\/\/dmss-container-and-signature-services:8092\/api\/eseal\/document\/profile\/LocalDemo",\n      username: "user",\n      password: "changeit",\n      timeoutMs: 30000\n    },\n    $1/' "$config_js"
    echo "  Inserted STAMP_MODE=local + STAMP_LOCAL in config.js"
  elif grep -q 'STAMP_MODE: *"external"' "$config_js"; then
    sed -i 's/STAMP_MODE: *"external"/STAMP_MODE: "local"/' "$config_js"
    echo "  Set STAMP_MODE to \"local\" in config.js"
  else
    echo "  STAMP_MODE already set to \"local\" in config.js"
  fi

  # Activate compose profile via .env so plain `docker compose up -d` includes it.
  touch "$env_file"
  if ! grep -q '^COMPOSE_PROFILES=' "$env_file"; then
    printf '\nCOMPOSE_PROFILES=local-eseal\n' >>"$env_file"
    echo "  Wrote COMPOSE_PROFILES=local-eseal to .env"
  elif ! grep -q '^COMPOSE_PROFILES=.*local-eseal' "$env_file"; then
    # Operates only on the COMPOSE_PROFILES line: strip a trailing CR first,
    # then either fill an empty value or append. The previous greedy (.*)
    # swallowed a carriage return on a CRLF .env under real GNU sed,
    # producing "COMPOSE_PROFILES=wizard\r,local-eseal".
    sed -i '/^COMPOSE_PROFILES=/ {
      s/\r$//
      s/^COMPOSE_PROFILES=$/COMPOSE_PROFILES=local-eseal/
      t
      s/$/,local-eseal/
    }' "$env_file"
    echo "  Appended local-eseal to existing COMPOSE_PROFILES in .env"
  fi
fi

# --- Optional: disable local e-sealing (--disable-local-eseal) ---
# Reverses STAMP_MODE + .env's COMPOSE_PROFILES only. Deliberately leaves the
# staged demo artefacts and the dmss-digital-stamping-service compose block
# in place (matches the enable path's "never destructive" cp -n philosophy)
# — the container simply won't start once its profile is inactive; the
# caller (toggle-features.sh) is responsible for stopping it if it's
# currently running.
if [[ "$disable_local_eseal" == "true" ]]; then
  env_file="${repo_root}/.env"

  if grep -q 'STAMP_MODE: *"local"' "$config_js"; then
    sed -i 's/STAMP_MODE: *"local"/STAMP_MODE: "external"/' "$config_js"
    echo "  Set STAMP_MODE to \"external\" in config.js"
  else
    echo "  STAMP_MODE already not \"local\" in config.js"
  fi

  if [[ -f "$env_file" ]] && grep -q '^COMPOSE_PROFILES=.*local-eseal' "$env_file"; then
    python3 - "$env_file" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r") as f:
    lines = f.readlines()

out = []
for line in lines:
    if line.startswith("COMPOSE_PROFILES="):
        value = line[len("COMPOSE_PROFILES="):].rstrip("\n")
        items = [v for v in value.split(",") if v and v != "local-eseal"]
        if items:
            out.append("COMPOSE_PROFILES=" + ",".join(items) + "\n")
        # else: every profile was local-eseal — drop the line entirely
        # rather than leave a trailing "COMPOSE_PROFILES=" (an empty value
        # is indistinguishable from "not set" to docker compose, but a
        # dangling key is needless clutter in a file operators will read).
    else:
        out.append(line)

with open(path, "w") as f:
    f.writelines(out)
PY
    echo "  Removed local-eseal from COMPOSE_PROFILES in .env"
  fi
fi

echo "  Configuration complete for ${host}"
