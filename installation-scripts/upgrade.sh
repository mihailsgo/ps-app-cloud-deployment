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
enable_local_eseal=false

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/upgrade.sh [--server-tag X.XX] [--client-tag X.XX] [--enable-local-eseal]

What it does:
  1) Backs up docker-compose.yml and config.js
  2) Updates image tags in docker-compose.yml
  3) Ensures DOCUMENT_ROUTING config exists (disabled by default)
  4) Ensures signed-output volume mount and directory exist
  4b) (--enable-local-eseal only) Materializes the dmss-digital-stamping-service
      assets, appends the gated compose service block, patches the
      container-signature baseUrl, flips STAMP_MODE in config.js to "local",
      and sets COMPOSE_PROFILES=local-eseal in .env so subsequent
      `docker compose up -d` calls automatically include the new service.
  5) Pulls new images and recreates changed containers
  6) Verifies services are running

The --enable-local-eseal flag is idempotent: re-running is safe and only
touches files that haven't already been migrated. To revert, edit
config/config.js (STAMP_MODE: "external"), clear COMPOSE_PROFILES in .env,
and `docker compose up -d ps-server`. See README.md "Enabling local
e-sealing" for full recipe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-tag) server_tag="${2:-}"; shift 2;;
    --client-tag) client_tag="${2:-}"; shift 2;;
    --enable-local-eseal) enable_local_eseal=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$server_tag" && -z "$client_tag" && "$enable_local_eseal" != true ]]; then
  echo "ERROR: Provide at least one of --server-tag, --client-tag, or --enable-local-eseal" >&2
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

# ── Step 4b (optional): Enable local e-sealing ──
if [[ "$enable_local_eseal" == true ]]; then
  echo "Step 4b/6: Enabling local e-sealing..."

  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  assets_src="${scripts_dir}/assets/dmss-digital-stamping-service"
  stamping_dst="${repo_root}/dmss-digital-stamping-service"
  csig_yml="${repo_root}/dmss-container-and-signature-services/application.yml"
  env_file="${repo_root}/.env"

  if [[ ! -d "$assets_src" ]]; then
    echo "ERROR: missing local-eseal assets at $assets_src" >&2
    echo "       Re-pull the deployment repo to fetch installation-scripts/assets/." >&2
    exit 3
  fi

  # 4b.1 — Materialize stamping artifacts (non-destructive: never overwrites
  # files the customer may have already replaced, e.g. their real seal.p12).
  if [[ ! -d "$stamping_dst" ]]; then
    mkdir -p "$stamping_dst/seal"
    cp -n "$assets_src/application.yml"   "$stamping_dst/application.yml"
    cp -n "$assets_src/seal/seal.p12"     "$stamping_dst/seal/seal.p12"
    cp -n "$assets_src/seal/README.md"    "$stamping_dst/seal/README.md"
    echo "  Demo stamping artifacts staged at ./dmss-digital-stamping-service/"
  else
    # Directory exists; just fill any missing files. Never overwrites.
    [[ -f "$stamping_dst/application.yml"     ]] || cp -n "$assets_src/application.yml"   "$stamping_dst/application.yml"
    [[ -f "$stamping_dst/seal/seal.p12"       ]] || { mkdir -p "$stamping_dst/seal"; cp -n "$assets_src/seal/seal.p12" "$stamping_dst/seal/seal.p12"; }
    [[ -f "$stamping_dst/seal/README.md"      ]] || { mkdir -p "$stamping_dst/seal"; cp -n "$assets_src/seal/README.md" "$stamping_dst/seal/README.md"; }
    echo "  Stamping artifacts already present (preserved)"
  fi

  # 4b.2 — Append compose service block if missing.
  if ! grep -q 'dmss-digital-stamping-service' "$compose_yml"; then
    # Insert before the first `networks:` block at column 0 (root mapping).
    # Falls back to appending at EOF if no networks: line is found.
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
    echo "  Compose service block appended (gated by profiles: [local-eseal])"
  else
    echo "  Compose service block already present"
  fi

  # 4b.3 — Patch container-signature baseUrl so it talks to the in-network stamping container.
  if grep -q '^  baseUrl: http://host.docker.internal:8084/api' "$csig_yml"; then
    sed -i 's#^  baseUrl: http://host.docker.internal:8084/api#  baseUrl: http://dmss-digital-stamping-service:8084/api#' "$csig_yml"
    echo "  Patched dmss-container-and-signature-services/application.yml baseUrl"
  else
    echo "  Container-signature baseUrl already patched (or non-default)"
  fi

  # 4b.4 — Pin Spring Security creds on container-signature for stable basic auth.
  if ! grep -q 'SPRING_SECURITY_USER_NAME' "$compose_yml"; then
    sed -i '/image: .trustlynx\/container-signature-service:/i\      - SPRING_SECURITY_USER_NAME=user\n      - SPRING_SECURITY_USER_PASSWORD=changeit' "$compose_yml"
    echo "  Pinned Spring Security creds on container-signature"
  else
    echo "  Spring Security creds already pinned"
  fi

  # 4b.5 — Flip STAMP_MODE in config.js to "local" and ensure STAMP_LOCAL is present.
  # Three branches kept distinct to preserve full byte-for-byte idempotency on
  # re-run: (1) insert if missing, (2) flip if currently external, (3) skip if
  # already local. The skip branch matters because `sed -i` always rewrites the
  # file (even on no-op substitutions) and on MSYS/Git-Bash that rewrite can
  # alter line-endings (CRLF -> LF), tripping change detection in later runs.
  if ! grep -q 'STAMP_MODE' "$config_js"; then
    perl -0777 -i -pe 's/(STAMP_API_URL:)/STAMP_MODE: "local",\n    STAMP_LOCAL: {\n      url: "http:\/\/dmss-container-and-signature-services:8092\/api\/eseal\/document\/profile\/LocalDemo",\n      username: "user",\n      password: "changeit",\n      timeoutMs: 30000\n    },\n    $1/' "$config_js"
    echo "  Inserted STAMP_MODE=local + STAMP_LOCAL in config.js"
  elif grep -q 'STAMP_MODE: *"external"' "$config_js"; then
    sed -i 's/STAMP_MODE: *"external"/STAMP_MODE: "local"/' "$config_js"
    echo "  Flipped STAMP_MODE to \"local\" in config.js"
  else
    echo "  STAMP_MODE already set to \"local\" in config.js"
  fi

  # 4b.6 — Activate compose profile via .env so all subsequent
  # `docker compose up -d` calls auto-include the stamping service.
  touch "$env_file"
  if ! grep -q '^COMPOSE_PROFILES=' "$env_file"; then
    printf '\nCOMPOSE_PROFILES=local-eseal\n' >>"$env_file"
    echo "  Wrote COMPOSE_PROFILES=local-eseal to .env"
  elif ! grep -q '^COMPOSE_PROFILES=.*local-eseal' "$env_file"; then
    sed -i 's/^COMPOSE_PROFILES=\(.*\)$/COMPOSE_PROFILES=\1,local-eseal/' "$env_file"
    echo "  Appended local-eseal to existing COMPOSE_PROFILES in .env"
  else
    echo "  .env already activates local-eseal profile"
  fi
fi

# ── Step 5: Pull and restart ──
echo "Step 5/6: Pulling images and restarting..."
cd "$repo_root"
services=""
[[ -n "$server_tag" ]] && services="$services ps-server"
[[ -n "$client_tag" ]] && services="$services ps-client"
if [[ "$enable_local_eseal" == true ]]; then
  # Pull / start the stamping service alongside any tagged images.
  services="$services dmss-digital-stamping-service"
fi
# .env now carries COMPOSE_PROFILES if applicable, so plain `docker compose`
# picks the profile up automatically.
docker compose pull $services
docker compose up -d $services
if [[ "$enable_local_eseal" == true ]]; then
  # container-signature needs to be restarted to pick up the new
  # SPRING_SECURITY_USER_* env vars and the patched baseUrl, and ps-server to
  # re-read config.js. These restarts are cheap and intentional.
  docker compose up -d dmss-container-and-signature-services ps-server
fi

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
