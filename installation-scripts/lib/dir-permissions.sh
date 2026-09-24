# shellcheck shell=bash
#
# Ownership and mode for the two host directories containers write into:
#
#   signed-output/  bind-mounted into ps-server (filesystem routing's
#                   durable archive + the receive-back .padsign-buffer/)
#   docs/           bind-mounted into dmss-archive-services-fallback
#                   (its document store)
#
# Both are sized to the uid the container image ACTUALLY runs as, read from
# the image docker-compose.yml pins right now - never a hardcoded uid. That
# matters because the uid changes under us:
#
#   - ps-server:  root in every image up to 3.29 (node:18-alpine, no USER);
#                 uid 1000 (`node`) from the Node 24 image on (psapp-saas#14).
#   - dmss-archive-services-fallback:  `spring` was 999:1000 up to 24.0.5 and
#                 is 10001:10001 in 24.1.7 (confirmed with
#                 `docker run --rm --entrypoint id <image>` on both).
#
# A container that runs as a non-root uid needs write access to EVERY
# directory in its tree, not just the top one: routing mkdirs into existing
# {company}/{email}/{YYYY-MM}/ directories, ack unlinks files out of
# .padsign-buffer/, and the fallback writes into existing docs/<a>/<b>/<c>/
# shards. A tree the previous image created (as root, or as the old uid) is
# not writable by the new one, and a chmod/chgrp on the top directory alone
# does not fix that. So when anything in the tree is not owned by the image's
# runtime uid, the whole tree is re-owned to it.
#
# The re-own runs on the host when this user can (root), and otherwise
# through a one-shot container of that same image run as root with the
# directory bind-mounted. Anyone who can run `docker compose` against this
# stack can already do that, so it needs no sudo and no guessing. If both
# fail, the functions print the exact fix and return non-zero: a container
# that cannot write here fails silently from the operator's point of view
# (routing failures are log-only; a docs/ failure surfaces as a misleading
# "Archive service rejected request" on every registerPDF), so the calling
# script must stop instead of carrying on.
#
# Root images: root bypasses host DAC checks, so nothing is re-owned; only
# the mode is narrowed. That is also why rolling ps-server back from the
# Node 24 image needs nothing here - root writes into a uid-1000 tree fine.
#
# Before this file, bootstrap.sh and upgrade.sh each carried a `chmod 777`
# copy of this logic; 777 only ever widened host-side exposure of what can be
# real signed customer documents (documentation/35-receive-back-deployment-runbook.md).
#
# Expects "$repo_root" to be set by the sourcing script.

ps_server_image_repo="mihailsgordijenko/ps-server"
dmss_fallback_image_repo="trustlynx/dmss-archive-services-fallback"

# Prints the image reference docker-compose.yml pins for <repository>
# (repo:tag or repo:tag@sha256:...), or nothing if there is no such line.
pinned_image_ref() {  # <repository>
  sed -nE "s|.*[\"' ](${1}:[0-9][0-9.]*(@sha256:[0-9a-f]+)?).*|\1|p" \
    "${repo_root}/docker-compose.yml" 2>/dev/null | tr -d '\r' | head -1
}

# Prints "<uid>:<gid>" <image-ref> runs as, read from the image itself, or
# returns 1 if that can't be determined (no docker, image not pullable, ...).
image_runtime_ids() {  # <image-ref>
  local ids
  [[ -z "$1" ]] && return 1
  command -v docker >/dev/null 2>&1 || return 1
  ids="$(docker run --rm --pull missing --entrypoint sh "$1" -c 'echo "$(id -u):$(id -g)"' 2>/dev/null | tr -d '\r')"
  [[ "$ids" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s' "$ids"
}

# Prints the first path under <dir> (inclusive) not owned by <uid>, or
# nothing. Once a tree belongs to a container uid with a 750/770 mode, this
# (non-root) user can no longer traverse it, and a host-side `find` would
# then see nothing and wrongly report "all owned" - so any unreadable tree is
# searched from inside a one-shot root container of <image-ref> instead.
# Returns 1 if the tree could not be searched at all.
first_foreign_path() {  # <dir> <uid> <image-ref>
  local out
  if out="$(find "$1" ! -user "$2" -print -quit 2>/dev/null)"; then
    printf '%s' "$out"
    return 0
  fi
  [[ -n "$3" ]] || return 1
  out="$(docker run --rm --user 0:0 -v "${1}:/target:ro" --entrypoint find "$3" /target ! -user "$2" -print -quit 2>/dev/null)" || return 1
  printf '%s' "${out/#\/target/$1}"
}

# Runs <cmd...> against <dir> on the host, or failing that inside a one-shot
# root container of <image-ref> with <dir> mounted at /target. <cmd...> gets
# the literal word TARGET where the directory goes.
run_on_dir() {  # <dir> <image-ref> <cmd> [args...] (TARGET = the directory)
  local dir="$1" ref="$2"; shift 2
  local host_args=() ctr_args=() a
  for a in "$@"; do
    host_args+=("${a/#TARGET/$dir}")
    ctr_args+=("${a/#TARGET//target}")
  done
  "${host_args[@]}" 2>/dev/null && return 0
  [[ -n "$ref" ]] || return 1
  docker run --rm --user 0:0 -v "${dir}:/target" --entrypoint "${ctr_args[0]}" "$ref" "${ctr_args[@]:1}" >/dev/null 2>&1
}

# mkdir -p <dir>, then make it (and everything in it) writable by whatever
# uid <repository>'s pinned image runs as, with <mode> on the top directory.
# Returns 1 (after printing the fix) if that could not be achieved.
ensure_dir_for_image() {  # <dir> <repository> <mode> <label>
  local dir="$1" repo="$2" mode="$3" label="$4" ref ids uid gid foreign
  mkdir -p "$dir"
  ref="$(pinned_image_ref "$repo")"

  if ! ids="$(image_runtime_ids "$ref")"; then
    chmod "$mode" "$dir" 2>/dev/null || true
    echo "  WARNING: could not determine which uid ${ref:-$repo} runs as, so ${label}/" >&2
    echo "           ownership was NOT checked. Check it with:" >&2
    echo "             docker run --rm --entrypoint id ${ref:-<${repo} image>}" >&2
    echo "           and if that is not root: sudo chown -R <uid>:<gid> ${dir}" >&2
    return 0
  fi
  uid="${ids%%:*}"; gid="${ids##*:}"

  if [[ "$uid" == 0 ]]; then
    chmod "$mode" "$dir" 2>/dev/null || true
    echo "  ${label}/: ${ref} runs as root - mode ${mode}, ownership left as is"
    return 0
  fi

  foreign="$(first_foreign_path "$dir" "$uid" "$ref")" || foreign="$dir"
  if [[ -n "$foreign" ]]; then
    echo "  ${label}/: ${ref} runs as ${uid}:${gid}; re-owning (first mismatch: ${foreign#"${repo_root}/"})"
    run_on_dir "$dir" "$ref" chown -R "${uid}:${gid}" TARGET || true
  fi
  run_on_dir "$dir" "$ref" chmod "$mode" TARGET || true

  if ! foreign="$(first_foreign_path "$dir" "$uid" "$ref")"; then
    echo "  ERROR: could not inspect ${dir} (neither as this user nor via ${ref})." >&2
    echo "         Make sure it is owned by ${uid}:${gid}, then re-run:" >&2
    echo "           sudo chown -R ${uid}:${gid} ${dir} && sudo chmod ${mode} ${dir}" >&2
    return 1
  fi
  if [[ -n "$foreign" ]]; then
    echo "  ERROR: ${foreign} is not owned by ${uid}, the user ${ref} runs as," >&2
    echo "         so that container cannot write into ${label}/. Fix it, then re-run:" >&2
    echo "           sudo chown -R ${uid}:${gid} ${dir} && sudo chmod ${mode} ${dir}" >&2
    return 1
  fi
  echo "  ${label}/: owned by ${uid}:${gid} (the user ${ref} runs as), mode ${mode}"
}

# Kept for existing callers and messages: the fallback image's gid, or the
# documented default with a warning.
dmss_fallback_spring_gid_default=10001
resolve_dmss_fallback_gid() {
  local ids
  if ids="$(image_runtime_ids "$(pinned_image_ref "$dmss_fallback_image_repo")")"; then
    echo "${ids##*:}"
  else
    echo "  WARNING: could not resolve the gid ${dmss_fallback_image_repo} runs as; using ${dmss_fallback_spring_gid_default}" >&2
    echo "$dmss_fallback_spring_gid_default"
  fi
}

fix_signed_output_permissions() {
  ensure_dir_for_image "${repo_root}/signed-output" "$ps_server_image_repo" 750 signed-output
}

fix_docs_permissions() {
  ensure_dir_for_image "${repo_root}/docs" "$dmss_fallback_image_repo" 770 docs
}
