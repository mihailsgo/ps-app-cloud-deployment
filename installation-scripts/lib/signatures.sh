# shellcheck shell=bash
# shellcheck disable=SC2034  # signed_image_keys / sig_status / sig_message are read by the sourcing script
#
# cosign signature verification for the PadSign images (ps-server,
# ps-client). psapp's CI signs every image it releases with a cosign key pair
# (psapp .github/workflows/sign-image.yml), and attaches the image's SPDX
# SBOM and SLSA v1 provenance as signed attestations. The public half of
# that key is release/cosign.pub. Nothing is uploaded to a transparency log
# (the source repository is private), so every check here passes
# --insecure-ignore-tlog=true: the key is the only trust anchor, which is
# the whole design, not a shortcut.
#
# Sourced by validate-config.sh and upgrade.sh, and by psapp's
# scripts/release-check.sh (which presets cosign_pub / unsigned_legacy_json
# to point into this repo). Expects "$repo_root" to be set, or both of those
# paths to be preset.
#
# Only reads the registry (cosign needs no other network access with a key
# and no transparency log). Makes no changes to anything.

cosign_pub="${cosign_pub:-${repo_root}/release/cosign.pub}"
unsigned_legacy_json="${unsigned_legacy_json:-${repo_root}/release/unsigned-legacy-images.json}"

# Signatures are cosign v3 bundles (OCI referrers). cosign v2 looks for the
# old .sig tags instead and would report "no signatures found".
cosign_min_major=3

# The images psapp CI builds and signs. Third-party images (Keycloak, DMSS,
# nginx, ...) are not ours to sign; they are covered by digest pinning only.
signed_image_keys=(ps-server ps-client)

# True when a missing or too-old cosign must fail rather than warn: in CI
# (GitHub Actions and most others set CI=true), or when an operator opts in
# with PADSIGN_REQUIRE_SIGNATURES=1. On an ordinary host it warns, so a
# deployment that has not installed cosign yet keeps validating.
signatures_required() {
  [[ "${PADSIGN_REQUIRE_SIGNATURES:-}" == 1 || "${CI:-}" == true ]]
}

# Prints the installed cosign version (v3.1.3), or nothing if cosign is not
# on PATH. Returns 0 only for a version this file can use.
cosign_usable() {
  local version major
  command -v cosign >/dev/null 2>&1 || return 1
  version="$(cosign version --json 2>/dev/null | sed -nE 's/.*"gitVersion": *"([^"]+)".*/\1/p' | head -1)"
  printf '%s' "$version"
  major="${version#v}"; major="${major%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] && (( major >= cosign_min_major ))
}

# Exit 0 if <repository>@<digest> is on the closed list of images released
# before signing existed (release/unsigned-legacy-images.json). Matches the
# exact digest, never a tag or a version range: a newly pushed unsigned
# image can never match, whatever it is tagged.
#
#   is_unsigned_legacy <repository> <digest>
is_unsigned_legacy() {
  local repository="$1" digest="$2"
  [[ -n "$digest" && -f "$unsigned_legacy_json" ]] || return 1
  python3 - "$unsigned_legacy_json" "$repository" "$digest" <<'PY'
import json, sys
path, repository, digest = sys.argv[1:4]
try:
    entries = json.load(open(path)).get("images", [])
except Exception as exc:
    sys.stderr.write("ERROR: cannot read %s: %s\n" % (path, exc))
    sys.exit(3)
sys.exit(0 if any(e.get("repository") == repository and e.get("digest") == digest for e in entries) else 1)
PY
}

# First meaningful line of a failed cosign run, for a one-line report.
_cosign_reason() {
  local out="$1" line
  line="$(grep -m1 -E '^Error:' <<< "$out" | sed 's/^Error: *//' || true)"
  [[ -z "$line" ]] && line="$(grep -v -E '^(WARNING|$)' <<< "$out" | tail -1 || true)"
  printf '%s' "${line:-cosign exited non-zero with no output}"
}

# Checks one image and sets two globals for the caller to report however it
# reports things:
#   sig_status   verified | exempt | unavailable | failed
#   sig_message  one line, human-readable
#
# verified     the image signature and both attestations (spdxjson SBOM,
#              slsaprovenance1 provenance) verify against release/cosign.pub
# exempt       unsigned, but the exact digest is a pre-signing release
#              (release/unsigned-legacy-images.json)
# unavailable  could not check: cosign missing or older than v3. Callers
#              warn, or fail when signatures_required
# failed       checked and rejected, or could not be checked for a reason
#              that is not "no cosign" (missing key, registry unreachable).
#              Always fails: an image that cannot be verified is not
#              treated as verified
#
#   signature_check <repository> <reference> [<digest>]
# <reference> is what cosign verifies: repo@sha256:... whenever the digest is
# known (always, for a pinned image), repo:tag only when it is not.
signature_check() {
  local repository="$1" ref="$2" digest="${3:-}" version out
  sig_status="" sig_message=""

  # Checked before cosign, so a pre-signing release is reported the same
  # way on a host with or without cosign installed.
  if is_unsigned_legacy "$repository" "$digest"; then
    sig_status=exempt
    sig_message="released before image signing existed; exempt by exact digest in release/unsigned-legacy-images.json"
    return 0
  fi

  if ! version="$(cosign_usable)"; then
    sig_status=unavailable
    if [[ -z "$version" ]]; then
      sig_message="cosign is not installed, so the image signature was not checked (documentation/40-02-post-deploy-validation.md)"
    else
      sig_message="cosign ${version} is too old (need v${cosign_min_major}+), so the image signature was not checked"
    fi
    return 0
  fi

  if [[ ! -f "$cosign_pub" ]]; then
    sig_status=failed
    sig_message="public key ${cosign_pub} is missing - cannot verify any signature"
    return 0
  fi

  if ! out="$(cosign verify --key "$cosign_pub" --insecure-ignore-tlog=true "$ref" 2>&1 >/dev/null)"; then
    sig_status=failed
    sig_message="image signature does not verify against release/cosign.pub: $(_cosign_reason "$out")"
    return 0
  fi
  if ! out="$(cosign verify-attestation --key "$cosign_pub" --insecure-ignore-tlog=true --type spdxjson "$ref" 2>&1 >/dev/null)"; then
    sig_status=failed
    sig_message="image is signed, but its SBOM attestation (spdxjson) does not verify: $(_cosign_reason "$out")"
    return 0
  fi
  if ! out="$(cosign verify-attestation --key "$cosign_pub" --insecure-ignore-tlog=true --type slsaprovenance1 "$ref" 2>&1 >/dev/null)"; then
    sig_status=failed
    sig_message="image is signed, but its provenance attestation (slsaprovenance1) does not verify: $(_cosign_reason "$out")"
    return 0
  fi

  sig_status=verified
  sig_message="signature, SBOM and provenance attestations verify against release/cosign.pub"
  return 0
}
