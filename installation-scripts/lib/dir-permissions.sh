# shellcheck shell=bash
#
# Shared "narrow these directories' permissions" logic for signed-output/ and
# docs/. Before this file, bootstrap.sh and upgrade.sh each carried their own
# `chmod 777` copy of this (and validate-config.sh told operators to do the
# same in its remediation text) - three independent places that could drift.
#
# signed-output/ is mounted into ps-server, which runs as root: there is no
# USER directive in psapp/server/Dockerfile, and the base image
# (node:18-alpine) defaults to root. Confirmed live via
#   docker run --rm --entrypoint id mihailsgordijenko/ps-server:<tag>
#   -> uid=0(root)
# Root bypasses host DAC permission checks on a normal (non-rootless,
# non-userns-remapped) Linux Docker install, so the container never actually
# needed mode 777 to write here - 777 only ever widened *host-side* exposure
# of what can be real signed customer documents (see
# documentation/35-receive-back-deployment-runbook.md). There is no clean
# narrower fix than this without adding a non-root USER to the ps-server image
# in the separate psapp repo - that's out of scope for this deployment repo,
# so this file does not pretend the container becomes non-root.
#
# docs/ is mounted into dmss-archive-services-fallback, which DOES run as a
# real non-root user. Confirmed live via
#   docker run --rm --entrypoint id trustlynx/dmss-archive-services-fallback:<tag> spring
#   -> uid=999(spring) gid=1000(spring)
# We resolve that gid at run time (reading whatever tag is actually pinned in
# docker-compose.yml) rather than hardcoding it, so a future image bump
# self-corrects instead of silently going stale. If resolution fails for any
# reason (image not pulled yet, offline, registry auth) we fall back to
# today's known value and say so loudly on stderr - never guess silently.
#
# Expects "$repo_root" to be set by the sourcing script.

dmss_fallback_image_repo="trustlynx/dmss-archive-services-fallback"
dmss_fallback_spring_gid_default=1000

# Prints the numeric gid of the pinned dmss-archive-services-fallback image's
# `spring` user, or the documented fallback with a stderr warning.
resolve_dmss_fallback_gid() {
  local compose_yml="${repo_root}/docker-compose.yml" tag image gid
  tag="$(grep -oP "${dmss_fallback_image_repo}:\K[0-9.]+" "$compose_yml" 2>/dev/null || true)"
  if [[ -z "$tag" ]]; then
    echo "  WARNING: could not find ${dmss_fallback_image_repo} tag in docker-compose.yml; using fallback gid ${dmss_fallback_spring_gid_default} for docs/" >&2
    echo "$dmss_fallback_spring_gid_default"
    return
  fi
  image="${dmss_fallback_image_repo}:${tag}"
  gid="$(docker run --rm --entrypoint id "$image" -g spring 2>/dev/null || true)"
  if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    echo "  WARNING: could not resolve 'spring' user's gid from ${image}; using fallback gid ${dmss_fallback_spring_gid_default} for docs/ (verify manually if dmss-archive-services-fallback can't write)" >&2
    echo "$dmss_fallback_spring_gid_default"
    return
  fi
  echo "$gid"
}

# mkdir -p + narrow permissions for signed-output/. No chown: the default
# ownership from mkdir is already correct, and root (what ps-server actually
# runs as) ignores the mode bits regardless.
fix_signed_output_permissions() {
  mkdir -p "${repo_root}/signed-output"
  chmod 750 "${repo_root}/signed-output" 2>/dev/null || true
}

# mkdir -p + narrow permissions for docs/. Group-owns it to
# dmss-archive-services-fallback's `spring` gid so the container can write
# without the directory being world-writable.
fix_docs_permissions() {
  local gid
  mkdir -p "${repo_root}/docs"
  gid="$(resolve_dmss_fallback_gid)"
  chgrp "$gid" "${repo_root}/docs" 2>/dev/null || true
  chmod 770 "${repo_root}/docs" 2>/dev/null || true
}
