#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Digest Drift Checker — compares release/approved-digests.json
# against what the effective compose model actually pins (docker-compose.yml
# plus any COMPOSE_FILE overlay, every profile), and against what the
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

Checks:
  - every image of the effective compose model (docker-compose.yml plus any
    COMPOSE_FILE overlay, every profile) is digest-pinned and approved, by
    release/approved-digests.json or, on an overlay host, by the overlay's
    approved-digests.json - the same rules as validate-config.sh
  - the registry still serves each approved digest for its tag today

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
if ! compose_images_prime; then
  echo "ERROR: could not read the effective compose model." >&2
  exit 2
fi

# Every approval to compare against the registry: the release's, plus - on a
# host run as release baseline + environment overlay - the overlay's own
# approved-digests.json (documentation/42-03).
approvals_table="$(
  digest_registry_table | tr -d '\r' | sed 's/^/release\t/'
  digest_env_registry_table | sed 's/^/overlay\t/'
)"
total=$(( $(grep -c . <<< "$approvals_table") + 1 ))

echo "========================================"
echo "PadSign Digest Drift Check"
echo "  Registry: ${digests_json}"
echo "========================================"
echo ""

drift=0
checked=0

# Step 1: the effective compose model (docker-compose.yml plus any
# COMPOSE_FILE overlay, every profile) against the approvals - the same
# rules validate-config.sh applies (lib/digest_gate.py), so the two cannot
# disagree about which images are approved.
echo "Step 1/${total}: effective compose model vs. approved digests"
while IFS=$'\t' read -r gate_status gate_message; do
  case "$gate_status" in
    FAIL) echo "  DRIFT: ${gate_message}"; drift=1;;
    OK|INFO) echo "  ${gate_message}";;
  esac
done < <(digest_gate_check)
echo ""

step=1
while IFS=$'\t' read -r origin image_key repository tag approved_digest; do
  [[ -z "$image_key" ]] && continue
  # Defensive \r strip: this repo's docker-compose.yml is CRLF for unrelated
  # reasons, and a Windows-hosted python3's stdout can add one too (see
  # lib/digests.sh) - every field gets the same treatment, not just the last.
  repository="${repository%$'\r'}"
  tag="${tag%$'\r'}"
  approved_digest="${approved_digest%$'\r'}"
  step=$((step + 1))
  checked=$((checked + 1))

  label="${image_key}"
  [[ "$origin" == overlay ]] && label="${image_key} (overlay approval)"
  echo "Step ${step}/${total}: ${label} (${repository}:${tag})"

  # Best-effort network check: a registry hiccup or auth gap here is
  # informational, not a drift finding - the compose-vs-approvals
  # comparison in step 1 already ran and is the part that can't silently
  # no-op.
  live_digest="$(digest_live "$repository" "$tag" || true)"
  if [[ -z "$live_digest" ]]; then
    echo "  WARNING: could not query the registry for ${repository}:${tag} (network, auth, or rate limit?)" >&2
  elif [[ "$live_digest" != "$approved_digest" ]]; then
    echo "  DRIFT: registry now serves ${live_digest} for ${repository}:${tag}, the approval still says ${approved_digest}"
    drift=1
  else
    echo "  registry still serves the approved digest"
  fi
  echo ""
done <<< "$approvals_table"

echo "========================================"
if [[ "$drift" -eq 0 ]]; then
  echo "Clean. All ${checked} approved images agree across the effective compose model, their approvals, and the live registry."
  exit 0
else
  echo "Drift found. See DRIFT: lines above."
  echo "Review before re-pinning - see documentation/39-release-procedure.md."
  exit 1
fi
