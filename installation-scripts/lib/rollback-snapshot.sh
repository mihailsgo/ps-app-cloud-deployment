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
# What a snapshot records for ps-server / ps-client is the image that is
# RUNNING, not what docker-compose.yml pins. The two differ whenever the
# checkout moved before upgrade.sh ran - the documented upgrade path is
# `git pull` first (documentation/04-04 Phase 1), and that alone already
# pins the new release in docker-compose.yml while the old containers keep
# running. A snapshot that recorded the pin would "roll back" to the release
# being rolled back from.
#
# Snapshots hold a copy of config/config.js, i.e. this deployment's secrets:
# .rollback-snapshots/ is kept at 700 and everything in it at 600.
#
# Expects "$repo_root" to be set by the sourcing script.

# shellcheck source=digests.sh
. "${repo_root}/installation-scripts/lib/digests.sh"

ROLLBACK_SNAPSHOTS_DIR_NAME=".rollback-snapshots"
ROLLBACK_SNAPSHOTS_KEEP=5
# Written by rollback.sh after a verified rollback; read by lib/digest_gate.py
# (validate-config.sh). Image references only, no secrets.
ROLLBACK_MARKER_NAME=".rollback-applied.json"
ROLLBACK_COMPONENTS=(ps-server ps-client)

# Prints "<tag> <digest>" (digest may be empty) for what a compose file pins
# for mihailsgordijenko/<component>, or nothing if it has no such line.
#
#   compose_pin <component> [compose file, default docker-compose.yml]
compose_pin() {
  local file="${2:-${repo_root}/docker-compose.yml}"
  sed -nE "s#.*mihailsgordijenko/$1:([0-9]+\.[0-9]+(\.[0-9]+)?)(@(sha256:[0-9a-f]{64}))?.*#\1 \4#p" "$file" 2>/dev/null \
    | tr -d '\r' | head -1
}

# component_state <component>
#
# Reads, without changing anything, what ps-server / ps-client is right now:
#   cs_pinned_tag, cs_pinned_digest    what docker-compose.yml pins
#   cs_running                         true if the service has a running container
#   cs_running_tag, cs_running_digest  the image that container was created from
#   cs_tag_source                      how cs_running_tag was found
#   cs_tag, cs_digest, cs_source       what a rollback snapshot records: the
#                                      running image, else the pin
component_state() {
  local c="$1" cid="" line
  cs_pinned_tag=""; cs_pinned_digest=""
  read -r cs_pinned_tag cs_pinned_digest <<< "$(compose_pin "$c")" || true
  cs_running=false; cs_running_tag=""; cs_running_digest=""; cs_tag_source=""
  if command -v docker >/dev/null 2>&1; then
    # From the project directory: `docker compose` finds the project by cwd.
    cid="$(cd "$repo_root" && docker compose ps -q "$c" 2>/dev/null | head -1 | tr -d '\r')" || cid=""
  fi
  if [[ -n "$cid" ]]; then
    cs_running=true
    cs_running_digest="$(digest_running "$cid")"
    line="$(running_release_tag "$cid" "mihailsgordijenko/${c}")"
    if [[ -n "$line" ]]; then
      cs_running_tag="${line%%$'\t'*}"
      cs_tag_source="${line#*$'\t'}"
    elif [[ -n "$cs_running_digest" && "$cs_running_digest" == "$cs_pinned_digest" ]]; then
      cs_running_tag="$cs_pinned_tag"
      cs_tag_source="docker-compose.yml, which pins the running digest"
    elif [[ -n "$cs_running_digest" ]]; then
      # A container created from a bare repo@digest of an unlabelled image:
      # the release files (and their git history) may still know the digest.
      line="$(python3 "$digest_gate_py" release-tag "$repo_root" "$digests_json" "mihailsgordijenko/${c}" "$cs_running_digest" 2>/dev/null | tr -d '\r' | head -1)" || line=""
      if [[ -n "$line" ]]; then
        cs_running_tag="${line%%$'\t'*}"
        cs_tag_source="${line#*$'\t'}"
      fi
    fi
  fi
  if [[ -n "${cs_running_digest}${cs_running_tag}" ]]; then
    cs_tag="${cs_running_tag:-$cs_pinned_tag}"
    cs_digest="$cs_running_digest"
    cs_source="running container"
    if [[ -z "$cs_running_tag" ]]; then
      cs_source="running container (tag unknown, docker-compose.yml's used)"
    fi
  else
    cs_tag="$cs_pinned_tag"
    cs_digest="$cs_pinned_digest"
    if [[ "$cs_running" == true ]]; then
      cs_source="docker-compose.yml (the running image has neither a registry digest nor a release tag)"
    else
      cs_source="docker-compose.yml (${c} is not running)"
    fi
  fi
  return 0
}

# Prints one line when <component>'s running image is not what
# docker-compose.yml pins, e.g. after a `git pull` ahead of upgrade.sh:
#   "docker-compose.yml pins ps-server 3.30 but 3.28 is running - the rollback snapshot records 3.28@sha256:..., the running image"
# Prints nothing when they agree or the service is not running.
# component_drift_text formats the cs_* variables the last component_state
# call set; component_drift_note reads the state first.
#
#   component_drift_note <component>
#   component_drift_text <component>
component_drift_note() {
  component_state "$1"
  component_drift_text "$1"
}
component_drift_text() {
  [[ "$cs_running" == true ]] || return 0
  if [[ -n "$cs_running_digest" && -n "$cs_pinned_digest" && "$cs_running_digest" != "$cs_pinned_digest" ]] \
     || [[ -n "$cs_running_tag" && -n "$cs_pinned_tag" && "$cs_running_tag" != "$cs_pinned_tag" ]]; then
    printf 'docker-compose.yml pins %s %s but %s is running - the rollback snapshot records %s%s, the running image' \
      "$1" "${cs_pinned_tag:-?}" "${cs_running_tag:-an image with digest ${cs_running_digest}}" \
      "${cs_tag:-?}" "${cs_digest:+@${cs_digest}}"
  fi
}

# Removes group/other access from .rollback-snapshots/ and everything in it
# (directories 700, files 600). upgrade.sh and rollback.sh both call it, so a
# tree an older upgrade.sh left at 755/644 is fixed by whichever runs first.
# Best effort: a file this user does not own is left as it is.
tighten_rollback_snapshots() {
  local snapshots_root="${repo_root}/${ROLLBACK_SNAPSHOTS_DIR_NAME}"
  [[ -d "$snapshots_root" ]] || return 0
  chmod -R go= "$snapshots_root" 2>/dev/null || true
  return 0
}

# write_rollback_snapshot
#
# Captures docker-compose.yml + config/config.js as they are RIGHT NOW (i.e.
# call this before any mutation), plus a manifest recording the RUNNING
# ps-server / ps-client tag and registry digest (component_state), what
# docker-compose.yml pinned for each, and the deployment repo's git
# revision. Updates the "latest" pointer file and prunes snapshots beyond
# ROLLBACK_SNAPSHOTS_KEEP.
#
# Prints the snapshot directory path on stdout.
write_rollback_snapshot() {
  local snapshots_root="${repo_root}/${ROLLBACK_SNAPSHOTS_DIR_NAME}"
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local snap_dir="${snapshots_root}/${stamp}"
  local old_umask
  old_umask="$(umask)"

  # 077 for everything created below, plus an explicit chmod: umask alone
  # does not fix a .rollback-snapshots/ an older upgrade.sh created 755 with
  # 644 copies of config.js in it.
  umask 077
  mkdir -p "$snap_dir"
  tighten_rollback_snapshots
  cp -f "${repo_root}/docker-compose.yml" "${snap_dir}/docker-compose.yml"
  cp -f "${repo_root}/config/config.js" "${snap_dir}/config.js"

  local c fields=()
  for c in "${ROLLBACK_COMPONENTS[@]}"; do
    component_state "$c"
    fields+=("$c" "${cs_tag:-}" "${cs_digest:-}" "${cs_source:-}" "${cs_tag_source:-}" "${cs_pinned_tag:-}" "${cs_pinned_digest:-}")
  done

  local git_rev
  git_rev="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"

  STAMP="$stamp" GIT_REV="$git_rev" MANIFEST_FILE="${snap_dir}/manifest.json" \
  python3 - "${fields[@]}" <<'PY'
import json
import os
import sys

args = sys.argv[1:]
tags, digests, sources, pins = {}, {}, {}, {}
for i in range(0, len(args), 7):
    c, tag, digest, source, tag_source, pinned_tag, pinned_digest = args[i:i + 7]
    tags[c] = tag or None
    digests[c] = digest or None
    sources[c] = source + (" - tag from the %s" % tag_source if tag_source else "")
    pins[c] = {"tag": pinned_tag or None, "digest": pinned_digest or None}

manifest = {
    # 2: image_tags / image_digests are the image that was RUNNING (1 took
    # image_tags from docker-compose.yml). rollback.sh reads both.
    "schema_version": 2,
    "taken_at": os.environ["STAMP"],
    "deployment_repo_revision": os.environ.get("GIT_REV") or None,
    "image_tags": tags,
    "image_digests": digests,
    "image_sources": sources,
    "compose_pins": pins,
}
with open(os.environ["MANIFEST_FILE"], "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
PY

  printf '%s' "$snap_dir" > "${snapshots_root}/latest"
  chmod 600 "${snap_dir}/docker-compose.yml" "${snap_dir}/config.js" "${snap_dir}/manifest.json" "${snapshots_root}/latest" 2>/dev/null || true
  chmod 700 "$snapshots_root" "$snap_dir" 2>/dev/null || true
  umask "$old_umask"

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
      dir="$(cat "${snapshots_root}/latest" 2>/dev/null)" || dir=""
    fi
  elif [[ -d "$ref" ]]; then
    dir="$ref"
  elif [[ -d "${snapshots_root}/${ref}" ]]; then
    dir="${snapshots_root}/${ref}"
  fi

  if [[ -z "$dir" || ! -r "${dir}/manifest.json" || ! -r "${dir}/docker-compose.yml" || ! -r "${dir}/config.js" ]]; then
    return 1
  fi
  printf '%s' "$dir"
}

# Prints why .rollback-snapshots/ exists but cannot be read by this user
# (created mode 700 by whoever ran upgrade.sh), or nothing + returns 1.
rollback_snapshots_unreadable() {
  local snapshots_root="${repo_root}/${ROLLBACK_SNAPSHOTS_DIR_NAME}" owner
  [[ -d "$snapshots_root" ]] || return 1
  [[ -r "$snapshots_root" && -x "$snapshots_root" ]] && [[ ! -e "${snapshots_root}/latest" || -r "${snapshots_root}/latest" ]] && return 1
  owner="$(stat -c '%U' "$snapshots_root" 2>/dev/null || echo "its owner")"
  printf '%s exists but is not readable by %s (it is mode 700, owned by %s, because it holds copies of config.js). Run rollback.sh as %s or with sudo.' \
    "$snapshots_root" "$(id -un 2>/dev/null || echo "this user")" "$owner" "$owner"
}

# write_rollback_marker <snapshot name> [<component> <tag> <digest>]...
#
# Records what rollback.sh restored and verified, for validate-config.sh's
# digest gate (lib/digest_gate.py): a pin named here that an earlier
# committed release approved is reported as a rollback (WARN) instead of an
# unapproved digest (FAIL). Replaces any earlier marker.
write_rollback_marker() {
  local snapshot="$1"
  shift
  MARKER_FILE="${repo_root}/${ROLLBACK_MARKER_NAME}" SNAPSHOT="$snapshot" python3 - "$@" <<'PY'
import datetime
import json
import os
import sys

args = sys.argv[1:]
images = {}
for i in range(0, len(args) - 2, 3):
    c, tag, digest = args[i:i + 3]
    if c and tag and digest:
        images[c] = {"repository": "mihailsgordijenko/" + c, "tag": tag, "digest": digest}
marker = {
    "schema_version": 1,
    "written_by": "rollback.sh",
    "snapshot": os.environ["SNAPSHOT"],
    "restored_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "images": images,
}
# Replace, not rewrite in place: works whoever owned the previous marker
# (rollback.sh run as root once, as the operator the next time).
path = os.environ["MARKER_FILE"]
with open(path + ".tmp", "w", encoding="utf-8") as fh:
    json.dump(marker, fh, indent=2)
    fh.write("\n")
os.replace(path + ".tmp", path)
PY
}

# Drops every entry of .rollback-applied.json whose pin docker-compose.yml no
# longer carries (upgrade.sh calls this after a successful run), and the file
# once nothing is left. Harmless when there is no marker.
prune_rollback_marker() {
  local marker="${repo_root}/${ROLLBACK_MARKER_NAME}" c tag digest keep=()
  [[ -f "$marker" ]] || return 0
  for c in "${ROLLBACK_COMPONENTS[@]}"; do
    read -r tag digest <<< "$(compose_pin "$c")" || true
    if [[ -n "${tag:-}" && -n "${digest:-}" ]]; then keep+=("$c" "$tag" "$digest"); fi
  done
  MARKER_FILE="$marker" python3 - ${keep[@]+"${keep[@]}"} <<'PY'
import json
import os
import sys

path = os.environ["MARKER_FILE"]
args = sys.argv[1:]
pinned = {args[i]: (args[i + 1], args[i + 2]) for i in range(0, len(args) - 2, 3)}
try:
    with open(path, encoding="utf-8") as fh:
        marker = json.load(fh)
except (OSError, ValueError):
    sys.exit(0)
images = {c: e for c, e in (marker.get("images") or {}).items()
          if pinned.get(c) == (e.get("tag"), e.get("digest"))}
if images == (marker.get("images") or {}):
    sys.exit(0)
if images:
    marker["images"] = images
    with open(path + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(marker, fh, indent=2)
        fh.write("\n")
    os.replace(path + ".tmp", path)
else:
    os.remove(path)
PY
}

# Returns 0 if the last verified rollback restored exactly <tag>@<digest> for
# <component>, i.e. docker-compose.yml differs from the release on purpose.
#
#   rollback_marker_covers <component> <tag> <digest>
rollback_marker_covers() {
  local marker="${repo_root}/${ROLLBACK_MARKER_NAME}"
  [[ -f "$marker" && -n "$2" && -n "$3" ]] || return 1
  MARKER_FILE="$marker" python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import sys

try:
    with open(os.environ["MARKER_FILE"], encoding="utf-8") as fh:
        e = (json.load(fh).get("images") or {}).get(sys.argv[1]) or {}
except (OSError, ValueError, AttributeError):
    sys.exit(1)
sys.exit(0 if (e.get("tag"), e.get("digest")) == (sys.argv[2], sys.argv[3]) else 1)
PY
}
