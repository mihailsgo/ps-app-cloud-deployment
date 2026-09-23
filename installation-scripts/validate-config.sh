#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Config Validator — checks syntax and consistency of all config files
#
# Usage:
#   ./installation-scripts/validate-config.sh [--host example.com]
# ============================================================================

host=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    -h|--help) echo "Usage: $0 [--host example.com]"; exit 0;;
    *) shift;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  WARN %s\n' "$*"; }

# The EFFECTIVE compose model: run from the project directory without -f, so
# .env's COMPOSE_FILE (an environment overlay, see installation-scripts/
# overlay.sh), COMPOSE_PROFILES and COMPOSE_PROJECT_NAME apply exactly as they
# do for `docker compose up`. `-f docker-compose.yml` would silently skip an
# overlay file - including any port it publishes, which is precisely what the
# port-binding check below exists to catch.
compose_config() {
  (cd "$repo_root" && docker compose config "$@")
}

echo "PadSign Configuration Validator"
echo "================================"

# --- File existence ---
echo ""
echo "File checks:"
for f in config/config.js config/constants.json nginx/nginx.conf docker-compose.yml; do
  if [[ -f "${repo_root}/${f}" ]]; then
    ok "$f exists"
  else
    bad "$f missing"
  fi
done

# --- JSON syntax ---
echo ""
echo "Syntax checks:"
if python3 -m json.tool "${repo_root}/config/constants.json" > /dev/null 2>&1; then
  ok "constants.json is valid JSON"
else
  bad "constants.json is invalid JSON"
fi

if compose_config > /dev/null 2>&1; then
  ok "docker-compose.yml is valid"
else
  bad "docker-compose.yml has errors"
fi

# --- DOCUMENT_ROUTING ---
echo ""
echo "Feature checks:"
if grep -q 'DOCUMENT_ROUTING' "${repo_root}/config/config.js"; then
  ok "DOCUMENT_ROUTING present in config.js"
else
  bad "DOCUMENT_ROUTING missing from config.js"
fi

if grep -q 'signed-output:/signed-output' "${repo_root}/docker-compose.yml"; then
  ok "signed-output volume mount in docker-compose.yml"
else
  bad "signed-output volume mount missing from docker-compose.yml"
fi

# Where the signed-document stores actually are. Normally the in-tree
# ./signed-output and ./docs, but an environment overlay (overlay.sh) points
# them at the documents' existing location instead of moving the data.
signed_output_dir="${repo_root}/signed-output"
docs_dir="${repo_root}/docs"
storage_sources="$(compose_config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    services = json.load(sys.stdin).get("services") or {}
except Exception:
    sys.exit(0)
want = {("ps-server", "/signed-output"), ("dmss-archive-services-fallback", "/docs")}
for name, svc in services.items():
    for v in svc.get("volumes") or []:
        if (name, v.get("target")) in want and v.get("type") == "bind" and v.get("source"):
            print(v["target"] + "\t" + v["source"])
' 2>/dev/null | tr -d '\r' || true)"
while IFS=$'\t' read -r tgt src; do
  case "$tgt" in
    /signed-output) signed_output_dir="$src";;
    /docs) docs_dir="$src";;
  esac
done <<< "$storage_sources"
if [[ "$signed_output_dir" != "${repo_root}/signed-output" ]]; then
  ok "signed-output is mounted from ${signed_output_dir} (environment overlay)"
fi
if [[ "$docs_dir" != "${repo_root}/docs" ]]; then
  ok "docs is mounted from ${docs_dir} (environment overlay)"
fi

world_writable() {
  # Matches if "other" has the write bit set, portable across GNU/BSD find.
  find "$1" -maxdepth 0 -perm -002 2>/dev/null | grep -q .
}

if [[ -d "${signed_output_dir}" ]]; then
  ok "signed-output directory exists"
  if world_writable "${signed_output_dir}"; then
    bad "signed-output directory is world-writable ($(stat -c '%a' "${signed_output_dir}" 2>/dev/null || stat -f '%Lp' "${signed_output_dir}" 2>/dev/null)). ps-server writes here as root and does not need this; fix: chmod 750 signed-output"
  else
    ok "signed-output directory is not world-writable"
  fi
else
  bad "signed-output directory missing (create with: mkdir -p signed-output && chmod 750 signed-output)"
fi

if [[ -d "${docs_dir}" ]]; then
  if [[ -w "${docs_dir}" ]]; then
    ok "docs directory exists and is writable"
  else
    bad "docs directory exists but is NOT writable (dmss-archive-services-fallback writes here as its 'spring' user). Fix: chgrp <spring's gid> docs && chmod 770 docs — see installation-scripts/lib/dir-permissions.sh. If that also fails, Docker likely auto-created it as root on an earlier 'docker compose up'; use sudo."
  fi
  if world_writable "${docs_dir}"; then
    bad "docs directory is world-writable ($(stat -c '%a' "${docs_dir}" 2>/dev/null || stat -f '%Lp' "${docs_dir}" 2>/dev/null)). Fix: chgrp <spring's gid> docs && chmod 770 docs — see installation-scripts/lib/dir-permissions.sh"
  else
    ok "docs directory is not world-writable"
  fi
else
  bad "docs directory missing (create with: mkdir -p docs — then see installation-scripts/lib/dir-permissions.sh for the correct group/mode)"
fi

# --- Secret hygiene (psapp-saas#6, #7) ---
# Nothing here prints a secret value - only field names and file modes.
echo ""
echo "Secret hygiene:"
config_js="${repo_root}/config/config.js"

# ps-server's apiProtect logs the raw Authorization header, the bearer token
# and its decoded payload when this flag is on (psapp server/app.js). A token
# in `docker logs` is a replayable credential until it expires.
if grep -Eq '^[[:space:]]*API_PROTECT_LOGS_ENABLED[[:space:]]*:[[:space:]]*true' "$config_js"; then
  bad "API_PROTECT_LOGS_ENABLED is true in config/config.js - ps-server then writes raw bearer tokens and token payloads to its log. Set it to false and restart ps-server."
else
  ok "API_PROTECT_LOGS_ENABLED is off (no bearer tokens in ps-server logs)"
fi

# Values shipped in this PUBLIC repository are known to everyone. Compared
# against the release's own committed config.js (what this checkout was cut
# from), so this script never has to carry a copy of the values itself.
known_default_fields() {
  BASELINE_JS="$(git -C "$repo_root" show HEAD:config/config.js)" python3 -c '
import os, re, sys
FIELDS = [
    ("backend client secret (KEYCLOAK_CONFIG.credentials.secret)", r"\"secret\"\s*:\s*\"([^\"]*)\""),
    ("REGISTER_PDF_API_KEY", r"REGISTER_PDF_API_KEY\s*:\s*[\"\x27]([^\"\x27]*)[\"\x27]"),
    ("SESSION_SECRET", r"SESSION_SECRET\s*:\s*[\"\x27]([^\"\x27]*)[\"\x27]"),
    ("STAMP_API_KEY", r"STAMP_API_KEY\s*:\s*[\"\x27]([^\"\x27]*)[\"\x27]"),
    ("STAMP_COMPANY_SECRET", r"STAMP_COMPANY_SECRET\s*:\s*[\"\x27]([^\"\x27]*)[\"\x27]"),
]
live = open(sys.argv[1], encoding="utf-8", errors="replace").read()
base = os.environ["BASELINE_JS"]
for label, rx in FIELDS:
    ml, mb = re.search(rx, live), re.search(rx, base)
    if ml and mb and ml.group(1) and ml.group(1) == mb.group(1):
        print(label)
' "$config_js" 2>/dev/null | tr -d '\r'
}
if git -C "$repo_root" cat-file -e HEAD:config/config.js 2>/dev/null; then
  known_default_report="$(known_default_fields || true)"
  if [[ -z "$known_default_report" ]]; then
    ok "no config.js credential still equals the value shipped in the repository"
  else
    while IFS= read -r field; do
      [[ -z "$field" ]] && continue
      warn "${field} is still the value shipped in the public repository - rotate it (value not shown)"
    done <<< "$known_default_report"
  fi
else
  warn "cannot compare config.js credentials to the shipped defaults (not a git checkout)"
fi
if grep -Eq '^[[:space:]]*-[[:space:]]*KEYCLOAK_ADMIN_PASSWORD=admin[[:space:]]*$' "${repo_root}/docker-compose.yml"; then
  warn "docker-compose.yml still carries KEYCLOAK_ADMIN_PASSWORD=admin (used only on Keycloak's first boot against an empty volume - see documentation/14-07)"
fi

file_mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
world_readable() { find "$1" -maxdepth 0 -perm -004 2>/dev/null | grep -q .; }
for f in config/config.js .env; do
  [[ -f "${repo_root}/${f}" ]] || continue
  if world_readable "${repo_root}/${f}"; then
    warn "${f} is world-readable (mode $(file_mode_of "${repo_root}/${f}")) and holds credentials - chmod o-rwx ${f} (ps-server runs as root and still reads it)"
  else
    ok "${f} is not world-readable"
  fi
done
for f in "${repo_root}"/nginx/certs/*.key; do
  [[ -f "$f" ]] || continue
  if world_readable "$f"; then
    bad "nginx/certs/$(basename "$f") is world-readable (mode $(file_mode_of "$f")) - chmod 600 it"
  else
    ok "nginx/certs/$(basename "$f") is not world-readable"
  fi
done

# --- Nginx redirect ---
if grep -q 'return 301.*portal' "${repo_root}/nginx/nginx.conf"; then
  ok "nginx root→/portal/ redirect configured"
else
  bad "nginx root→/portal/ redirect missing"
fi

# --- Port bindings (psapp-saas#13) ---
# Internal services must never bind to a non-loopback host interface — nginx is
# the only intended public ingress. A service is allowed to publish on all
# interfaces only if it's on this allow-list (documented exception); everything
# else, including any future service someone adds here, must be loopback-only
# or have no host port mapping at all.
echo ""
echo "Port bindings:"
declare -A PORT_ALLOWLIST_NONLOOPBACK=(
  [nginx]="public HTTPS/HTTP ingress — the only intended entrypoint"
  [wizard]="opt-in, profile-gated deployment UI; own HTTPS+token controls, see documentation/36-05"
)

port_config_json="$(compose_config --format json 2>/dev/null || echo "")"
if [[ -z "$port_config_json" ]]; then
  bad "could not render docker-compose.yml via 'docker compose config --format json' to check port bindings"
else
  port_report="$(python3 -c "
import json, sys
data = json.load(sys.stdin)
for name, svc in sorted((data.get('services') or {}).items()):
    for p in (svc.get('ports') or []):
        host_ip = p.get('host_ip') or ''
        published = p.get('published') or ''
        target = p.get('target', '')
        loopback = host_ip in ('127.0.0.1', '::1')
        print(f'{name}\t{host_ip}\t{published}\t{target}\t{1 if loopback else 0}')
" <<< "$port_config_json" 2>/dev/null | tr -d '\r')"

  if [[ -z "$port_report" ]]; then
    ok "no services publish a host port"
  else
    while IFS=$'\t' read -r svc host_ip published target loopback; do
      [[ -z "$svc" ]] && continue
      if [[ "$loopback" == "1" ]]; then
        ok "${svc}: host port ${published} bound to ${host_ip} (loopback-only)"
      elif [[ -n "${PORT_ALLOWLIST_NONLOOPBACK[$svc]:-}" ]]; then
        ok "${svc}: host port ${published} bound to all interfaces (allow-listed: ${PORT_ALLOWLIST_NONLOOPBACK[$svc]})"
      else
        bad "${svc}: host port ${published} (-> ${target}) bound to ${host_ip:-all interfaces (0.0.0.0/::)} — internal services must be loopback-only or unpublished unless added to the allow-list in this script with a documented reason"
      fi
    done <<< "$port_report"
  fi
fi

# --- Hostname consistency (if --host provided) ---
if [[ -n "$host" ]]; then
  echo ""
  echo "Hostname consistency (${host}):"

  if grep -q "server_name ${host}" "${repo_root}/nginx/nginx.conf"; then
    ok "nginx server_name matches"
  else
    bad "nginx server_name does not match '${host}'"
  fi

  if grep -q "\"KEYCLOAK_URL\": \"https://${host}/auth\"" "${repo_root}/config/constants.json" 2>/dev/null || \
     python3 -c "import json; d=json.load(open('${repo_root}/config/constants.json')); exit(0 if d.get('KEYCLOAK_URL')=='https://${host}/auth' else 1)" 2>/dev/null; then
    ok "constants.json KEYCLOAK_URL matches"
  else
    bad "constants.json KEYCLOAK_URL does not match 'https://${host}/auth'"
  fi

  if grep -q "https://${host}/auth" "${repo_root}/config/config.js"; then
    ok "config.js auth-server-url matches"
  else
    bad "config.js auth-server-url does not match 'https://${host}/auth'"
  fi
fi

# --- Image tag consistency ---
echo ""
echo "Image tags:"
server_tag="$(grep -oP 'mihailsgordijenko/ps-server:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "not found")"
client_tag="$(grep -oP 'mihailsgordijenko/ps-client:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "not found")"
ok "ps-server: ${server_tag}"
ok "ps-client: ${client_tag}"

# Check that the release snapshot doc matches (if present)
snapshot_doc="${repo_root}/documentation/01-release-snapshot.md"
if [[ -f "$snapshot_doc" ]]; then
  snap_server="$(grep -oPm1 'mihailsgordijenko/ps-server:\K[0-9.]+' "$snapshot_doc" 2>/dev/null || echo "")"
  if [[ -n "$snap_server" && "$snap_server" != "$server_tag" ]]; then
    bad "Release snapshot ps-server (${snap_server}) != docker-compose (${server_tag})"
  fi
  snap_client="$(grep -oPm1 'mihailsgordijenko/ps-client:\K[0-9.]+' "$snapshot_doc" 2>/dev/null || echo "")"
  if [[ -n "$snap_client" && "$snap_client" != "$client_tag" ]]; then
    bad "Release snapshot ps-client (${snap_client}) != docker-compose (${client_tag})"
  fi
fi

# --- Image digest pinning ---
# Every image docker-compose.yml references must be pinned by immutable
# sha256 digest, and that digest must match what release/approved-digests.json
# records as reviewed — a tag-only pin or a digest that doesn't match the
# registry both fail here. See documentation/39-release-procedure.md.
echo ""
echo "Image digest pinning:"
# shellcheck source=lib/digests.sh
. "${repo_root}/installation-scripts/lib/digests.sh"

if [[ ! -f "$digests_json" ]]; then
  bad "release/approved-digests.json missing — no image digests can be verified"
else
  while IFS=$'\t' read -r image_key repository _tag approved_digest; do
    [[ -z "$image_key" ]] && continue
    approved_digest="${approved_digest%$'\r'}"
    pinned="$(digest_from_compose "$repository")"

    if [[ -z "$pinned" ]]; then
      bad "${image_key}: ${repository} not found in docker-compose.yml"
    elif [[ "$pinned" != *"@sha256:"* ]]; then
      bad "${image_key}: pinned by tag only (${repository}:${pinned}), no immutable digest"
    else
      pinned_digest="${pinned#*@}"
      if [[ "$pinned_digest" == "$approved_digest" ]]; then
        ok "${image_key}: digest-pinned and matches release/approved-digests.json"
      else
        bad "${image_key}: pinned digest (${pinned_digest}) does not match the approved digest in release/approved-digests.json (${approved_digest}) — unapproved digest"
      fi
    fi
  done < <(digest_registry_table)
fi

# --- Running container checks (if Docker is available) ---
if docker ps > /dev/null 2>&1; then
  echo ""
  echo "Container checks:"
  running_server="$(docker ps --filter name=ps-server --format '{{.Image}}' 2>/dev/null || echo "")"
  running_client="$(docker ps --filter name=ps-client --format '{{.Image}}' 2>/dev/null || echo "")"

  if [[ -n "$running_server" ]]; then
    if echo "$running_server" | grep -q "$server_tag"; then
      ok "ps-server running correct tag (${server_tag})"
    else
      bad "ps-server running ${running_server}, expected ${server_tag}"
    fi
  else
    bad "ps-server not running"
  fi

  if [[ -n "$running_client" ]]; then
    if echo "$running_client" | grep -q "$client_tag"; then
      ok "ps-client running correct tag (${client_tag})"
    else
      bad "ps-client running ${running_client}, expected ${client_tag}"
    fi
  else
    bad "ps-client not running"
  fi
fi

# --- Summary ---
echo ""
echo "================================"
if [[ "$fail" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
else
  echo "Some checks FAILED. Review above."
  exit 1
fi
