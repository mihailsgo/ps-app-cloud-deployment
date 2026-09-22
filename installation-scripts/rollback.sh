#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Rollback — restore the image tags + config.js an upgrade.sh run had
# in place immediately before it ran.
#
# Usage:
#   ./installation-scripts/rollback.sh [--to latest|<snapshot-dir-name>] [--yes]
#
# What this restores (and nothing else):
#   - docker-compose.yml's ps-server/ps-client image TAG lines only (a
#     targeted sed, not a wholesale file overwrite - so any unrelated
#     docker-compose.yml edit made after the snapshot, e.g. a
#     configure-host.sh --enable-local-eseal block, survives)
#   - config/config.js, restored verbatim from the snapshot
#
# What this NEVER touches:
#   - signed-output/ or docs/ (document storage)
#   - nginx/nginx.conf or config/constants.json (configure-host.sh's
#     "environment overlay" - hostname, TLS paths, DEMO_MODE, redirect URIs)
#   - Keycloak admin credentials / realm state
#
# Idempotent: running this twice in a row against the same snapshot is a
# no-op the second time (the tag sed matches nothing to change, config.js
# copy is byte-identical).
#
# Exit codes:
#   0  rollback applied (or already at the target state)
#   1  rollback failed
#   2  argument error / no snapshot found
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"
compose_yml="${repo_root}/docker-compose.yml"
config_js="${repo_root}/config/config.js"
# shellcheck source=lib/rollback-snapshot.sh
. "${scripts_dir}/lib/rollback-snapshot.sh"
# shellcheck source=lib/deployment-evidence.sh
. "${scripts_dir}/lib/deployment-evidence.sh"

target_ref="latest"
assume_yes="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/rollback.sh [--to latest|<snapshot-dir-name>] [--yes]

  --to    Which snapshot to restore. Defaults to 'latest' (the most recent
          upgrade.sh run). Snapshot names are timestamps under the repo
          root's .rollback-snapshots/ (gitignored) - list them with:
            ls .rollback-snapshots/
  --yes   Skip the confirmation prompt (for non-interactive use).

This restores the image tags and config/config.js exactly as they were
immediately before the chosen upgrade.sh run. It does not touch
signed-output/, docs/, nginx/nginx.conf, or config/constants.json.

If configure-host.sh, toggle-features.sh, or another upgrade.sh ran AFTER
the snapshot you're restoring, whatever those changed to config/config.js
will be reverted too - this script only knows about the one snapshot it's
restoring, not everything that happened since.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) target_ref="${2:-}"; shift 2;;
    --yes) assume_yes="true"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

snap_dir="$(resolve_rollback_snapshot "$target_ref")" || {
  echo "ERROR: No usable rollback snapshot found for '--to ${target_ref}'." >&2
  echo "       Snapshots are written by upgrade.sh before each run. None exist yet if upgrade.sh has never run." >&2
  exit 2
}

# Path passed via env var, not interpolated into the -c string: keeps this
# safe regardless of what characters end up in a path, and (found by testing
# on Windows/Git Bash) env-var values reliably reach python's file APIs in a
# form it can open, where a path embedded directly in a -c argument string
# did not.
manifest_json="$(MANIFEST_PATH="${snap_dir}/manifest.json" python3 -c "
import json, os
with open(os.environ['MANIFEST_PATH'], encoding='utf-8') as fh:
    print(json.dumps(json.load(fh)))
" 2>/dev/null || echo "{}")"
manifest_server_tag="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('image_tags',{}).get('ps-server') or '')" 2>/dev/null || echo "")"
manifest_client_tag="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('image_tags',{}).get('ps-client') or '')" 2>/dev/null || echo "")"
taken_at="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('taken_at') or '')" 2>/dev/null || echo "")"

current_server_tag="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "$compose_yml" 2>/dev/null | head -1)"
current_client_tag="$(sed -nE 's|.*mihailsgordijenko/ps-client:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "$compose_yml" 2>/dev/null | head -1)"

echo "PadSign Rollback"
echo "================================"
echo "Snapshot:        ${snap_dir}"
echo "Snapshot taken:  ${taken_at}"
echo ""
echo "  ps-server: ${current_server_tag:-unknown} -> ${manifest_server_tag:-<unchanged>}"
echo "  ps-client: ${current_client_tag:-unknown} -> ${manifest_client_tag:-<unchanged>}"
echo ""
echo "This restores docker-compose.yml's image tags and config/config.js to"
echo "their state immediately before that upgrade.sh run. It never touches"
echo "signed-output/, docs/, nginx/nginx.conf, or config/constants.json."
echo ""

if [[ "$assume_yes" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    echo "ERROR: No interactive terminal attached - pass --yes to run non-interactively." >&2
    exit 2
  fi
  confirm=""
  read -r -p "Proceed? [y/N] " confirm || true
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
echo "Step 1/3: Restoring image tags in docker-compose.yml..."
if [[ -n "$manifest_server_tag" ]]; then
  sed -i "s|mihailsgordijenko/ps-server:[0-9.]*|mihailsgordijenko/ps-server:${manifest_server_tag}|" "$compose_yml"
  echo "  ps-server -> ${manifest_server_tag}"
fi
if [[ -n "$manifest_client_tag" ]]; then
  sed -i "s|mihailsgordijenko/ps-client:[0-9.]*|mihailsgordijenko/ps-client:${manifest_client_tag}|" "$compose_yml"
  echo "  ps-client -> ${manifest_client_tag}"
fi

echo "Step 2/3: Restoring config/config.js from snapshot..."
cp -f "${snap_dir}/config.js" "$config_js"
echo "  Restored"

echo "Step 3/3: Pulling and restarting..."
cd "$repo_root"
services=""
[[ -n "$manifest_server_tag" ]] && services="$services ps-server"
[[ -n "$manifest_client_tag" ]] && services="$services ps-client"
if [[ -n "$services" ]]; then
  docker compose pull $services
  docker compose up -d $services
fi
docker compose restart nginx 2>/dev/null || true

echo "  Waiting for rolled-back services to report healthy..."
for i in $(seq 1 30); do
  all_healthy=true
  for svc in $services; do
    cid="$(docker compose ps -q "$svc" 2>/dev/null || echo "")"
    [[ -z "$cid" ]] && { all_healthy=false; break; }
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "$cid" 2>/dev/null || echo "unknown")"
    [[ "$health" != "healthy" ]] && all_healthy=false
  done
  if [[ "$all_healthy" == "true" ]]; then
    echo "  Rolled-back services are healthy."
    break
  fi
  sleep 2
  if [[ "$i" == "30" ]]; then
    echo "  WARNING: rolled-back services did not report healthy within 60s. Check: docker compose ps" >&2
  fi
done

write_deployment_evidence "rollback.sh"

echo ""
echo "================================"
echo "Rollback complete."
