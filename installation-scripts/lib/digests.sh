# shellcheck shell=bash
#
# Shared reader for release/approved-digests.json, plus helpers for reading
# what's actually pinned in docker-compose.yml and what a registry currently
# serves for a tag. Follows the same pattern as lib/capabilities.sh: one
# machine-readable registry, read at run time, never a value hardcoded in a
# script.
#
# Sourced by validate-config.sh (compose file vs. registry file only - no
# network), check-digest-drift.sh (registry file vs. the live registry
# over the network), and rollback-snapshot.sh / deployment-evidence.sh
# (digest_running, to record what a container is actually running).
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

# Prints every image reference docker-compose.yml declares, one per line,
# quotes and \r stripped. A plain sed over the file rather than
# `docker compose config --images`, which only lists services whose profile
# is active - the profile-gated stamping and wizard services would never be
# seen, and this also has to work on a host without Docker.
compose_image_refs() {
  sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]?([^'\"[:space:]]+).*/\1/p" \
    "${repo_root}/docker-compose.yml" | tr -d '\r'
}

# Prints the registry digest (sha256:..., the same value docker-compose.yml
# pins and release/approved-digests.json approves) of the image a running
# container was created from, or nothing if Docker has no registry digest
# for it (e.g. a locally built image that was never pulled).
#
# Deliberately NOT `docker inspect --format '{{.Image}}' <container>`: that
# is the local image ID. Under the containerd image store it happens to equal
# the pulled index digest, but under the classic overlay2 store (still the
# default on upgraded Linux hosts) it is the image *config* digest, which is
# not a manifest - pinning `repo:tag@<config digest>` makes `docker pull`
# fail with "unexpected media type application/octet-stream".
#
#   digest_running <container-id>
digest_running() {
  local cid="$1" ref repository image_id found
  ref="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null | tr -d '\r')" || return 0
  [[ -z "$ref" ]] && return 0
  repository="${ref%@*}"
  # Strip a trailing :tag, but not a registry port (host:5000/repo).
  [[ "${repository##*:}" != */* ]] && repository="${repository%:*}"
  image_id="$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null)" || return 0
  found="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null \
    | tr -d '\r' \
    | awk -F@ -v repo="$repository" \
        '$1 == repo || $1 == "docker.io/" repo || $1 == "docker.io/library/" repo { print $2; exit }')"
  # A container created from repo:tag@digest was pulled by exactly that
  # digest, so the reference itself is authoritative if RepoDigests is empty.
  if [[ -z "$found" && "$ref" == *"@sha256:"* ]]; then
    found="${ref#*@}"
  fi
  [[ -n "$found" ]] && printf '%s\n' "$found"
  return 0
}
