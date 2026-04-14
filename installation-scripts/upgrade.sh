#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Upgrade — update image tags and apply latest config patterns
#
# Usage:
#   ./installation-scripts/upgrade.sh --server-tag 3.22 --client-tag 8.34
#   ./installation-scripts/upgrade.sh --server-tag 3.22   # server only
#   ./installation-scripts/upgrade.sh --client-tag 8.34   # client only
# ============================================================================

server_tag=""
client_tag=""

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/upgrade.sh [--server-tag X.XX] [--client-tag X.XX]

What it does:
  1) Backs up docker-compose.yml and config.js
  2) Updates image tags in docker-compose.yml
  3) Ensures DOCUMENT_ROUTING config exists (disabled by default)
  4) Ensures signed-output volume mount and directory exist
  5) Ensures nginx root redirects to /portal/
  6) Pulls new images and recreates changed containers
  7) Verifies services are running
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-tag) server_tag="${2:-}"; shift 2;;
    --client-tag) client_tag="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$server_tag" && -z "$client_tag" ]]; then
  echo "ERROR: Provide at least one of --server-tag or --client-tag" >&2
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_yml="${repo_root}/docker-compose.yml"
config_js="${repo_root}/config/config.js"
nginx_conf="${repo_root}/nginx/nginx.conf"

echo "========================================"
echo "PadSign Upgrade"
[[ -n "$server_tag" ]] && echo "  ps-server: → ${server_tag}"
[[ -n "$client_tag" ]] && echo "  ps-client: → ${client_tag}"
echo "========================================"
echo ""

# ── Step 1: Backup ──
echo "Step 1/6: Backing up..."
cp -f "$compose_yml" "${compose_yml}.bak"
cp -f "$config_js" "${config_js}.bak"
echo "  Backups created"

# ── Step 2: Update image tags ──
echo "Step 2/6: Updating image tags..."
if [[ -n "$server_tag" ]]; then
  old_server="$(grep -oP 'mihailsgordijenko/ps-server:\K[0-9.]+' "$compose_yml" || echo "unknown")"
  sed -i "s|mihailsgordijenko/ps-server:[0-9.]*|mihailsgordijenko/ps-server:${server_tag}|" "$compose_yml"
  echo "  ps-server: ${old_server} → ${server_tag}"
fi
if [[ -n "$client_tag" ]]; then
  old_client="$(grep -oP 'mihailsgordijenko/ps-client:\K[0-9.]+' "$compose_yml" || echo "unknown")"
  sed -i "s|mihailsgordijenko/ps-client:[0-9.]*|mihailsgordijenko/ps-client:${client_tag}|" "$compose_yml"
  echo "  ps-client: ${old_client} → ${client_tag}"
fi

# ── Step 3: Ensure DOCUMENT_ROUTING ──
echo "Step 3/6: Ensuring DOCUMENT_ROUTING config..."
if ! grep -q 'DOCUMENT_ROUTING' "$config_js"; then
  perl -0777 -i -pe 's/(\n\};)$/\n\n    \/\/ Document Routing (post-signing actions) - disabled by default\n    DOCUMENT_ROUTING: {\n      enabled: false,\n      skipDemo: true,\n      strategies: [\n        {\n          type: "filesystem",\n          enabled: false,\n          basePath: "\/signed-output",\n          pathTemplate: "{company}\/{date:YYYY-MM}\/{company}_{clientName}_{date:YYYY-MM-DD_HHmm}.pdf",\n          createDirectories: true\n        },\n        {\n          type: "webhook",\n          enabled: false,\n          url: "https:\/\/example.com\/api\/signing-status",\n          method: "POST",\n          headers: {},\n          includeFile: false,\n          timeoutMs: 10000,\n          retries: 3,\n          retryBaseDelayMs: 1000\n        }\n      ]\n    },\n};/' "$config_js"
  echo "  Added DOCUMENT_ROUTING (disabled)"
else
  echo "  DOCUMENT_ROUTING already present"
fi

# ── Step 4: Ensure signed-output volume + directory ──
echo "Step 4/6: Ensuring signed-output volume..."
if ! grep -q 'signed-output:/signed-output' "$compose_yml"; then
  sed -i '/config\/config\.js:\/usr\/src\/app\/config\.js/a\      - "./signed-output:/signed-output"' "$compose_yml"
  echo "  Added volume mount"
else
  echo "  Volume mount already present"
fi
mkdir -p "${repo_root}/signed-output"
chmod 777 "${repo_root}/signed-output" 2>/dev/null || true

# ── Step 5: Pull and restart ──
echo "Step 5/6: Pulling images and restarting..."
cd "$repo_root"
services=""
[[ -n "$server_tag" ]] && services="$services ps-server"
[[ -n "$client_tag" ]] && services="$services ps-client"
docker compose pull $services
docker compose up -d $services

# Also restart nginx to pick up any config changes
docker compose restart nginx 2>/dev/null || true
sleep 3

# ── Step 6: Verify ──
echo "Step 6/6: Verifying..."
echo ""
echo "  Running containers:"
docker ps --format '  {{.Names}}: {{.Image}} ({{.Status}})' | grep -E 'ps-server|ps-client|nginx' | sort

# Health check
if docker compose logs ps-server 2>/dev/null | grep -q "PadSign Server listening"; then
  echo ""
  echo "  ps-server: OK"
else
  echo ""
  echo "  WARNING: ps-server may not have started. Check: docker compose logs ps-server" >&2
fi

echo ""
echo "========================================"
echo "Upgrade complete!"
echo "  Rollback: cp docker-compose.yml.bak docker-compose.yml && cp config/config.js.bak config/config.js && docker compose up -d"
echo "========================================"
