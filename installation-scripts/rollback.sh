#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Rollback - restore the ps-server / ps-client images and config.js
# that were in place immediately before an upgrade.sh run.
#
# Usage:
#   ./installation-scripts/rollback.sh [--to latest|<snapshot-dir-name>] [--yes]
#
# What this restores (and nothing else):
#   - docker-compose.yml's ps-server/ps-client image lines only (a targeted
#     sed, not a wholesale file overwrite - so any unrelated docker-compose.yml
#     edit made after the snapshot, e.g. a configure-host.sh
#     --enable-local-eseal block, survives). Restores repo:tag@digest of the
#     image that was RUNNING when upgrade.sh took the snapshot, which is not
#     necessarily what docker-compose.yml pinned then: after the documented
#     `git pull` ahead of upgrade.sh, docker-compose.yml already pins the new
#     release while the old one still runs (see lib/rollback-snapshot.sh).
#   - config/config.js, restored verbatim from the snapshot
#
# Snapshot formats:
#   schema 2 (this version of upgrade.sh): the manifest's image_tags /
#     image_digests are the running image; restored as recorded.
#   schema 1 (older upgrade.sh): image_tags came from docker-compose.yml and
#     image_digests from the running container. When the two disagree, the
#     digest is trusted, its tag is looked up (release files and their git
#     history, the local image's OCI version label) and a warning is printed.
#     A digest that is really a local image ID (what the oldest snapshots
#     recorded on the classic image store) is mapped to its registry digest.
#
# Verified, not assumed: after the restart, each restored service must be
# running the digest the snapshot recorded. If it is not, this exits 1
# (ROLLBACK FAILED) - it never reports success for a stack that is still on
# the release being rolled back from.
#
# What this NEVER touches:
#   - signed-output/ or docs/ (document storage)
#   - nginx/nginx.conf or config/constants.json (configure-host.sh's
#     "environment overlay" - hostname, TLS paths, DEMO_MODE, redirect URIs)
#   - Keycloak admin credentials / realm state
#   - the git checkout itself: release/approved-digests.json keeps approving
#     the release rolled back from. validate-config.sh reports the restored
#     pins as a rollback (WARN) when an earlier committed revision of that
#     file approved them, using the .rollback-applied.json this script
#     writes after a verified rollback (lib/rollback-snapshot.sh).
#
# Idempotent: running this twice in a row against the same snapshot is a
# no-op the second time (the tag sed matches nothing to change, config.js
# copy is byte-identical).
#
# Exit codes:
#   0  rollback applied (or already at the target state), the restored
#      services are healthy and run the recorded digests
#   1  rollback failed, refused (a recorded image could not be identified -
#      nothing changed), the restored services did not become healthy, or
#      they do not run the recorded digests
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
# Default health wait: at least the longest health-check window in
# docker-compose.yml, so this never gives up on a service Docker still
# counts as starting. DMSS JVMs: start_period 300s + 10 retries x (10s
# interval + 5s timeout) = 450s; see dmss-container-and-signature-services.
health_timeout=480

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/rollback.sh [--to latest|<snapshot-dir-name>] [--yes]

  --to    Which snapshot to restore. Defaults to 'latest' (the most recent
          upgrade.sh run). Snapshot names are timestamps under the repo
          root's .rollback-snapshots/ (gitignored, mode 700) - list them with:
            ls .rollback-snapshots/
  --yes   Skip the confirmation prompt (for non-interactive use).
  --health-timeout N
          Seconds to wait for the restored services to be healthy
          (default 480). The rollback exits 1 if they are not.

This restores the ps-server / ps-client images that were RUNNING immediately
before the chosen upgrade.sh run (repo:tag@digest), and config/config.js as
it was then. It then checks that the restored containers run exactly those
digests and exits 1 if they do not. It does not touch signed-output/, docs/,
nginx/nginx.conf, config/constants.json or the git checkout.

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

# Snapshots hold copies of config.js: close up a tree an older upgrade.sh left
# world-readable before reading anything from it.
tighten_rollback_snapshots

snap_dir="$(resolve_rollback_snapshot "$target_ref")" || {
  echo "ERROR: No usable rollback snapshot found for '--to ${target_ref}'." >&2
  if unreadable="$(rollback_snapshots_unreadable)"; then
    echo "       ${unreadable}" >&2
  else
    echo "       Snapshots are written by upgrade.sh before each run. None exist yet if upgrade.sh has never run." >&2
  fi
  exit 2
}

# One python3 call reads the manifest into "<field><TAB><value>" lines. The
# path goes in through the environment, not the -c string: keeps this safe
# regardless of what characters end up in a path, and (found by testing on
# Windows/Git Bash) env-var values reliably reach python's file APIs in a
# form it can open, where a path embedded in the program text did not.
manifest_fields="$(MANIFEST_PATH="${snap_dir}/manifest.json" python3 - <<'PY' 2>/dev/null || true
import json, os, sys
try:
    sys.stdout.reconfigure(newline="\n")
except AttributeError:
    pass
with open(os.environ["MANIFEST_PATH"], encoding="utf-8") as fh:
    m = json.load(fh)
print("schema\t%s" % (m.get("schema_version") or 1))
print("taken_at\t%s" % (m.get("taken_at") or ""))
for c in ("ps-server", "ps-client"):
    print("tag:%s\t%s" % (c, (m.get("image_tags") or {}).get(c) or ""))
    print("digest:%s\t%s" % (c, (m.get("image_digests") or {}).get(c) or ""))
    print("source:%s\t%s" % (c, (m.get("image_sources") or {}).get(c) or ""))
    pin = (m.get("compose_pins") or {}).get(c) or {}
    print("pinned_tag:%s\t%s" % (c, pin.get("tag") or ""))
    print("pinned_digest:%s\t%s" % (c, pin.get("digest") or ""))
PY
)"
manifest_fields="$(tr -d '\r' <<< "$manifest_fields")"
mf() {  # <field> -> its value, or nothing
  awk -F'\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }' <<< "$manifest_fields"
}
if [[ -z "$manifest_fields" ]]; then
  echo "ERROR: ${snap_dir}/manifest.json could not be read (is python3 installed?)." >&2
  exit 1
fi
schema="$(mf schema)"
[[ "$schema" =~ ^[0-9]+$ ]] || schema=1
taken_at="$(mf taken_at)"

# ── Identify, per component, the image to restore ───────────────────────────

# Prints "<tag><TAB><where>" for <digest> of <repository>: what the release
# files know it as (approved now, unsigned-legacy list, or an earlier
# committed approval), else the snapshot's compose copy, else the local
# image's OCI version label / only local tag. Nothing if none knows it.
tag_for_digest() {  # <repository> <digest>
  local repository="$1" digest="$2" found tag
  [[ -n "$digest" ]] || return 0
  found="$(python3 "${scripts_dir}/lib/digest_gate.py" release-tag "$repo_root" "$digests_json" "$repository" "$digest" 2>/dev/null | tr -d '\r' | head -1)" || found=""
  if [[ -n "$found" ]]; then printf '%s\n' "$found"; return 0; fi
  tag="$(sed -nE "s#.*${repository}:([0-9]+\.[0-9]+(\.[0-9]+)?)@${digest}.*#\1#p" "${snap_dir}/docker-compose.yml" 2>/dev/null | head -1)"
  if [[ -n "$tag" ]]; then printf '%s\t%s\n' "$tag" "the snapshot's docker-compose.yml"; return 0; fi
  command -v docker >/dev/null 2>&1 && image_release_tag "${repository}@${digest}" "$repository"
  return 0
}

# Maps a digest a schema-1 snapshot recorded to a pullable registry digest.
# The oldest snapshots recorded `docker inspect {{.Image}}`, the local image
# ID - on the classic image store that is the config digest, which cannot be
# pulled. Prints the registry digest (preferring <prefer> when the image has
# it), or nothing if the image is not on this host.
registry_digest_for() {  # <repository> <digest> [<prefer>]
  local repository="$1" digest="$2" prefer="${3:-}" id list
  command -v docker >/dev/null 2>&1 || return 0
  id="$(docker image inspect --format '{{.Id}}' "$digest" 2>/dev/null | tr -d '\r')" || id=""
  if [[ "$id" == "$digest" ]]; then
    list="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$digest" 2>/dev/null \
      | tr -d '\r' | awk -F@ -v repo="$repository" '$1 == repo || $1 == "docker.io/" repo { print $2 }')"
    if [[ -n "$prefer" ]] && grep -qx -- "$prefer" <<< "$list"; then printf '%s\n' "$prefer"
    elif grep -qx -- "$digest" <<< "$list"; then printf '%s\n' "$digest"
    else head -1 <<< "$list"
    fi
    return 0
  fi
  docker image inspect "${repository}@${digest}" >/dev/null 2>&1 && printf '%s\n' "$digest"
  return 0
}

declare -A tgt_tag=() tgt_digest=() rec_digest=() tgt_note=()
warnings=()
refusals=()

resolve_target() {  # <component>
  local c="$1" repository="mihailsgordijenko/$1" tag dig pin_tag pin_dig norm found t_tag t_dig
  tag="$(mf "tag:$c")"; dig="$(mf "digest:$c")"
  rec_digest[$c]="$dig"
  if [[ "$schema" -ge 2 ]]; then
    pin_tag="$(mf "pinned_tag:$c")"; pin_dig="$(mf "pinned_digest:$c")"
  else
    pin_tag=""; pin_dig=""
    read -r pin_tag pin_dig <<< "$(compose_pin "$c" "${snap_dir}/docker-compose.yml")" || true
    [[ "$pin_tag" != "$tag" ]] && pin_dig=""
  fi
  [[ -z "$tag" && -z "$dig" ]] && return 0   # nothing recorded: leave it alone

  t_tag="$tag"; t_dig="$dig"
  if [[ "$schema" -ge 2 ]]; then
    tgt_note[$c]="$(mf "source:$c")"
    if [[ -z "$t_dig" && -n "$pin_dig" && "$pin_tag" == "$t_tag" ]]; then
      t_dig="$pin_dig"
      tgt_note[$c]="${tgt_note[$c]:+${tgt_note[$c]}; }digest from docker-compose.yml's pin for the same tag"
    fi
  elif [[ -n "$dig" ]]; then
    norm="$(registry_digest_for "$repository" "$dig" "$pin_dig")"
    if [[ -n "$norm" && "$norm" != "$dig" ]]; then
      tgt_note[$c]="the snapshot recorded local image ID ${dig}; its registry digest is ${norm}"
    fi
    if [[ -z "$norm" ]]; then
      # Not on this host any more. A digest a release knows is a registry
      # digest; anything else may be an old image ID that only the
      # compose copy's pin can be pulled by.
      found="$(tag_for_digest "$repository" "$dig")"
      if [[ -n "$found" ]]; then
        norm="$dig"
      else
        t_dig="$pin_dig"
        tgt_note[$c]="the snapshot recorded ${dig}, which is not on this host and no release names; restoring its docker-compose.yml pin and checking afterwards that the result runs ${dig}"
      fi
    fi
    if [[ -n "$norm" ]]; then
      t_dig="$norm"
      if [[ -n "$pin_dig" && "$norm" == "$pin_dig" ]]; then
        : # the running image was the pinned one: the normal case
      else
        found="${found:-$(tag_for_digest "$repository" "$norm")}"
        if [[ -n "$found" ]]; then
          t_tag="${found%%$'\t'*}"
          if [[ -n "$pin_dig" || "$t_tag" != "$tag" ]]; then
            warnings+=("${c}: the snapshot's docker-compose.yml pinned ${tag:-nothing}${pin_dig:+@${pin_dig}}, but the container that was running then ran ${norm} (${t_tag}, from ${found#*$'\t'}). Restoring the running image. This snapshot was taken by an older upgrade.sh after docker-compose.yml had already moved on (a git pull before upgrade.sh).")
          fi
        elif [[ -n "$pin_dig" ]]; then
          refusals+=("${c}: the snapshot's docker-compose.yml pinned ${tag}@${pin_dig}, but the running container recorded ${norm}, and no release file, git history or local image names a tag for it")
          return 0
        fi
      fi
    fi
  else
    t_dig="$pin_dig"
  fi

  if [[ -z "$t_tag" ]]; then
    found="$(tag_for_digest "$repository" "$t_dig")"
    t_tag="${found%%$'\t'*}"
    if [[ -z "$t_tag" ]]; then
      refusals+=("${c}: the snapshot recorded ${t_dig:-no digest} but no tag for it, and none could be found")
      return 0
    fi
  fi
  tgt_tag[$c]="$t_tag"
  tgt_digest[$c]="$t_dig"
}

for c in "${ROLLBACK_COMPONENTS[@]}"; do
  resolve_target "$c"
done

current_server_tag="$(compose_pin ps-server | cut -d' ' -f1)"
current_client_tag="$(compose_pin ps-client | cut -d' ' -f1)"

echo "PadSign Rollback"
echo "================================"
echo "Snapshot:        ${snap_dir}"
echo "Snapshot taken:  ${taken_at}   (manifest schema ${schema})"
echo ""
for c in "${ROLLBACK_COMPONENTS[@]}"; do
  if [[ "$c" == ps-server ]]; then now="$current_server_tag"; else now="$current_client_tag"; fi
  if [[ -n "${tgt_tag[$c]:-}" ]]; then
    echo "  ${c}: ${now:-unknown} -> ${tgt_tag[$c]}${tgt_digest[$c]:+@${tgt_digest[$c]}}"
    if [[ -n "${tgt_note[$c]:-}" ]]; then echo "      (${tgt_note[$c]})"; fi
  else
    echo "  ${c}: ${now:-unknown} -> <unchanged>"
  fi
done
echo ""
for w in ${warnings[@]+"${warnings[@]}"}; do
  echo "WARNING: ${w}" >&2
done
if [[ ${#warnings[@]} -gt 0 ]]; then echo "" >&2; fi
if [[ ${#refusals[@]} -gt 0 ]]; then
  for r in "${refusals[@]}"; do
    echo "ERROR: ${r}." >&2
  done
  echo "" >&2
  echo "Refusing to roll back: restoring docker-compose.yml's pin instead could leave the" >&2
  echo "stack on the release you are rolling back from. Nothing was changed. Restore by hand" >&2
  echo "(documentation/40-04-rollback.md, 'Restoring by hand'), or pick another snapshot with --to." >&2
  exit 1
fi
echo "This restores docker-compose.yml's image tags and config/config.js to"
echo "their state immediately before that upgrade.sh run, then checks that the"
echo "restored containers run exactly the recorded digests. It never touches"
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
echo "Step 1/4: Restoring image tags in docker-compose.yml..."
# -E and the trailing (@sha256:[0-9a-f]+)? deliberately strip whatever digest
# is CURRENTLY pinned before writing the new reference - that digest belongs
# to the tag being rolled back FROM, not the one being rolled back TO.
# Carrying it forward would silently pin the restored tag to the wrong
# content (the same bug fixed in upgrade.sh's Step 2 for the same reason).
services=""
for c in "${ROLLBACK_COMPONENTS[@]}"; do
  [[ -n "${tgt_tag[$c]:-}" ]] || continue
  services="$services $c"
  if [[ -n "${tgt_digest[$c]}" ]]; then
    sed -i -E "s|mihailsgordijenko/${c}:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/${c}:${tgt_tag[$c]}@${tgt_digest[$c]}|" "$compose_yml"
    echo "  ${c} -> ${tgt_tag[$c]}@${tgt_digest[$c]}"
  else
    sed -i -E "s|mihailsgordijenko/${c}:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/${c}:${tgt_tag[$c]}|" "$compose_yml"
    echo "  ${c} -> ${tgt_tag[$c]} (no digest in this snapshot - re-pin manually, see documentation/39-release-procedure.md)"
  fi
done

echo "Step 2/4: Restoring config/config.js from snapshot..."
# cp onto the existing file keeps config.js's own owner and mode (ps-server
# must still be able to read it) - the snapshot copy's 600 is not carried over.
cp -f "${snap_dir}/config.js" "$config_js"
echo "  Restored"

echo "Step 3/4: Pulling and restarting..."
cd "$repo_root"
if [[ -n "$services" ]]; then
  # shellcheck disable=SC2086 # word-splitting the service list is intended
  docker compose pull $services
  # shellcheck disable=SC2086
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

echo "Step 4/4: Checking the restored containers run the recorded images..."
verify_failed=()
marker_args=()
for c in $services; do
  cid="$(docker compose ps -q "$c" 2>/dev/null | head -1 | tr -d '\r')" || cid=""
  running=""; image_id=""
  if [[ -n "$cid" ]]; then
    running="$(digest_running "$cid")"
    image_id="$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null | tr -d '\r')" || image_id=""
  fi
  want="${tgt_digest[$c]}"; rec="${rec_digest[$c]}"
  if [[ -z "$cid" ]]; then
    verify_failed+=("${c}: no running container")
  elif [[ -n "$want" && "$running" != "$want" ]]; then
    verify_failed+=("${c}: running ${running:-an image with no registry digest}, but the snapshot recorded ${want} (${tgt_tag[$c]})")
  elif [[ -n "$rec" && "$rec" != "$want" && "$running" != "$rec" && "$image_id" != "$rec" ]]; then
    verify_failed+=("${c}: running ${running:-?} (image ${image_id:-?}), but the snapshot recorded ${rec}")
  elif [[ -z "$want" && -z "$rec" ]]; then
    echo "  ${c}: running ${tgt_tag[$c]} (not verified: this snapshot recorded no digest)"
  else
    echo "  ${c}: running ${tgt_tag[$c]}@${running} - the image the snapshot recorded"
    marker_args+=("$c" "${tgt_tag[$c]}" "$running")
  fi
done
if [[ ${#verify_failed[@]} -gt 0 ]]; then
  write_deployment_evidence "rollback.sh (verification failed)" || true
  echo "" >&2
  for f in "${verify_failed[@]}"; do
    echo "ROLLBACK FAILED: ${f}." >&2
  done
  echo "The stack is NOT back on the snapshot's images. Check: docker compose ps;" >&2
  echo "docker inspect --format '{{.Config.Image}}' \$(docker compose ps -q ps-server ps-client)" >&2
  exit 1
fi

write_rollback_marker "$(basename "$snap_dir")" ${marker_args[@]+"${marker_args[@]}"} \
  || echo "  WARNING: could not write ${ROLLBACK_MARKER_NAME}; validate-config.sh will report the restored pins as unapproved." >&2

write_deployment_evidence "rollback.sh"

echo ""
echo "================================"
echo "Rollback complete."
echo ""
echo "This checkout's release/approved-digests.json still approves the release you"
echo "rolled back from. validate-config.sh reports the restored pins as a rollback"
echo "(WARN) when an earlier committed revision of that file approved them, and as"
echo "unapproved (FAIL) otherwise. Roll forward with upgrade.sh once the cause is fixed."
