# shellcheck shell=bash
#
# Shared reader for release/approved-digests.json, plus helpers for reading
# what's actually pinned in docker-compose.yml and what a registry currently
# serves for a tag. Follows the same pattern as lib/capabilities.sh: one
# machine-readable registry, read at run time, never a value hardcoded in a
# script.
#
# Sourced by validate-config.sh (compose file vs. registry file only - no
# network) and check-digest-drift.sh (registry file vs. the live registry
# over the network).
#
# Expects "$repo_root" to be set by the sourcing script.

digests_json="${digests_json:-${repo_root}/release/approved-digests.json}"

# Prints the whole registry as one image per line, tab-separated:
#   <key><TAB><repository><TAB><tag><TAB><digest>
#
# One python3 invocation for the whole registry rather than one per field per
# image - deliberately, not just for speed: a python3-heredoc command called
# repeatedly *inside* a `while read ... < <(another-heredoc-command)` loop
# was found, live in this shell, to intermittently read the wrong heredoc
# body and report every key as unknown. Emitting the full table in one shot
# and doing only plain grep/sed lookups (digest_from_compose below) inside
# any loop sidesteps that entirely. Exits 3 on an unreadable/malformed
# registry.
#
# stdout is explicitly reconfigured to LF-only: on a Windows-hosted python3,
# text-mode stdout otherwise translates each \n to \r\n, which survives
# `$(...)`/`read` as a trailing \r on the last field and makes an otherwise
# byte-identical digest compare unequal. Callers also strip \r defensively
# (see validate-config.sh) - this file's own docker-compose.yml is CRLF for
# unrelated reasons, so treating a stray \r as always-possible matches this
# repo's existing convention (see upgrade.sh's \r? handling).
digest_registry_table() {
  python3 - "$digests_json" <<'PY'
import json, sys
try:
    sys.stdout.reconfigure(newline='\n')
except AttributeError:
    pass  # Python < 3.7; the bash-side strip below still covers it.
path = sys.argv[1]
try:
    data = json.load(open(path))
except Exception as exc:
    sys.stderr.write("ERROR: cannot read digest registry %s: %s\n" % (path, exc))
    sys.exit(3)
for key, entry in data.get("images", {}).items():
    print("\t".join([key, entry.get("repository", ""), entry.get("tag", ""), entry.get("digest", "")]))
PY
}

# Extracts what's actually pinned for <repository> in docker-compose.yml:
# prints "TAG@sha256:DIGEST" if a digest is pinned, bare "TAG" if the image
# is only tag-pinned, or nothing if the repository isn't referenced at all.
#
#   digest_from_compose <repository>
digest_from_compose() {
  local repository="$1"
  grep -oE "${repository}:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?" "${repo_root}/docker-compose.yml" \
    | head -1 \
    | sed "s|^${repository}:||"
}

# Queries the live registry for what <repository>:<tag> currently resolves
# to. Requires network access and `docker buildx`. Prints the digest alone
# (sha256:...) on success, or nothing on failure - callers must treat an
# empty result as "could not resolve", not as "no digest".
#
#   digest_live <repository> <tag>
digest_live() {
  local repository="$1" tag="$2"
  docker buildx imagetools inspect "${repository}:${tag}" 2>/dev/null \
    | awk '/^Digest:/ { print $2; exit }'
}
