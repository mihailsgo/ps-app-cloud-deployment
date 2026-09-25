# shellcheck shell=bash
#
# Ownership and mode for the two host directories containers write into:
#
#   signed-output/  bind-mounted into ps-server (filesystem routing's
#                   durable archive + the receive-back .padsign-buffer/)
#   docs/           bind-mounted into dmss-archive-services-fallback
#                   (its document store)
#
# and for config/config.js, which ps-server only reads (see the section at
# the end of this file).
#
# All are sized to the uid the container image ACTUALLY runs as, read from
# the image the effective compose model (docker-compose.yml plus any
# COMPOSE_FILE overlay) pins right now - never a hardcoded uid. That matters
# because the uid changes under us:
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

# Prints the image reference the EFFECTIVE compose model pins for
# <repository> (repo:tag or repo:tag@sha256:...), or nothing if no service
# uses it. Effective = what `docker compose up` runs here: docker-compose.yml
# plus any COMPOSE_FILE overlay, as lib/digest_gate.py (the digest gate's own
# model) reads it. An environment overlay can pin another tag than the
# release (a host kept on dmss-archive-services-fallback 24.0.5, uid 999,
# where the release has 24.1.7, uid 10001), and the uid that matters is the
# one of the image that actually runs. Falls back to docker-compose.yml alone
# when the model cannot be read. Rendered fresh on every call on purpose:
# upgrade.sh calls this right after rewriting the image tags, and a model
# cached before that would still name the old image.
pinned_image_ref() {  # <repository>
  local ref=""
  if command -v python3 >/dev/null 2>&1 && [[ -f "${repo_root}/installation-scripts/lib/digest_gate.py" ]]; then
    ref="$(python3 "${repo_root}/installation-scripts/lib/digest_gate.py" images "$repo_root" 2>/dev/null \
      | tr -d '\r' | cut -f2 | grep -E "^${1}:[0-9][0-9.]*(@sha256:[0-9a-f]+)?$" | head -1 || true)"
  fi
  if [[ -z "$ref" ]]; then
    ref="$(sed -nE "s|.*[\"' ](${1}:[0-9][0-9.]*(@sha256:[0-9a-f]+)?).*|\1|p" \
      "${repo_root}/docker-compose.yml" 2>/dev/null | tr -d '\r' | head -1)"
  fi
  printf '%s' "$ref"
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

# ── config/config.js: a file ps-server only READS ──────────────────────────
#
# config/config.js is bind-mounted into ps-server and holds the Keycloak
# backend client secret, REGISTER_PDF_API_KEY, SESSION_SECRET and the
# stamping credentials, so it should not be world-readable. But ps-server has
# to be able to read it, or it crash-loops with EACCES on its next start.
# While ps-server ran as root (up to 3.29) `chmod o-rwx` was enough; the
# Node 24 image (3.30, psapp-saas#14) runs as uid 1000, and a root:root 640
# config.js locks it out (seen on a real 3.30 install). So the file keeps its
# owner (whoever edits it), gets the image's gid as its group, and mode 640.
#
# That group only survives later edits if the user making them may set it.
# perl -i and sed -i (configure-host.sh, upgrade.sh) write a NEW file as the
# user running them and then try to restore the old group, which the kernel
# allows only root and members of that group; a text editor usually rewrites
# in place and keeps it. So the restriction is applied only when this user is
# root, is the image's uid, or is in the image's gid - and in every case the
# result is checked by reading the file from inside the image, so config.js
# always ends up readable by ps-server.

# Returns 0 if <uid>:<gid> can read <file> by its owner/group/mode bits
# (ignores supplementary groups), 1 if not, 2 if the file can't be stat'ed.
ids_can_read() {  # <uid> <gid> <file>
  local st ou og m
  st="$(stat -c '%u %g %a' "$3" 2>/dev/null || stat -f '%u %g %Lp' "$3" 2>/dev/null)" || return 2
  read -r ou og m <<< "$st"
  [[ "$m" =~ ^[0-7]+$ ]] || return 2
  m=$((8#$m))
  [[ "$1" == 0 ]] && return 0
  if [[ "$ou" == "$1" ]]; then (( m & 8#400 )) && return 0; return 1; fi
  if [[ "$og" == "$2" ]]; then (( m & 8#040 )) && return 0; return 1; fi
  (( m & 8#004 )) && return 0
  return 1
}

# Reads <file> as <image-ref>'s own user, from inside a one-shot container
# with no network. Returns 0 readable, 1 permission denied, 2 could not check.
file_readable_by_image() {  # <file> <image-ref>
  local out
  [[ -n "$2" ]] || return 2
  command -v docker >/dev/null 2>&1 || return 2
  out="$(docker run --rm --pull missing --network none -v "${1}:/padsign-probe:ro" --entrypoint sh "$2" \
    -c 'cat /padsign-probe >/dev/null 2>&1 && echo READABLE || echo DENIED' 2>/dev/null | tr -d '\r')"
  case "$out" in
    READABLE) return 0 ;;
    DENIED) return 1 ;;
    *) return 2 ;;
  esac
}

user_in_group() {  # <gid>
  # A here-string, not `id -G | ... | grep -q`: under the callers' pipefail a
  # grep -q that exits at the match can turn it into a miss (v1.0.43).
  grep -qx -- "$1" <<< "$(id -G 2>/dev/null | tr ' ' '\n')"
}

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

other_can_read() {  # <file>: the "other" read bit is set
  local m
  m="$(file_mode "$1")"
  [[ "$m" =~ ^[0-7]+$ ]] && (( 8#$m & 8#004 ))
}

# Restricts config/config.js as described above and checks the ps-server
# image of the effective compose model can still read it. Prints what it did.
#
# Default (bootstrap / configure-host.sh): never fails the caller. If the
# image cannot read the file afterwards, it is made readable by all users
# again - a world-readable config.js is validate-config.sh's WARN, one
# ps-server cannot read is an outage.
#
# --strict (overlay.sh apply): never widens the mode. If the image cannot
# read the file, prints the fix and returns 1, so apply fails before the
# cut-over instead of ps-server crash-looping on `docker compose up`.
secure_config_js() {  # [--strict]
  local strict=false f="${repo_root}/config/config.js" ref ids uid gid me restricted=false rc
  [[ "${1:-}" == --strict ]] && strict=true
  [[ -f "$f" ]] || return 0
  ref="$(pinned_image_ref "$ps_server_image_repo")"
  if ! ids="$(image_runtime_ids "$ref")"; then
    echo "  config/config.js: could not determine which uid ${ref:-the ps-server image} runs as - mode left as is ($(file_mode "$f"))"
    [[ "$strict" == true ]] && return 2
    return 0
  fi
  uid="${ids%%:*}"; gid="${ids##*:}"; me="$(id -u)"

  if [[ "$uid" == 0 ]]; then
    # Nothing to gain that survives an upgrade: the next ps-server image may
    # run as a non-root uid again, and a 640 file with some other group would
    # then lock it out. validate-config.sh reports the mode.
    echo "  config/config.js: ${ref} runs as root - mode left as is ($(file_mode "$f"))"
    return 0
  fi

  if [[ "$me" == 0 || "$me" == "$uid" ]] || user_in_group "$gid"; then
    chgrp "$gid" "$f" 2>/dev/null || true
    chmod 640 "$f" 2>/dev/null && restricted=true
  fi

  rc=0
  ids_can_read "$uid" "$gid" "$f" || rc=1
  # The bits say nothing about user namespaces or a remapped daemon: ask the
  # image itself whenever we just restricted the file, or the bits say no.
  if [[ "$restricted" == true || "$rc" != 0 ]]; then
    rc=0
    file_readable_by_image "$f" "$ref" || rc=$?
    # Could not ask (no docker run): fall back to the bits.
    if [[ "$rc" == 2 ]]; then
      rc=0
      ids_can_read "$uid" "$gid" "$f" || rc=1
    fi
  fi

  if [[ "$rc" != 0 ]]; then
    if [[ "$strict" == true ]]; then
      echo "  ERROR: ${ref} runs as ${ids} and cannot read config/config.js (mode $(file_mode "$f"))," >&2
      echo "         so ps-server would crash-loop with EACCES. Fix, then re-run:" >&2
      echo "           sudo chgrp ${gid} config/config.js && sudo chmod 640 config/config.js" >&2
      return 1
    fi
    chmod o+r "$f" 2>/dev/null || true
    echo "  WARNING: ${ref} (runs as ${ids}) could not read config/config.js; it was made readable" >&2
    echo "           by all users again so ps-server can start. Restrict it by hand once you can:" >&2
    echo "             sudo chgrp ${gid} config/config.js && sudo chmod 640 config/config.js" >&2
    return 0
  fi
  if [[ "$restricted" == true ]]; then
    echo "  config/config.js: group ${gid}, mode 640 - readable by ${ref} (${ids}), not by other users"
  elif other_can_read "$f"; then
    # Still world-readable, and deliberately not restricted.
    echo "  config/config.js: left at mode $(file_mode "$f"): $(id -un 2>/dev/null || echo "uid ${me}") is not root, uid ${uid} or in group ${gid},"
    echo "    so a later script edit would drop the group and lock ps-server out. Run the installation"
    echo "    scripts as root or as a member of group ${gid} to have it restricted (documentation/22)."
  else
    echo "  config/config.js: mode $(file_mode "$f"), readable by ${ref} (${ids})"
  fi
}

# Prints one "<OK|WARN|FAIL><TAB><message>" line: can the ps-server image of
# the effective compose model read config/config.js, and is it kept from
# other users - with the fix that fits the uid:gid that image runs as.
# Shared by validate-config.sh and overlay.sh verify, so they check exactly
# what secure_config_js sets up. Checks the bits first and only asks the
# image (a one-shot container) when the bits say it cannot read.
config_js_access_report() {
  local f="${repo_root}/config/config.js" ref ids uid gid rc fix
  [[ -f "$f" ]] || { printf 'FAIL\tconfig/config.js missing\n'; return 0; }
  ref="$(pinned_image_ref "$ps_server_image_repo")"
  if ! ids="$(image_runtime_ids "$ref")"; then
    if other_can_read "$f"; then
      printf 'WARN\tconfig/config.js is world-readable (mode %s) and holds credentials. Could not tell which uid %s runs as, so no safe fix to suggest: check with docker run --rm --entrypoint id %s, and for a non-root uid set the group to its gid before chmod 640 (chmod o-rwx alone locks such an image out)\n' \
        "$(file_mode "$f")" "${ref:-the ps-server image}" "${ref:-<ps-server image>}"
    else
      printf 'OK\tconfig/config.js is not world-readable (mode %s; could not check which uid %s runs as)\n' "$(file_mode "$f")" "${ref:-the ps-server image}"
    fi
    return 0
  fi
  uid="${ids%%:*}"; gid="${ids##*:}"
  fix="sudo chgrp ${gid} config/config.js && sudo chmod 640 config/config.js"

  rc=0
  ids_can_read "$uid" "$gid" "$f" || rc=1
  if [[ "$rc" != 0 ]]; then
    rc=0
    file_readable_by_image "$f" "$ref" || rc=$?
  fi
  case "$rc" in
    1)
      printf 'FAIL\tconfig/config.js cannot be read by %s, the uid:gid %s runs as (mode %s) - ps-server crash-loops with EACCES on its next start. Fix: %s\n' \
        "$ids" "$ref" "$(file_mode "$f")" "$fix"
      return 0 ;;
    2)
      printf 'WARN\tconfig/config.js: its owner/group/mode do not let %s (%s) read it, and that could not be checked from inside the image - make sure ps-server can start. Fix: %s\n' \
        "$ref" "$ids" "$fix"
      return 0 ;;
  esac
  if ! other_can_read "$f"; then
    printf 'OK\tconfig/config.js is not world-readable, and %s (%s) can read it\n' "$ref" "$ids"
  elif [[ "$uid" == 0 ]]; then
    printf 'WARN\tconfig/config.js is world-readable (mode %s) and holds credentials. %s runs as root, so chmod 640 config/config.js is safe for it - but a non-root ps-server image (3.30 and later run as uid 1000) would then need the file'"'"'s group set to its gid: re-run this check after such an upgrade\n' \
      "$(file_mode "$f")" "$ref"
  else
    # Who can apply it for you: never configure-host.sh on an overlay-managed
    # checkout, which is not edited in place (documentation/42-06).
    local who="configure-host.sh does this for you when run as root or as a member of group ${gid}"
    [[ -f "${repo_root}/.overlay-applied.json" ]] && who="overlay.sh apply does this for you when run as root"
    printf 'WARN\tconfig/config.js is world-readable (mode %s) and holds credentials. Fix: %s - %s runs as %s and then reads it through group %s (chmod o-rwx alone would lock it out unless the file already belongs to that uid or group). %s\n' \
      "$(file_mode "$f")" "$fix" "$ref" "$ids" "$gid" "$who"
  fi
}
