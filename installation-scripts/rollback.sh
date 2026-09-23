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
#   - docker-compose.yml's ps-server/ps-client image lines only (a targeted
#     sed, not a wholesale file overwrite - so any unrelated docker-compose.yml
#     edit made after the snapshot, e.g. a configure-host.sh
#     --enable-local-eseal block, survives). Restores tag@digest when the
#     snapshot's manifest.json recorded a digest (every snapshot since
#     psapp-saas#11 does); falls back to a bare tag, with a re-pin reminder,
#     for older snapshots that predate digest recording.
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
#   0  rollback applied (or already at the target state) and the restored
#      services are healthy
#   1  rollback failed, or the restored services did not become healthy
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
# shellcheck source=lib/health-wait.sh
. "${scripts_dir}/lib/health-wait.sh"

target_ref="latest"
assume_yes="false"
health_timeout=300

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/rollback.sh [--to latest|<snapshot-dir-name>] [--yes]

  --to    Which snapshot to restore. Defaults to 'latest' (the most recent
          upgrade.sh run). Snapshot names are timestamps under the repo
          root's .rollback-snapshots/ (gitignored) - list them with:
            ls .rollback-snapshots/
  --yes   Skip the confirmation prompt (for non-interactive use).
  --health-timeout N
          Seconds to wait for the restored services to be healthy
          (default 300). The rollback exits 1 if they are not.

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
    --health-timeout) health_timeout="${2:-}"; shift 2;;
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
# Recorded by write_rollback_snapshot() (lib/rollback-snapshot.sh) via
# `docker inspect --format '{{.Image}}'` on the pre-upgrade container - this
# is the exact content digest that was running, independent of whether
# docker-compose.yml pinned by digest at snapshot time. Empty for snapshots
# taken before this field existed.
manifest_server_digest="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('image_digests',{}).get('ps-server') or '')" 2>/dev/null || echo "")"
manifest_client_digest="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('image_digests',{}).get('ps-client') or '')" 2>/dev/null || echo "")"
taken_at="$(MANIFEST_JSON="$manifest_json" python3 -c "import json,os;print(json.loads(os.environ['MANIFEST_JSON']).get('taken_at') or '')" 2>/dev/null || echo "")"

current_server_tag="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "$compose_yml" 2>/dev/null | head -1)"
current_client_tag="$(sed -nE 's|.*mihailsgordijenko/ps-client:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "$compose_yml" 2>/dev/null | head -1)"

echo "PadSign Rollback"
echo "================================"
echo "Snapshot:        ${snap_dir}"
echo "Snapshot taken:  ${taken_at}"
echo ""
echo "  ps-server: ${current_server_tag:-unknown} -> ${manifest_server_tag:-<unchanged>}${manifest_server_digest:+@${manifest_server_digest}}"
echo "  ps-client: ${current_client_tag:-unknown} -> ${manifest_client_tag:-<unchanged>}${manifest_client_digest:+@${manifest_client_digest}}"
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
# -E and the trailing (@sha256:[0-9a-f]+)? deliberately strip whatever digest
# is CURRENTLY pinned before writing the new reference - that digest belongs
# to the tag being rolled back FROM, not the one being rolled back TO.
# Carrying it forward would silently pin the restored tag to the wrong
# content (the same bug fixed in upgrade.sh's Step 2 for the same reason).
if [[ -n "$manifest_server_tag" ]]; then
  if [[ -n "$manifest_server_digest" ]]; then
    sed -i -E "s|mihailsgordijenko/ps-server:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-server:${manifest_server_tag}@${manifest_server_digest}|" "$compose_yml"
    echo "  ps-server -> ${manifest_server_tag}@${manifest_server_digest}"
  else
    sed -i -E "s|mihailsgordijenko/ps-server:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-server:${manifest_server_tag}|" "$compose_yml"
    echo "  ps-server -> ${manifest_server_tag} (no digest in this snapshot - re-pin manually, see documentation/39-release-procedure.md)"
  fi
fi
if [[ -n "$manifest_client_tag" ]]; then
  if [[ -n "$manifest_client_digest" ]]; then
    sed -i -E "s|mihailsgordijenko/ps-client:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-client:${manifest_client_tag}@${manifest_client_digest}|" "$compose_yml"
    echo "  ps-client -> ${manifest_client_tag}@${manifest_client_digest}"
  else
    sed -i -E "s|mihailsgordijenko/ps-client:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-client:${manifest_client_tag}|" "$compose_yml"
    echo "  ps-client -> ${manifest_client_tag} (no digest in this snapshot - re-pin manually, see documentation/39-release-procedure.md)"
  fi
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

echo "  Waiting for rolled-back services to report healthy (up to ${health_timeout}s)..."
# shellcheck disable=SC2086 # word-splitting the service list is intended
if ! wait_for_healthy "$health_timeout" $services nginx; then
  write_deployment_evidence "rollback.sh (unhealthy)" || true
  echo "" >&2
  echo "ROLLBACK APPLIED BUT NOT HEALTHY: the restored configuration is in place," >&2
  echo "but the services above did not become healthy. Check: docker compose ps" >&2
  exit 1
fi
echo "  Rolled-back services are healthy."

write_deployment_evidence "rollback.sh"

echo ""
echo "================================"
echo "Rollback complete."
