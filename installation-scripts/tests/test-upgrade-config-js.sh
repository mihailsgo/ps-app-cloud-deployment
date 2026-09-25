#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for upgrade.sh's handling of config/config.js (psapp-saas#7, #12):
#
#   - pre-flight: the ps-server image the upgrade ends on must be able to read
#     config.js. Otherwise it refuses before the snapshot, any edit or any
#     pull, and prints the exact chgrp/chmod fix;
#   - Step 4e re-applies the ownership model (group = image gid, mode 640)
#     after the run's own perl -i rewrite of config.js, which drops a group
#     the user running it may not set;
#   - the *.bak copies upgrade.sh and update-hostname.sh write are 0600.
#
# Usage:
#   ./installation-scripts/tests/test-upgrade-config-js.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` is a stub (`compose config` / `version` go to the real
# docker when there is one; `run` fakes the image uid:gid and the in-image
# read probe; everything else fails, so every upgrade stops at its image
# pull). `cosign` is a stub that verifies. The file-mode cases need real
# POSIX modes: Linux only (Git Bash on NTFS has none).
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git perl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER
unset CI PADSIGN_REQUIRE_SIGNATURES KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true
real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi
real_perl="$(command -v perl)"

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

copy_tree() {  # <dest>: tracked files as they are on disk now
  mkdir -p "$1"
  (cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$src_root" && xargs -0 cp --parents -t "$1" 2>/dev/null) || true
}

# ── stubs ───────────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/stub-argv.log" REAL_DOCKER="$real_docker" STUB_IDS="$(id -u):$(id -g)"
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1" in
  compose)
    for a in "$@"; do
      if [[ "$a" == config || "$a" == version ]]; then
        [[ -n "${REAL_DOCKER:-}" ]] && exec "$REAL_DOCKER" "$@"
        exit 1
      fi
    done
    exit 1 ;;
  run)
    if [[ "$*" == *padsign-probe* ]]; then
      args=("$@")
      for ((i = 0; i < ${#args[@]}; i++)); do
        [[ "${args[$i]}" == -v ]] && src="${args[$((i + 1))]%%:/padsign-probe*}"
      done
      read -r ou og m <<< "$(stat -c '%u %g %a' "$src")"
      uid="${STUB_IDS%%:*}"; gid="${STUB_IDS##*:}"; m=$((8#$m))
      if [[ "$uid" == 0 ]] || { [[ "$ou" == "$uid" ]] && (( m & 8#400 )); } \
         || { [[ "$ou" != "$uid" && "$og" == "$gid" ]] && (( m & 8#040 )); } \
         || { [[ "$ou" != "$uid" && "$og" != "$gid" ]] && (( m & 8#004 )); }; then
        echo READABLE
      else
        echo DENIED
      fi
      exit 0
    fi
    if [[ "$*" == *'id -u'* ]]; then echo "$STUB_IDS"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
cat > "${bin}/cosign" <<'STUB'
#!/usr/bin/env bash
printf 'cosign %s\n' "$*" >> "$STUB_LOG"
[[ "$1" == version ]] && echo '{"gitVersion": "v3.1.3"}'
exit 0
STUB
chmod +x "${bin}/docker" "${bin}/cosign"
export PATH="${bin}:${PATH}"

# perl -i as a user who may not set the file's group: the rewritten file gets
# the user's primary group, as the kernel does for a non-member.
dropbin="${work}/dropbin"
mkdir -p "$dropbin"
cat > "${dropbin}/perl" <<STUB
#!/usr/bin/env bash
"${real_perl}" "\$@"; rc=\$?
inplace=false
for a in "\$@"; do [[ "\$a" == -i* ]] && inplace=true; last="\$a"; done
[[ "\$inplace" == true && -f "\$last" ]] && chgrp "\$(id -g)" "\$last"
exit \$rc
STUB
chmod +x "${dropbin}/perl"

pristine="${work}/pristine"
copy_tree "$pristine"
approved() {  # <key> -> approved tag
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["tag"])' \
    "$(native "${pristine}/release/approved-digests.json")" "$1"
}
srv_ok="$(approved ps-server)"; cli_ok="$(approved ps-client)"

fresh() {  # <name>: a new throwaway copy, config.js mode 640, printed path
  local d="${work}/$1"
  copy_tree "$d"
  chmod 640 "$d/config/config.js"
  printf '%s' "$d"
}
upgrade() {  # <repo> [args...]
  local d="$1"; shift
  : > "$STUB_LOG"
  (cd "$d" && bash installation-scripts/upgrade.sh "$@" 2>&1)
}
fingerprint() { (cd "$1" && sha256sum docker-compose.yml config/config.js); }
nothing_written() {  # <repo> <fingerprint before>
  [[ "$2" == "$(fingerprint "$1")" ]] && ! ls -A "$1" "$1/config" | grep -qE '\.bak$|^deployment-evidence|^\.rollback-snapshots$' \
    && ! grep -q '^docker compose .*pull' "$STUB_LOG"
}
mode_group() { stat -c '%a %g' "$1"; }

# Keep upgrade.sh's storage step out of these cases: the stores are mounted
# from outside the checkout (as on an overlay host), which upgrade.sh leaves
# alone, so no case depends on who may own an in-tree signed-output/.
external_storage() {  # <repo>
  mkdir -p "${work}/storage-$(basename "$1")/signed-output" "${work}/storage-$(basename "$1")/docs"
  cat > "$1/docker-compose.override.yml" <<EOF
services:
  ps-server:
    volumes:
      - "$(native "${work}/storage-$(basename "$1")")/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - "$(native "${work}/storage-$(basename "$1")")/docs:/docs"
EOF
}

# ── lint: every .bak copy goes through backup_owner_only ────────────────────
echo ""
echo "*.bak copies:"
bare="$(grep -nE 'cp -f? *"[^"]*" *"[^"]*\.bak"' "${src_root}/installation-scripts/upgrade.sh" "${src_root}/installation-scripts/update-hostname.sh" || true)"
check "upgrade.sh / update-hostname.sh make no bare cp ... .bak copy" test -z "$bare"

if [[ "$linux" != true ]]; then
  echo ""
  echo "(the file-mode cases need Linux - skipped)"
  echo ""
  echo "================================"
  echo "${pass} passed, ${failed} failed"
  [[ "$failed" == 0 ]]
  exit
fi

d="$(fresh bak)"
printf 'old\n' > "$d/config/config.js.bak"; chmod 644 "$d/config/config.js.bak"
chmod 644 "$d/config/config.js"
(repo_root="$d" bash -c '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; backup_owner_only "$repo_root/config/config.js"; backup_owner_only "$repo_root/docker-compose.yml"')
check "backup_owner_only: an existing 644 .bak ends 600, with the new content" \
  bash -c '[[ "$(stat -c %a "$1.bak")" == 600 ]] && cmp -s "$1" "$1.bak"' _ "$d/config/config.js"
check "backup_owner_only: a new .bak is 600" test "$(stat -c %a "$d/docker-compose.yml.bak")" = 600

# ── pre-flight: the target ps-server image must read config.js ─────────────
echo ""
echo "upgrade.sh config.js pre-flight:"
d="$(fresh refuse)"
before="$(fingerprint "$d")"
out="$(STUB_IDS=4242:4242 upgrade "$d" --server-tag "$srv_ok" --client-tag "$cli_ok")"; rc=$?
check "an image uid that cannot read config.js: refused, exit 1" test "$rc" = 1
check "... names the image, its uid:gid and the exact fix" \
  bash -c 'grep -q "ERROR: mihailsgordijenko/ps-server:$2@sha256:[0-9a-f]* runs as 4242:4242 and cannot read config/config.js" <<< "$1" \
    && grep -qF "sudo chgrp 4242 config/config.js && sudo chmod 640 config/config.js" <<< "$1"' _ "$out" "$srv_ok"
check "... before Step 1: no snapshot, no .bak, no edit, no pull" nothing_written "$d" "$before"
check "... after the signature pre-flight" \
  bash -c 'grep -q "^Pre-flight: verifying image signatures" <<< "$1" && ! grep -q "^Step 1/6" <<< "$1"' _ "$out"

out="$(STUB_IDS=4242:4242 upgrade "$d" --enable-local-eseal)"; rc=$?
check "--enable-local-eseal alone (restarts ps-server on the current pin): refused too" \
  bash -c '[[ "$1" == 1 ]] && grep -q "runs as 4242:4242 and cannot read config/config.js" <<< "$2"' _ "$rc" "$out"
check "... nothing written" nothing_written "$d" "$before"

chmod 644 "$d/config/config.js"
out="$(STUB_IDS=4242:4242 upgrade "$d" --server-tag "$srv_ok" --plan-only)"; rc=$?
check "--plan-only never runs the pre-flight (no docker run)" \
  bash -c '[[ "$1" == 0 ]] && ! grep -q "^docker run" "$2"' _ "$rc" "$STUB_LOG"
chmod 640 "$d/config/config.js"

# ── a run that passes the pre-flight ────────────────────────────────────────
echo ""
echo "upgrade.sh, pre-flight passed:"
d="$(fresh pass)"
external_storage "$d"
chmod 644 "$d/config/config.js"
printf 'old\n' > "$d/config/config.js.bak"; chmod 644 "$d/config/config.js.bak"
gid="$(id -g)"
for g in $(id -G); do [[ "$g" != "$(id -g)" ]] && { gid="$g"; break; }; done
out="$(STUB_IDS="$(id -u):${gid}" upgrade "$d" --server-tag "$srv_ok" --client-tag "$cli_ok")"; rc=$?
check "pre-flight passes, then Step 1 (the stub pull then fails the run, rc=${rc})" \
  bash -c 'grep -q "config/config.js: readable by mihailsgordijenko/ps-server" <<< "$1" && grep -q "^Step 1/6" <<< "$1" && grep -q "UPGRADE FAILED: could not pull" <<< "$1"' _ "$out"
check "Step 1: config.js.bak and docker-compose.yml.bak are 600 (an old 644 .bak included)" \
  bash -c '[[ "$(stat -c %a "$1/config/config.js.bak")" == 600 && "$(stat -c %a "$1/docker-compose.yml.bak")" == 600 ]]' _ "$d"
check "Step 4e: config.js is 640 with the image's group (was 644)" test "$(mode_group "$d/config/config.js")" = "640 ${gid}"
check "... and says so" grep -q "config/config.js: group ${gid}, mode 640 - readable by" <<< "$out"
check "storage mounted from outside the checkout: left alone, nothing created in the tree" \
  bash -c '[[ ! -e "$1/signed-output" && ! -e "$1/docs" ]] && grep -q "signed-output/: mounted from .* left as it is" <<< "$2"' _ "$d" "$out"

# ── perl -i dropping the group, then Step 4e ───────────────────────────────
echo ""
echo "upgrade.sh --enable-local-eseal, config.js rewritten by a user who may not keep its group:"
sec=""
for g in $(id -G); do [[ "$g" != "$(id -g)" ]] && { sec="$g"; break; }; done
if [[ -z "$sec" ]]; then
  echo "  (this user has no supplementary group to give config.js - skipped)"
else
  d="$(fresh drop)"
  external_storage "$d"
  chgrp "$sec" "$d/config/config.js"; chmod 640 "$d/config/config.js"
  out="$(STUB_IDS="4242:${sec}" PATH="${dropbin}:${PATH}" upgrade "$d" --enable-local-eseal)"; rc=$?
  check "pre-flight passes: uid 4242 reads config.js through group ${sec}" grep -q 'config/config.js: readable by' <<< "$out"
  check "Step 4b rewrote config.js (STAMP_MODE local)" grep -q 'STAMP_MODE: "local"' "$d/config/config.js"
  probe="$(STUB_IDS="4242:${sec}" docker run --rm --network none -v "$d/config/config.js:/padsign-probe:ro" --entrypoint sh img -c true)"
  check "Step 4e, after that rewrite: back to group ${sec}, mode 640, readable by the uid-4242 image" \
    bash -c 'grep -q "STAMP_MODE: \"local\"" "$1" && [[ "$(stat -c "%a %g" "$1")" == "640 $2" && "$3" == READABLE ]] \
      && grep -q "^Step 4e/6" <<< "$4" && grep -q "config/config.js: group $2, mode 640 - readable by" <<< "$4"' \
    _ "$d/config/config.js" "$sec" "$probe" "$out"
fi

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
