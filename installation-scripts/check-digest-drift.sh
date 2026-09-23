#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Digest Drift Checker — compares release/approved-digests.json
# against what docker-compose.yml actually pins, and against what the
# registry currently serves for the same tag.
#
# Usage:
#   ./installation-scripts/check-digest-drift.sh
#
# For manual or scheduled review only — this script never writes anything
# and never re-pins a digest itself. A DRIFT line means "a human should
# look," not "something is broken": a registry moving a tag's digest is
# often a legitimate upstream rebuild (e.g. a base-image security patch on
# an official image), but could also mean the tag was force-pushed or
# compromised. Deciding which, and re-pinning if appropriate, is left to
# the reviewed process in documentation/39-release-procedure.md, not
# automated here.
#
# Exit codes: 0 clean, 1 drift found, 2 usage/dependency error — same
# convention as scripts/release-check.sh in psapp, which this is the
# digest-focused sibling of.
# ============================================================================

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/check-digest-drift.sh

Checks every image in release/approved-digests.json:
  - docker-compose.yml pins the digest this file approves
  - the registry still serves that same digest for the pinned tag today

Prints one DRIFT line per disagreement and exits non-zero. Read-only: never
modifies docker-compose.yml, release/approved-digests.json, or anything
else. Requires network access to reach each image's registry.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 2
  fi
}
need_cmd docker
need_cmd python3

if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx is required (queries a registry's manifest without a full image pull)." >&2
  exit 2
fi

# shellcheck source=lib/digests.sh
. "${scripts_dir}/lib/digests.sh"

if [[ ! -f "$digests_json" ]]; then
  echo "ERROR: ${digests_json} not found." >&2
  exit 2
fi

total="$(digest_registry_table | wc -l | tr -d ' ')"

echo "========================================"
echo "PadSign Digest Drift Check"
echo "  Registry: ${digests_json}"
echo "========================================"
echo ""

drift=0
checked=0

while IFS=$'\t' read -r image_key repository tag approved_digest; do
  [[ -z "$image_key" ]] && continue
  # Defensive \r strip: this repo's docker-compose.yml is CRLF for unrelated
  # reasons, and a Windows-hosted python3's stdout can add one too (see
  # lib/digests.sh) — every field gets the same treatment, not just the last.
  repository="${repository%$'\r'}"
  tag="${tag%$'\r'}"
  approved_digest="${approved_digest%$'\r'}"
  checked=$((checked + 1))

  echo "Step ${checked}/${total}: ${image_key} (${repository}:${tag})"

  compose_pinned="$(digest_from_compose "$repository")"
  if [[ -z "$compose_pinned" ]]; then
    echo "  DRIFT: not referenced in docker-compose.yml at all"
    drift=1
  elif [[ "$compose_pinned" != *"@sha256:"* ]]; then
    echo "  DRIFT: docker-compose.yml pins by tag only (${repository}:${compose_pinned}), no digest"
    drift=1
  else
    compose_digest="${compose_pinned#*@}"
    if [[ "$compose_digest" != "$approved_digest" ]]; then
      echo "  DRIFT: docker-compose.yml pins ${compose_digest}, approved-digests.json says ${approved_digest}"
      drift=1
    else
      echo "  docker-compose.yml matches approved-digests.json"
    fi
  fi

  # Best-effort network check: a registry hiccup or auth gap here is
  # informational, not a drift finding — the compose-vs-registry-file
  # comparison above already ran and is the part that can't silently no-op.
  live_digest="$(digest_live "$repository" "$tag" || true)"
  if [[ -z "$live_digest" ]]; then
    echo "  WARNING: could not query the registry for ${repository}:${tag} (network, auth, or rate limit?)" >&2
  elif [[ "$live_digest" != "$approved_digest" ]]; then
    echo "  DRIFT: registry now serves ${live_digest} for ${repository}:${tag}, approved-digests.json still says ${approved_digest}"
    drift=1
  else
    echo "  registry still serves the approved digest"
  fi
  echo ""
done < <(digest_registry_table)

echo "========================================"
if [[ "$drift" -eq 0 ]]; then
  echo "Clean. All ${checked} images agree across docker-compose.yml, release/approved-digests.json, and the live registry."
  exit 0
else
  echo "Drift found. See DRIFT: lines above."
  echo "Review before re-pinning — see documentation/39-release-procedure.md."
  exit 1
fi
