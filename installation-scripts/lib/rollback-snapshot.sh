# shellcheck shell=bash
#
# Timestamped pre-upgrade snapshots that rollback.sh restores from.
#
# upgrade.sh is the only script that calls write_rollback_snapshot(), and it
# does so BEFORE it mutates anything. Each snapshot is its own directory
# (never overwritten, unlike the single-generation docker-compose.yml.bak /
# config.js.bak upgrade.sh has always kept) containing exact copies of the
# two files upgrade.sh actually mutates - nothing from configure-host.sh's
# territory (nginx.conf, constants.json) is ever snapshotted or restored
# here, by design: that's the "environment overlay" rollback must not touch.
#
# Expects "$repo_root" to be set by the sourcing script.

ROLLBACK_SNAPSHOTS_DIR_NAME=".rollback-snapshots"
ROLLBACK_SNAPSHOTS_KEEP=5

# write_rollback_snapshot
#
# Captures docker-compose.yml + config/config.js as they are RIGHT NOW (i.e.
# call this before any mutation), plus a manifest recording the current
# image tags/digests and the deployment repo's git revision. Updates the
# "latest" pointer file and prunes snapshots beyond ROLLBACK_SNAPSHOTS_KEEP.
#
# Prints the snapshot directory path on stdout.
write_rollback_snapshot() {
  local snapshots_root="${repo_root}/${ROLLBACK_SNAPSHOTS_DIR_NAME}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local snap_dir="${snapshots_root}/${stamp}"

  mkdir -p "$snap_dir"
  cp -f "${repo_root}/docker-compose.yml" "${snap_dir}/docker-compose.yml"
  cp -f "${repo_root}/config/config.js" "${snap_dir}/config.js"

  local server_tag client_tag
  server_tag="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1)"
  client_tag="$(sed -nE 's|.*mihailsgordijenko/ps-client:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1)"

  local server_digest="" client_digest="" server_cid client_cid
  if command -v docker >/dev/null 2>&1; then
    server_cid="$(docker compose ps -q ps-server 2>/dev/null || echo "")"
    client_cid="$(docker compose ps -q ps-client 2>/dev/null || echo "")"
    [[ -n "$server_cid" ]] && server_digest="$(docker inspect --format '{{.Image}}' "$server_cid" 2>/dev/null || echo "")"
    [[ -n "$client_cid" ]] && client_digest="$(docker inspect --format '{{.Image}}' "$client_cid" 2>/dev/null || echo "")"
  fi

  local git_rev
  git_rev="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"

  STAMP="$stamp" SERVER_TAG="$server_tag" CLIENT_TAG="$client_tag" \
  SERVER_DIGEST="$server_digest" CLIENT_DIGEST="$client_digest" \
  GIT_REV="$git_rev" MANIFEST_FILE="${snap_dir}/manifest.json" \
  python3 <<'PY'
import json
import os
import datetime

manifest = {
    "schema_version": 1,
    "taken_at": os.environ["STAMP"],
    "deployment_repo_revision": os.environ.get("GIT_REV") or None,
    "image_tags": {
        "ps-server": os.environ.get("SERVER_TAG") or None,
        "ps-client": os.environ.get("CLIENT_TAG") or None,
    },
    "image_digests": {
        "ps-server": os.environ.get("SERVER_DIGEST") or None,
        "ps-client": os.environ.get("CLIENT_DIGEST") or None,
    },
}
with open(os.environ["MANIFEST_FILE"], "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PY

  printf '%s' "$snap_dir" > "${snapshots_root}/latest"

  # Prune: keep only the newest ROLLBACK_SNAPSHOTS_KEEP snapshot directories.
  local old_snaps
  old_snaps="$(find "$snapshots_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | tail -n "+$((ROLLBACK_SNAPSHOTS_KEEP + 1))")"
  if [[ -n "$old_snaps" ]]; then
    printf '%s\n' "$old_snaps" | while IFS= read -r d; do
      [[ -n "$d" ]] && rm -rf "$d"
    done
  fi

  printf '%s' "$snap_dir"
}

# resolve_rollback_snapshot <name-or-'latest'|path>
#
# Prints the resolved snapshot directory path, or nothing + returns 1 if it
# can't be found / doesn't contain the expected files.
resolve_rollback_snapshot() {
  local ref="$1"
  local snapshots_root="${repo_root}/${ROLLBACK_SNAPSHOTS_DIR_NAME}"
  local dir=""

  if [[ "$ref" == "latest" || -z "$ref" ]]; then
    if [[ -f "${snapshots_root}/latest" ]]; then
      dir="$(cat "${snapshots_root}/latest")"
    fi
  elif [[ -d "$ref" ]]; then
    dir="$ref"
  elif [[ -d "${snapshots_root}/${ref}" ]]; then
    dir="${snapshots_root}/${ref}"
  fi

  if [[ -z "$dir" || ! -f "${dir}/manifest.json" || ! -f "${dir}/docker-compose.yml" || ! -f "${dir}/config.js" ]]; then
    return 1
  fi
  printf '%s' "$dir"
}
