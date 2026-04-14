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
ok()  { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=1; }

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

if docker compose -f "${repo_root}/docker-compose.yml" config > /dev/null 2>&1; then
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

if [[ -d "${repo_root}/signed-output" ]]; then
  ok "signed-output directory exists"
else
  bad "signed-output directory missing (create with: mkdir -p signed-output)"
fi

# --- Nginx redirect ---
if grep -q 'return 301.*portal' "${repo_root}/nginx/nginx.conf"; then
  ok "nginx root→/portal/ redirect configured"
else
  bad "nginx root→/portal/ redirect missing"
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

# Check if README release snapshot matches (if README exists)
if [[ -f "${repo_root}/README.md" ]]; then
  readme_server="$(grep -oP 'ps-server:\s*\`mihailsgordijenko/ps-server:\K[0-9.]+' "${repo_root}/README.md" 2>/dev/null || echo "")"
  if [[ -n "$readme_server" && "$readme_server" != "$server_tag" ]]; then
    bad "README release snapshot ps-server (${readme_server}) != docker-compose (${server_tag})"
  fi
  readme_client="$(grep -oP 'ps-client:\s*\`mihailsgordijenko/ps-client:\K[0-9.]+' "${repo_root}/README.md" 2>/dev/null || echo "")"
  if [[ -n "$readme_client" && "$readme_client" != "$client_tag" ]]; then
    bad "README release snapshot ps-client (${readme_client}) != docker-compose (${client_tag})"
  fi
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
