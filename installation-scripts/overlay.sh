#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Environment overlay — keep a host's per-environment state OUTSIDE the git
# checkout, so a deployment is "clean release baseline + explicit overlay"
# instead of a hand-edited working tree (psapp-saas#7).
#
#   capture  Read a deployed directory (git checkout or plain copy) and write
#            everything that differs from a release baseline into a protected
#            overlay directory outside any checkout: whole-file overrides,
#            extra files, TLS certificates, .env, the compose project name
#            (which owns the Keycloak data volume), where signed documents
#            live, a starter compose.overlay.yml, and a redacted
#            DEVIATIONS.md. Never modifies the source; never reads
#            signed-output/ or docs/.
#   apply    Put an overlay onto a CLEAN checkout of the release: copies the
#            overlay files in (refusing if the release changed a file the
#            overlay replaces wholesale), installs certificates, writes .env
#            (COMPOSE_PROJECT_NAME + COMPOSE_FILE=docker-compose.yml:<overlay>).
#            Never starts or stops anything.
#   verify   Check a checkout against its overlay: every git-visible change is
#            declared, secret files are not world-readable, the compose project
#            reuses the existing Keycloak volume, storage mounts point at the
#            existing documents, and (with --live) the effective compose model
#            matches the host being replaced.
#   rebase   Carry an overlay forward onto a NEWER release (the checkout this
#            script lives in): 3-way merges the overlay's edits onto the new
#            release's versions of the files it overrides, into a NEW overlay
#            directory. The old overlay is never modified, so "previous
#            release checkout + previous overlay" stays a complete rollback.
#   rehash   Re-record checksums after deliberately editing overlay files
#            (resolved merge conflicts, a renewed certificate).
#
# All logic is in lib/overlay.py; secrets are never printed (lib/redact.py).
# Operator procedure: documentation/42-host-reconciliation-runbook.md.
# ============================================================================

usage() {
  cat <<'USAGE'
Usage:
  ./installation-scripts/overlay.sh capture --baseline <git-ref|clean-checkout-dir> --out <overlay-dir> [--from <deployed-dir>] [--host-base <ref|dir>]
  ./installation-scripts/overlay.sh apply   --overlay <overlay-dir> [--accept-baseline-change] [--force]
  ./installation-scripts/overlay.sh verify  --overlay <overlay-dir> [--live <deployed-dir>]
  ./installation-scripts/overlay.sh rebase  --overlay <old-overlay-dir> --out <new-overlay-dir>
  ./installation-scripts/overlay.sh rehash  --overlay <overlay-dir>

The overlay directory must be outside every checkout (e.g. /etc/padsign/overlay/<date>,
mode 700). apply, verify and rebase act on the checkout this script lives in.
--host-base: the release the host was ORIGINALLY deployed from (default: the
host's own git HEAD); lets capture carry only the host's edits, not old release content.

Exit codes: 0 ok (WARNs allowed), 1 check failed / refused, 2 usage error.
USAGE
}

case "${1:-}" in
  capture|apply|verify|rebase|rehash) ;;
  -h|--help) usage; exit 0;;
  *) usage >&2; exit 2;;
esac

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

for c in python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: Missing dependency: $c" >&2; exit 1; }
done

PYTHONDONTWRITEBYTECODE=1 exec python3 "${scripts_dir}/lib/overlay.py" --repo-root "$repo_root" "$@"
