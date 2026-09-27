#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Tests for upgrade.sh's rollback snapshot and rollback.sh (psapp-saas#12,
# #14): the snapshot records the ps-server / ps-client image that is RUNNING,
# rollback.sh restores exactly that and fails loudly when the result runs
# anything else, and the digest gate reports a verified rollback to an
# earlier approved release as a WARN.
#
# Usage:
#   ./installation-scripts/tests/test-rollback.sh
#
# Works on a throwaway copy of this checkout's tracked files (plus any
# uncommitted edits to them), made into its own git repository whose history
# has an older release approving ps-server 3.28 / ps-client 8.39 - the same
# shape as a deployment that ran `git pull` to the current release. `docker`
# and `cosign` are stubs (below) that simulate containers and images in a
# state directory, so nothing is pulled, started or contacted. The scripts
# get no stdin and a 15 s health wait: every simulated service is healthy at
# once, so a wait that does not end at once fails in seconds instead of
# running into the scripts' 480 s default.
#
# Under Git Bash on Windows this takes minutes, not seconds: every process
# start costs 50-150 ms there, and one upgrade.sh or rollback.sh run starts
# several hundred. Each PASS/FAIL line shows its seconds. A slow run is not a
# hang, so do not wrap it in a short `timeout`: the watchdog
# (lib/watchdog.sh) stops it after TEST_WATCHDOG_SECS (default 1200) and
# prints what was still running.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency,
# 124 the watchdog stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 2; }

unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR CI PADSIGN_REQUIRE_SIGNATURES
export PADSIGN_DIGEST_GATE_NO_DOCKER=1

work="$(mktemp -d)"
# TEST_ROLLBACK_KEEP=1 keeps the throwaway copy for debugging.
if [[ "${TEST_ROLLBACK_KEEP:-}" == 1 ]]; then
  trap 'echo "(kept ${work})"' EXIT
else
  trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
fi
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start
repo="${work}/repo"
mkdir -p "$repo"
(cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
  | (cd "$src_root" && xargs -0 cp --parents -t "$repo" 2>/dev/null) || true
rm -rf "${repo}/.rollback-snapshots" "${repo}/.rollback-applied.json" "${repo}/deployment-evidence.json"*
if command -v cygpath >/dev/null 2>&1; then repo_native="$(cygpath -m "$repo")"; else repo_native="$repo"; fi

pass=0
failed=0
case_t0=$SECONDS   # each result line shows the seconds since the previous one
ok_case()   { pass=$((pass + 1)); printf '  PASS %s (%ss)\n' "$1" "$((SECONDS - case_t0))"; case_t0=$SECONDS; }
fail_case() {
  failed=$((failed + 1)); printf '  FAIL %s (%ss)\n' "$1" "$((SECONDS - case_t0))"; case_t0=$SECONDS
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" | sed 's/^/       | /'; fi
  return 0
}

# ── Release values (read from the release files, never hardcoded) ──────────
jq_py() { python3 -c "$1" "${@:2}"; }
approved() {  # <key> <tag|digest>
  jq_py 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]][sys.argv[3]])' \
    "${repo_native}/release/approved-digests.json" "$1" "$2"
}
legacy() {  # <repository> <tag|digest>
  jq_py 'import json,sys
for e in json.load(open(sys.argv[1]))["images"]:
    if e["repository"] == sys.argv[2]: print(e[sys.argv[3]]); break' \
    "${repo_native}/release/unsigned-legacy-images.json" "$1" "$2"
}
new_srv_tag="$(approved ps-server tag)";  new_srv_dig="$(approved ps-server digest)"
new_cli_tag="$(approved ps-client tag)";  new_cli_dig="$(approved ps-client digest)"
old_srv_tag="$(legacy mihailsgordijenko/ps-server tag)"; old_srv_dig="$(legacy mihailsgordijenko/ps-server digest)"
old_cli_tag="$(legacy mihailsgordijenko/ps-client tag)"; old_cli_dig="$(legacy mihailsgordijenko/ps-client digest)"
fake() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
id_old_srv="$(fake id-old-srv)"; id_new_srv="$(fake id-new-srv)"
id_old_cli="$(fake id-old-cli)"; id_new_cli="$(fake id-new-cli)"
hotfix_dig="$(fake hotfix-digest)"; id_hotfix="$(fake id-hotfix)"

# ── git history: an older release approving the old tags, then this one ────
g() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
git init -q "$repo"
# Every g call must land in this repository, never in one around $work.
if [[ ! -d "${repo}/.git" || "$(g rev-parse --git-dir 2>/dev/null)" != ".git" ]]; then
  echo "ERROR: could not create a git repository in ${repo}" >&2; exit 2
fi
cp "${repo}/release/approved-digests.json" "${work}/approved-now.json"
python3 - "${repo_native}/release/approved-digests.json" "$old_srv_tag" "$old_srv_dig" "$old_cli_tag" "$old_cli_dig" <<'PY'
import json, sys
path, st, sd, ct, cd = sys.argv[1:]
data = json.load(open(path))
data["images"]["ps-server"].update(tag=st, digest=sd)
data["images"]["ps-client"].update(tag=ct, digest=cd)
json.dump(data, open(path, "w"), indent=2)
PY
g add -A >/dev/null
g commit -qm "release: old"
old_release_commit="$(g rev-parse HEAD)"
cp "${work}/approved-now.json" "${repo}/release/approved-digests.json"
g commit -qam "release: new"

# ── docker / cosign stubs ───────────────────────────────────────────────────
stubs="${work}/stubs"
export DSTATE="${work}/dstate"
mkdir -p "$stubs" "${DSTATE}/ctr"
cat > "${stubs}/cosign" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == version ]] && { echo '{"gitVersion": "v3.1.3"}'; exit 0; }
exit 0
EOF
cat > "${stubs}/docker" <<'EOF'
#!/usr/bin/env bash
# Simulated docker: images in $DSTATE/images.tsv
#   <id> <repository> <digest> <version label or -> <local tag or -> <local yes|no>
# and one file per compose service in $DSTATE/ctr/<svc>: "<cid> <ref> <image id>".
# Only bash builtins below: no $(...), awk, grep or sed. upgrade.sh and
# rollback.sh call docker ~35 times per run, and under Git Bash each process
# start costs 50-150 ms, so a helper pipeline in here cost the suite ~2 min.
echo "docker $*" >> "${DSTATE}/calls.log"
images="${DSTATE}/images.tsv"
find_image() {  # <id | repo@digest | repo:tag> -> $row: the images.tsv row of a LOCAL image
  local q="$1" id repo digest label tag here
  row=""
  while read -r id repo digest label tag here; do
    [[ "$here" == yes ]] || continue
    if [[ "$id" == "$q" || "${repo}@${digest}" == "$q" || ( "$tag" != - && "${repo}:${tag}" == "$q" ) ]]; then
      row="${id} ${repo} ${digest} ${label} ${tag} ${here}"; return 0
    fi
  done < "$images"
}
ctr_of_cid() {  # <cid> -> $ctr: the $DSTATE/ctr/<svc> file of that container
  local f c
  ctr=""
  for f in "${DSTATE}"/ctr/*; do
    [[ -f "$f" ]] || continue
    read -r c _ < "$f"
    [[ "$c" == "$1" ]] && { ctr="$f"; return 0; }
  done
}
compose_ref() {  # <svc> -> $ref: the image reference docker-compose.yml (cwd) pins
  local line re=".*(mihailsgordijenko/$1:[^'\" ]+)"
  ref=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ $re ]] && { ref="${BASH_REMATCH[1]}"; return 0; }
  done < docker-compose.yml
}
ref_row() {  # <ref> [any] -> $row: the images.tsv row for a reference (digest wins over tag)
  local want="$1" all="${2:-}" r d="" t="" id repo digest label tag here
  r="${want%%@*}"; r="${r%:*}"
  if [[ "$want" == *@* ]]; then d="${want#*@}"; else t="${want##*:}"; fi
  row=""
  while read -r id repo digest label tag here; do
    [[ "$repo" == "$r" && ( -n "$all" || "$here" == yes ) ]] || continue
    if [[ ( -n "$d" && "$digest" == "$d" ) || ( -z "$d" && "$tag" == "$t" ) ]]; then
      row="${id} ${repo} ${digest} ${label} ${tag} ${here}"; return 0
    fi
  done < "$images"
}
mark_local() {  # <image id>: the image is now on the host (last column "yes")
  local line out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "${line%% *}" == "$1" ]] && line="${line% *} yes"
    out+="${line}"$'\n'
  done < "$images"
  printf '%s' "$out" > "$images"
}
case "$1" in
  compose)
    shift
    sub="$1"; shift
    case "$sub" in
      version) echo "Docker Compose version v2.99.0-stub"; exit 0;;
      ps)
        if [[ " $* " != *" -q "* ]]; then
          for f in "${DSTATE}"/ctr/*; do [[ -f "$f" ]] && printf '%s\n' "${f##*/}"; done
          exit 0
        fi
        svc="${*: -1}"
        if [[ -f "${DSTATE}/ctr/${svc}" ]]; then read -r cid _ < "${DSTATE}/ctr/${svc}"; echo "$cid"; fi
        exit 0;;
      pull)
        for svc in "$@"; do
          [[ "$svc" == -* ]] && continue
          compose_ref "$svc"; [[ -z "$ref" ]] && continue
          ref_row "$ref" any
          [[ -z "$row" ]] && { echo "Error: pull access denied or manifest unknown for ${ref}" >&2; exit 1; }
          mark_local "${row%% *}"
        done
        exit 0;;
      up)
        [[ "${STUB_UP_NOOP:-}" == 1 ]] && exit 0
        for svc in "$@"; do
          [[ "$svc" == -* ]] && continue
          compose_ref "$svc"; [[ -z "$ref" ]] && continue
          ref_row "$ref"
          [[ -z "$row" ]] && { echo "Error: no such image ${ref}" >&2; exit 1; }
          if [[ -f "${DSTATE}/ctr/${svc}" ]]; then
            read -r _ running _ < "${DSTATE}/ctr/${svc}"
            [[ "$running" == "$ref" ]] && continue
          fi
          n=0; [[ -f "${DSTATE}/counter" ]] && read -r n < "${DSTATE}/counter"
          n=$((n + 1)); echo "$n" > "${DSTATE}/counter"
          echo "cid${n}x${svc} ${ref} ${row%% *}" > "${DSTATE}/ctr/${svc}"
        done
        exit 0;;
      restart|logs) exit 0;;
      *) exit 1;;
    esac;;
  inspect)
    fmt=""; [[ "$2" == --format ]] && { fmt="$3"; shift 2; }
    ctr_of_cid "$2"
    [[ -z "$ctr" ]] && exit 1
    read -r cid ref id < "$ctr"
    case "$fmt" in
      *Config.Image*) echo "$ref";;
      '{{.Image}}') echo "$id";;
      *State.Status*) echo "running healthy 0";;
      *RestartCount*) echo 0;;
      *) echo "";;
    esac
    exit 0;;
  image)
    [[ "$2" == inspect ]] || exit 1
    fmt=""; [[ "$3" == --format ]] && { fmt="$4"; shift 2; }
    find_image "$3"
    [[ -z "$row" ]] && { echo "Error: No such image: $3" >&2; exit 1; }
    read -r id repo digest label tag local <<< "$row"
    case "$fmt" in
      '') echo '[{}]';;
      '{{.Id}}') echo "$id";;
      *RepoDigests*) echo "${repo}@${digest}";;
      *image.version*) [[ "$label" == - ]] && echo '<no value>' || echo "$label";;
      *RepoTags*) [[ "$tag" != - ]] && echo "${repo}:${tag}"; echo;;
      *) echo "";;
    esac
    exit 0;;
  ps)
    for f in "${DSTATE}"/ctr/*; do
      [[ -f "$f" ]] || continue
      read -r _ ref _ < "$f"
      printf '  %s: %s (Up, healthy)\n' "${f##*/}" "$ref"
    done
    exit 0;;
  *) exit 1;;
esac
EOF
chmod +x "${stubs}/cosign" "${stubs}/docker"

reset_state() {  # <srv ref> <cli ref>: containers running these; every image local
  rm -f "${DSTATE}"/ctr/* "${DSTATE}/counter" "${DSTATE}/calls.log"
  cat > "${DSTATE}/images.tsv" <<EOF2
${id_old_srv} mihailsgordijenko/ps-server ${old_srv_dig} ${old_srv_tag} - yes
${id_new_srv} mihailsgordijenko/ps-server ${new_srv_dig} ${new_srv_tag} - yes
${id_old_cli} mihailsgordijenko/ps-client ${old_cli_dig} ${old_cli_tag} ${old_cli_tag} yes
${id_new_cli} mihailsgordijenko/ps-client ${new_cli_dig} ${new_cli_tag} - yes
${id_hotfix} mihailsgordijenko/ps-server ${hotfix_dig} - - yes
EOF2
  run_ctr ps-server "$1"
  run_ctr ps-client "$2"
  echo "cid0xnginx nginx:stub sha256:nginx" > "${DSTATE}/ctr/nginx"
  rm -rf "${repo}/.rollback-snapshots" "${repo}/.rollback-applied.json" "${repo}"/deployment-evidence.json*
  cp "${src_root}/config/config.js" "${repo}/config/config.js"
}
run_ctr() {  # <svc> <ref>
  local row
  row="$(awk -v r="${2%%@*}" -v d="${2#*@}" '{ split(r, a, ":") } $2 == a[1] && $3 == d { print $1; exit }' "${DSTATE}/images.tsv")"
  echo "cid-pre-$1 $2 ${row}" > "${DSTATE}/ctr/$1"
}
pin_compose() {  # <srv tag@digest> <cli tag@digest>
  sed -i -E "s|mihailsgordijenko/ps-server:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-server:$1|; s|mihailsgordijenko/ps-client:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-client:$2|" "${repo}/docker-compose.yml"
}
pins() {  # -> "srvtag@dig clitag@dig" as docker-compose.yml pins them
  printf '%s %s' \
    "$(sed -nE 's#.*mihailsgordijenko/ps-server:([^\x27" ]+).*#\1#p' "${repo}/docker-compose.yml" | tr -d '\r' | head -1)" \
    "$(sed -nE 's#.*mihailsgordijenko/ps-client:([^\x27" ]+).*#\1#p' "${repo}/docker-compose.yml" | tr -d '\r' | head -1)"
}
running() {  # -> "srvref clientref" of the simulated containers
  printf '%s %s' "$(cut -d' ' -f2 "${DSTATE}/ctr/ps-server")" "$(cut -d' ' -f2 "${DSTATE}/ctr/ps-client")"
}
manifest() {  # <dotted key>... -> their values, "|"-joined, from the latest snapshot's manifest
  local snap
  snap="$(cat "${repo}/.rollback-snapshots/latest")"
  command -v cygpath >/dev/null 2>&1 && snap="$(cygpath -m "$snap")"
  python3 - "${snap}/manifest.json" "$@" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
out = []
for key in sys.argv[2:]:
    v = m
    for part in key.split("."):
        v = (v or {}).get(part)
    out.append("" if v is None else str(v))
print("|".join(out))
PY
}
# The scripts under test never get stdin: one that reads it (a prompt, a
# `docker compose exec -T` without </dev/null) fails instead of waiting on
# the terminal the suite was started from.
in_repo() { (cd "$repo" && PATH="${stubs}:${PATH}" "$@" 2>&1 < /dev/null); }
# Every real upgrade.sh / rollback.sh run: see the header.
hw=(--health-timeout 15)
gate() {
  (
    repo_root="$repo_native"
    # shellcheck source=../lib/digests.sh
    . "${repo}/installation-scripts/lib/digests.sh"
    compose_images_prime
    digest_gate_check
  )
}

old_srv="mihailsgordijenko/ps-server:${old_srv_tag}@${old_srv_dig}"
old_cli="mihailsgordijenko/ps-client:${old_cli_tag}@${old_cli_dig}"
new_srv="mihailsgordijenko/ps-server:${new_srv_tag}@${new_srv_dig}"
new_cli="mihailsgordijenko/ps-client:${new_cli_tag}@${new_cli_dig}"

# ── 1. The bug: git pull first, then upgrade.sh, then rollback.sh ──────────
echo ""
echo "Pull before upgrade (docker-compose.yml already pins ${new_srv_tag} / ${new_cli_tag}, ${old_srv_tag} / ${old_cli_tag} running):"
reset_state "$old_srv" "$old_cli"
pin_compose "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"

set +e
out="$(in_repo bash installation-scripts/upgrade.sh --server-tag "$new_srv_tag" --client-tag "$new_cli_tag" --plan-only)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "ps-server: ${old_srv_tag} → ${new_srv_tag}" <<< "$out" \
   && grep -q "NOTE: docker-compose.yml pins ps-server ${new_srv_tag} but ${old_srv_tag} is running - the rollback snapshot records ${old_srv_tag}@${old_srv_dig}" <<< "$out" \
   && grep -q "ps-client: ${old_cli_tag} → ${new_cli_tag}" <<< "$out"; then
  ok_case "--plan-only shows the running tag as 'from' and says the pin already moved"
else
  fail_case "--plan-only running-vs-pinned (rc=${rc})" "$out"
fi
set +e
out="$(in_repo bash installation-scripts/upgrade.sh --server-tag "$new_srv_tag" --plan-only --plan-format machine)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -qx "server_tag_from=${old_srv_tag}" <<< "$out" && grep -qx "server_tag_pinned=${new_srv_tag}" <<< "$out" \
   && grep -qx "server_tag_to=${new_srv_tag}" <<< "$out"; then
  ok_case "machine plan: server_tag_from is the running tag, server_tag_pinned the pin"
else
  fail_case "machine plan (rc=${rc})" "$out"
fi

set +e
out="$(in_repo bash installation-scripts/upgrade.sh "${hw[@]}" --server-tag "$new_srv_tag" --client-tag "$new_cli_tag")"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "NOTE: docker-compose.yml pins ps-server ${new_srv_tag} but ${old_srv_tag} is running" <<< "$out" \
   && grep -q "ps-server: ${old_srv_tag} → ${new_srv_tag} (pinned to its approved digest)" <<< "$out" \
   && [[ "$(running)" == "${new_srv} ${new_cli}" ]]; then
  ok_case "upgrade: says so in Step 1/2 and ends running the new release"
else
  fail_case "upgrade run (rc=${rc}, running: $(running))" "$out"
fi
if [[ "$(manifest schema_version image_tags.ps-server image_digests.ps-server image_tags.ps-client image_digests.ps-client compose_pins.ps-server.tag)" \
      == "2|${old_srv_tag}|${old_srv_dig}|${old_cli_tag}|${old_cli_dig}|${new_srv_tag}" ]]; then
  ok_case "snapshot manifest records the RUNNING tag and digest, plus the pin"
else
  fail_case "snapshot manifest" "$(cat "$(cat "${repo}/.rollback-snapshots/latest")/manifest.json")"
fi

set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --yes)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && [[ "$(running)" == "${old_srv} ${old_cli}" ]] \
   && [[ "$(pins)" == "${old_srv_tag}@${old_srv_dig} ${old_cli_tag}@${old_cli_dig}" ]] \
   && grep -q "ps-server: running ${old_srv_tag}@${old_srv_dig} - the image the snapshot recorded" <<< "$out" \
   && cmp -s "${repo}/config/config.js" "${src_root}/config/config.js"; then
  ok_case "rollback restores ${old_srv_tag}@${old_srv_dig} / ${old_cli_tag}@${old_cli_dig} and verifies them"
else
  fail_case "rollback after pull-before-upgrade (rc=${rc}, running: $(running), pins: $(pins))" "$out"
fi

set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --yes)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && [[ "$(running)" == "${old_srv} ${old_cli}" ]]; then
  ok_case "rollback is idempotent (second run exit 0, same state)"
else
  fail_case "second rollback (rc=${rc})" "$out"
fi

# The digest gate on the rolled-back checkout.
gout="$(gate)"
if [[ "$(grep -c '^FAIL' <<< "$gout" || true)" == 0 ]] \
   && grep -qE "^WARN[[:space:]]ps-server: rolled back to mihailsgordijenko/ps-server:${old_srv_tag} by rollback.sh .* approved by release commit ${old_release_commit:0:12}" <<< "$gout" \
   && grep -qE "^WARN[[:space:]]ps-client: rolled back to .*Roll forward with upgrade.sh --client-tag ${new_cli_tag}" <<< "$gout"; then
  ok_case "digest gate: verified rollback to an earlier approved release is WARN, not FAIL"
else
  fail_case "digest gate after rollback" "$gout"
fi
mv "${repo}/.rollback-applied.json" "${work}/marker.json"
gout="$(gate)"
if [[ "$(grep -c '^FAIL' <<< "$gout" || true)" == 2 ]] && grep -q "ps-server: pinned digest (${old_srv_dig}) does not match" <<< "$gout"; then
  ok_case "digest gate: the same pins without rollback.sh's marker still FAIL"
else
  fail_case "digest gate without marker" "$gout"
fi
mv "${work}/marker.json" "${repo}/.rollback-applied.json"
mv "${repo}/.git" "${work}/dotgit"
gout="$(gate)"
mv "${work}/dotgit" "${repo}/.git"
if [[ "$(grep -c '^FAIL' <<< "$gout" || true)" == 2 ]] && grep -q "no committed revision of release/approved-digests.json ever approved" <<< "$gout"; then
  ok_case "digest gate: marker without git history approving the pin still FAILs, and says why"
else
  fail_case "digest gate without history" "$gout"
fi

# Rolling forward again drops the marker.
set +e
out="$(in_repo bash installation-scripts/upgrade.sh "${hw[@]}" --server-tag "$new_srv_tag" --client-tag "$new_cli_tag")"; rc=$?
set -e
if [[ $rc -eq 0 && ! -f "${repo}/.rollback-applied.json" ]] && ! grep -q "NOTE: docker-compose.yml pins" <<< "$out"; then
  ok_case "a later successful upgrade removes the rollback marker (no pin-drift note when they agree)"
else
  fail_case "roll forward (rc=${rc})" "$out"$'\n'"$(cat "${repo}/.rollback-applied.json" 2>/dev/null)"
fi

# ── 2. Normal case: the pin is what runs ────────────────────────────────────
echo ""
echo "Normal case (docker-compose.yml pins what runs):"
reset_state "$old_srv" "$old_cli"
pin_compose "${old_srv_tag}@${old_srv_dig}" "${old_cli_tag}@${old_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/upgrade.sh "${hw[@]}" --server-tag "$new_srv_tag" --client-tag "$new_cli_tag")"; rc=$?
set -e
if [[ $rc -eq 0 ]] && ! grep -q "NOTE: docker-compose.yml pins" <<< "$out" && [[ "$(running)" == "${new_srv} ${new_cli}" ]] \
   && [[ "$(manifest image_tags.ps-server image_digests.ps-server image_sources.ps-server)" \
         == "${old_srv_tag}|${old_srv_dig}|running container - tag from the container reference" ]]; then
  ok_case "upgrade: no drift note, snapshot records the running (= pinned) image"
else
  fail_case "normal upgrade (rc=${rc})" "$out"
fi
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --yes)"; rc=$?
set -e
if [[ $rc -eq 0 && "$(running)" == "${old_srv} ${old_cli}" ]] && ! grep -q WARNING <<< "$out"; then
  ok_case "rollback restores the old release without warnings"
else
  fail_case "normal rollback (rc=${rc}, running: $(running))" "$out"
fi

# Nothing running at snapshot time: the pin is the fallback.
reset_state "$old_srv" "$old_cli"
rm -f "${DSTATE}/ctr/ps-server"
pin_compose "${old_srv_tag}@${old_srv_dig}" "${old_cli_tag}@${old_cli_dig}"
snap="$(cd "$repo" && PATH="${stubs}:${PATH}" bash -c 'repo_root="$1"; . installation-scripts/lib/rollback-snapshot.sh; write_rollback_snapshot' _ "$repo_native" < /dev/null)"
if [[ "$(manifest image_tags.ps-server image_digests.ps-server image_sources.ps-server)" \
      == "${old_srv_tag}|${old_srv_dig}|docker-compose.yml (ps-server is not running)" ]]; then
  ok_case "service not running: snapshot falls back to docker-compose.yml's pin, and says so"
else
  fail_case "not-running fallback" "$(cat "${snap}/manifest.json")"
fi

# ── 3. Snapshots written by an older upgrade.sh (schema 1) ──────────────────
echo ""
echo "Legacy schema-1 snapshots:"
legacy_snapshot() {  # <name> <srv tag> <srv digest> <cli tag> <cli digest> <compose srv pin> <compose cli pin>
  local d="${repo}/.rollback-snapshots/$1"
  mkdir -p "$d"
  cp "${repo}/docker-compose.yml" "${d}/docker-compose.yml"
  cp "${src_root}/config/config.js" "${d}/config.js"
  sed -i -E "s|mihailsgordijenko/ps-server:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-server:$6|; s|mihailsgordijenko/ps-client:[0-9.]*(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-client:$7|" "${d}/docker-compose.yml"
  printf '{"schema_version": 1, "taken_at": "%s", "image_tags": {"ps-server": "%s", "ps-client": "%s"}, "image_digests": {"ps-server": %s, "ps-client": %s}}\n' \
    "$1" "$2" "$4" "$([[ -n "$3" ]] && printf '"%s"' "$3" || echo null)" "$([[ -n "$5" ]] && printf '"%s"' "$5" || echo null)" > "${d}/manifest.json"
}
after_upgrade() {  # the state a legacy rollback starts from: new release pinned and running
  reset_state "$new_srv" "$new_cli"
  pin_compose "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
}

# 3a: exactly the reported bug: tags from the post-pull compose file, digests from the old containers.
after_upgrade
legacy_snapshot 20260925T100000Z "$new_srv_tag" "$old_srv_dig" "$new_cli_tag" "$old_cli_dig" \
  "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100000Z --yes)"; rc=$?
set -e
if [[ $rc -eq 0 && "$(running)" == "${old_srv} ${old_cli}" ]] \
   && grep -q "WARNING: ps-server: the snapshot's docker-compose.yml pinned ${new_srv_tag}@${new_srv_dig}, but the container that was running then ran ${old_srv_dig} (${old_srv_tag}" <<< "$out"; then
  ok_case "schema 1, digests differ from the compose copy: trusts the digests, warns, restores ${old_srv_tag}/${old_cli_tag}"
else
  fail_case "schema-1 mismatch (rc=${rc}, running: $(running))" "$out"
fi

# 3b: same, but the old images are gone from the host: the tag comes from the release files.
after_upgrade
awk -v a="$id_old_srv" -v b="$id_old_cli" 'BEGIN{OFS=" "} $1 == a || $1 == b { $6 = "no" } { print }' "${DSTATE}/images.tsv" > "${DSTATE}/i" && mv "${DSTATE}/i" "${DSTATE}/images.tsv"
legacy_snapshot 20260925T100001Z "$new_srv_tag" "$old_srv_dig" "$new_cli_tag" "$old_cli_dig" \
  "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100001Z --yes)"; rc=$?
set -e
if [[ $rc -eq 0 && "$(running)" == "${old_srv} ${old_cli}" ]] && grep -q "from release/unsigned-legacy-images.json" <<< "$out"; then
  ok_case "schema 1 mismatch, old images pruned: tag found in the release files, pulled and verified"
else
  fail_case "schema-1 mismatch, pruned images (rc=${rc}, running: $(running))" "$out"
fi

# 3c: consistent schema-1 snapshot (no pull before that upgrade).
after_upgrade
legacy_snapshot 20260925T100002Z "$old_srv_tag" "$old_srv_dig" "$old_cli_tag" "$old_cli_dig" \
  "${old_srv_tag}@${old_srv_dig}" "${old_cli_tag}@${old_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100002Z --yes)"; rc=$?
set -e
if [[ $rc -eq 0 && "$(running)" == "${old_srv} ${old_cli}" ]] && ! grep -q WARNING <<< "$out"; then
  ok_case "schema 1, consistent: restored without warnings"
else
  fail_case "schema-1 consistent (rc=${rc})" "$out"
fi

# 3d: the oldest snapshots recorded the local image ID (classic image store).
after_upgrade
legacy_snapshot 20260925T100003Z "$old_srv_tag" "$id_old_srv" "$old_cli_tag" "$id_old_cli" \
  "${old_srv_tag}@${old_srv_dig}" "${old_cli_tag}@${old_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100003Z --yes)"; rc=$?
set -e
if [[ $rc -eq 0 && "$(running)" == "${old_srv} ${old_cli}" ]] && grep -q "recorded local image ID ${id_old_srv}; its registry digest is ${old_srv_dig}" <<< "$out"; then
  ok_case "schema 1 with a local image ID: mapped to the registry digest, verified by image ID"
else
  fail_case "schema-1 image ID (rc=${rc}, running: $(running))" "$out"
fi

# 3e: an unknown digest (not on the host, in no release file): the compose
# copy's pin is restored, and the check afterwards FAILS the rollback because
# the result does not run what the snapshot recorded.
after_upgrade
legacy_snapshot 20260925T100004Z "$new_srv_tag" "$(fake unknown)" "$new_cli_tag" "$new_cli_dig" \
  "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100004Z --yes)"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "ROLLBACK FAILED: ps-server: running ${new_srv_dig} .*but the snapshot recorded $(fake unknown)" <<< "$out" \
   && ! grep -q "Rollback complete" <<< "$out" && [[ ! -f "${repo}/.rollback-applied.json" ]]; then
  ok_case "unverifiable recorded digest: exit 1 ROLLBACK FAILED, never 'Rollback complete'"
else
  fail_case "unknown digest (rc=${rc})" "$out"
fi

# 3f: a mismatched digest whose tag nobody can name: refused, nothing changed.
after_upgrade
legacy_snapshot 20260925T100005Z "$new_srv_tag" "$hotfix_dig" "$new_cli_tag" "$new_cli_dig" \
  "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
before="$(sha256sum "${repo}/docker-compose.yml" "${repo}/config/config.js")"
set +e
out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --to 20260925T100005Z --yes)"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "Refusing to roll back" <<< "$out" && [[ "$before" == "$(sha256sum "${repo}/docker-compose.yml" "${repo}/config/config.js")" ]] \
   && ! grep -q '^docker compose pull' "${DSTATE}/calls.log"; then
  ok_case "mismatched digest with no known tag: refused before any change"
else
  fail_case "refusal (rc=${rc})" "$out"
fi

# ── 4. The restart did not take: rollback must fail, not report success ────
echo ""
echo "Verification:"
reset_state "$old_srv" "$old_cli"
pin_compose "${new_srv_tag}@${new_srv_dig}" "${new_cli_tag}@${new_cli_dig}"
in_repo bash installation-scripts/upgrade.sh "${hw[@]}" --server-tag "$new_srv_tag" --client-tag "$new_cli_tag" >/dev/null
set +e
out="$(cd "$repo" && STUB_UP_NOOP=1 PATH="${stubs}:${PATH}" bash installation-scripts/rollback.sh "${hw[@]}" --yes 2>&1 < /dev/null)"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "ROLLBACK FAILED: ps-server: running ${new_srv_dig}, but the snapshot recorded ${old_srv_dig} (${old_srv_tag})" <<< "$out" \
   && ! grep -q "Rollback complete" <<< "$out"; then
  ok_case "containers not recreated: exit 1 ROLLBACK FAILED naming both digests"
else
  fail_case "no-op restart (rc=${rc})" "$out"
fi

# ── 5. Snapshot permissions ─────────────────────────────────────────────────
echo ""
echo "Snapshot permissions:"
probe="${work}/probe"; : > "$probe"; chmod 600 "$probe"
if [[ "$(stat -c '%a' "$probe" 2>/dev/null)" != 600 ]]; then
  echo "  SKIP this filesystem does not keep POSIX modes (e.g. Git Bash on NTFS)"
else
  reset_state "$old_srv" "$old_cli"
  mkdir -p "${repo}/.rollback-snapshots/20200101T000000Z"
  : > "${repo}/.rollback-snapshots/20200101T000000Z/config.js"
  chmod 755 "${repo}/.rollback-snapshots" "${repo}/.rollback-snapshots/20200101T000000Z"
  chmod 644 "${repo}/.rollback-snapshots/20200101T000000Z/config.js"
  snap="$(cd "$repo" && umask 022 && PATH="${stubs}:${PATH}" bash -c 'repo_root="$1"; . installation-scripts/lib/rollback-snapshot.sh; write_rollback_snapshot' _ "$repo_native" < /dev/null)"
  modes="$(cd "${repo}/.rollback-snapshots" && stat -c '%a %n' . "$(basename "$snap")" "$(basename "$snap")"/* latest 20200101T000000Z 20200101T000000Z/config.js | sort -k2)"
  bad_modes="$(awk '($2 ~ /\// || $2 == "latest") && $1 != "600" { print } ($2 !~ /\// && $2 != "latest") && $1 != "700" { print }' <<< "$modes")"
  if [[ -z "$bad_modes" ]]; then
    ok_case "700 directories, 600 files (umask 022; an older 755/644 snapshot is tightened too)"
  else
    fail_case "snapshot modes" "$modes"
  fi
  # An older upgrade.sh's world-readable tree, then only rollback.sh runs.
  chmod -R go+rX "${repo}/.rollback-snapshots"
  set +e
  out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --yes)"; rc=$?
  set -e
  modes="$(cd "${repo}/.rollback-snapshots" && stat -c '%a %n' . * */* | sort -k2)"
  bad_modes="$(awk '($2 ~ /\// || $2 == "latest") && $1 != "600" { print } ($2 !~ /\// && $2 != "latest") && $1 != "700" { print }' <<< "$modes")"
  if [[ $rc -eq 0 && -z "$bad_modes" ]]; then
    ok_case "rollback.sh alone also tightens a 755/644 snapshot tree"
  else
    fail_case "rollback.sh tightening (rc=${rc})" "$modes"$'\n'"$out"
  fi
  if [[ "$(stat -c '%a' "${repo}/config/config.js")" == "$(stat -c '%a' "${src_root}/config/config.js")" ]]; then
    ok_case "config/config.js itself keeps its mode after the restore"
  else
    fail_case "config.js mode changed"
  fi
  if [[ "$(id -u)" != 0 ]]; then
    chmod 000 "${repo}/.rollback-snapshots"
    set +e
    out="$(in_repo bash installation-scripts/rollback.sh "${hw[@]}" --yes)"; rc=$?
    set -e
    chmod 700 "${repo}/.rollback-snapshots"
    if [[ $rc -eq 2 ]] && grep -q "exists but is not readable by" <<< "$out"; then
      ok_case "unreadable .rollback-snapshots/: exit 2 with the owner and how to run it"
    else
      fail_case "unreadable snapshots (rc=${rc})" "$out"
    fi
  fi
fi

echo ""
echo "${pass} passed, ${failed} failed."
[[ "$failed" -eq 0 ]]
