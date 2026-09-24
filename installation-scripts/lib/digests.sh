# shellcheck shell=bash
#
# Shared reader for release/approved-digests.json, plus helpers for reading
# what the EFFECTIVE compose model actually pins and what a registry
# currently serves for a tag. Follows the same pattern as lib/capabilities.sh:
# one machine-readable registry, read at run time, never a value hardcoded in
# a script.
#
# "Effective compose model" = what `docker compose up` would run here: every
# file COMPOSE_FILE names (an environment overlay such as the section 42
# compose.overlay.yml adds or replaces images), with every profile enabled so
# the profile-gated stamping and wizard services are always covered. Reading
# docker-compose.yml alone let an overlay's images bypass the gate. The model
# comes from lib/digest_gate.py (`docker compose config`, with a plain-file
# fallback when docker is unavailable).
#
# Sourced by validate-config.sh (compose model vs. registry file only - no
# network; postdeploy-check.sh runs it), check-digest-drift.sh (also vs. the
# live registry over the network), upgrade.sh (approved_pin and the
# unapproved-tag refusal), dmss-seal-smoke.sh (which DMSS images to boot),
# and rollback-snapshot.sh / deployment-evidence.sh (digest_running, to
# record what a container is actually running).
#
# Expects "$repo_root" to be set by the sourcing script.

digests_json="${digests_json:-${repo_root}/release/approved-digests.json}"
digest_gate_py="${repo_root}/installation-scripts/lib/digest_gate.py"

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

# Loads the effective compose model once into $compose_images (one
# "<service>\t<image>" line per service) and $compose_images_source (how it
# was obtained). Call it at top level before any loop: a call made inside
# $(...) primes only that subshell, so every helper below still works
# unprimed, just slower (each call renders the model again).
compose_images_prime() {
  local out
  out="$(python3 "$digest_gate_py" images "$repo_root" | tr -d '\r')" || return 3
  compose_images_source="$(grep '^#source' <<< "$out" | head -1 | cut -f3-)"
  compose_images="$(grep -v '^#source' <<< "$out" || true)"
  compose_images_raw="$out"
}

_compose_images_ensure() {
  [[ -n "${compose_images_raw+x}" ]] || compose_images_prime
}

# Extracts what the effective compose model pins for <repository>: prints
# "TAG@sha256:DIGEST" if a digest is pinned, bare "TAG" if the image is only
# tag-pinned, or nothing if no service uses the repository at all.
#
#   digest_from_compose <repository>
digest_from_compose() {
  local repository="$1"
  _compose_images_ensure
  cut -f2 <<< "$compose_images"     | grep -E "^${repository}:[A-Za-z0-9._-]+(@sha256:[0-9a-f]{64})?$"     | head -1     | sed "s|^${repository}:||"
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

# Prints every image reference of the effective compose model, one per line.
compose_image_refs() {
  _compose_images_ensure
  cut -f2 <<< "$compose_images" | sed '/^$/d'
}

# The digest gate itself: every image of the effective compose model must be
# digest-pinned and approved, by release/approved-digests.json or, on a host
# running an environment overlay, by the overlay's own approved-digests.json
# (documentation/42-03). Prints "<OK|FAIL|INFO><TAB><message>" lines; the
# caller decides how to render them. validate-config.sh and
# check-digest-drift.sh both use this, so they cannot disagree.
digest_gate_check() {
  _compose_images_ensure
  python3 "$digest_gate_py" check "$repo_root" "$digests_json" <<< "$compose_images_raw" | tr -d '\r'
}

# The overlay's approvals, same columns as digest_registry_table
# (<key><TAB><repository><TAB><tag><TAB><digest>), or nothing.
digest_env_registry_table() {
  python3 "$digest_gate_py" approvals "$repo_root" | tr -d '\r'
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
