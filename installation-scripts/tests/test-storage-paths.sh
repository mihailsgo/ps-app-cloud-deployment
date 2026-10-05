#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for how validate-config.sh finds and inspects the two signed-document
# stores (ps-server's /signed-output, the fallback archive's /docs):
#
#   - the host path is the source of the mount in the rendered compose model
#     (`docker compose config --format json`), not <project>/signed-output and
#     <project>/docs; an ordinary relative mount behaves as before;
#   - a store the caller cannot look at (the wizard container, which sees the
#     deployment directory only; a path the user may not read) is reported as
#     INFO "cannot inspect", never as a FAIL with an upgrade.sh or mkdir fix;
#   - a named volume has no host directory and is INFO too;
#   - a store that is mounted from outside the checkout and really missing is
#     still a FAIL, and never suggests upgrade.sh or mkdir.
#
# Usage:
#   ./installation-scripts/tests/test-storage-paths.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` is a stub: `compose config` / `version` go to the real
# docker when there is one (otherwise the file fallback reads the compose
# files), `run` fakes the image uid:gid and the in-image read probe, and
# everything else fails, so no case can reach a daemon. `cosign` is a stub
# that verifies. The wizard container is simulated with HOST_PROJECT_DIR and
# PADSIGN_MOUNTINFO (a stand-in for /proc/self/mountinfo). The permission
# case needs POSIX modes and a non-root user: Linux only.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency,
# 124 the watchdog (lib/watchdog.sh) stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git perl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER
unset CI PADSIGN_REQUIRE_SIGNATURES KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD HOST_PROJECT_DIR PADSIGN_MOUNTINFO

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start
real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 30 | sed 's/^/       | /'; return 0; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}
has() {  # <name> <text> <fixed string>
  if grep -qF -- "$3" <<< "$2"; then ok_case "$1"; else fail_case "$1" "wanted: $3"$'\n'"$2"; fi
}
lacks() {  # <name> <text> <fixed string>
  if grep -qF -- "$3" <<< "$2"; then fail_case "$1" "unexpected: $3"$'\n'"$2"; else ok_case "$1"; fi
}

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
sep=":"; command -v cygpath >/dev/null 2>&1 && sep=";"

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
    if [[ "$*" == *padsign-probe* ]]; then echo READABLE; exit 0; fi
    if [[ "$*" == *'id -u'* ]]; then echo "$STUB_IDS"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
cat > "${bin}/cosign" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == version ]] && echo '{"gitVersion": "v3.1.3"}'
exit 0
STUB
chmod +x "${bin}/docker" "${bin}/cosign"
export PATH="${bin}:${PATH}"

repo="${work}/repo"
copy_tree "$repo"
chmod 640 "$repo/config/config.js"
storage="${work}/storage"
mkdir -p "$storage/signed-output" "$storage/docs"
# /proc/self/mountinfo stand-ins: a container whose only mount is its root,
# and one with $storage mounted in at the same path as on the host.
printf '1 0 0:1 / / rw - overlay overlay rw\n' > "${work}/mountinfo-root"
ustore="$storage"; command -v cygpath >/dev/null 2>&1 && ustore="$(cygpath -u "$(cygpath -m "$storage")")"
printf '1 0 0:1 / / rw - overlay overlay rw\n99 1 0:50 / %s rw - ext4 /dev/sda1 rw\n' "$ustore" > "${work}/mountinfo-store"

lib() {  # <shell code>: run with lib/dir-permissions.sh sourced for $repo
  repo_root="$repo" bash -c '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; '"$1" </dev/null
}

# ── store_probe ─────────────────────────────────────────────────────────────
echo "store_probe (lib/dir-permissions.sh):"
mkdir -p "${work}/probe/dir"
: > "${work}/probe/file"
probe() {  # <path> [env assignments...]
  local p="$1"; shift
  env "$@" repo_root="$repo" bash -c '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; store_probe "$1"; printf "%s" "$store_state"' _ "$p" </dev/null
}
check "a directory: dir" test "$(probe "${work}/probe/dir")" = dir
check "nothing there: missing" test "$(probe "${work}/probe/none")" = missing
check "a file: notdir" test "$(probe "${work}/probe/file")" = notdir
check "wizard container, path outside the checkout and not mounted: outside, even though it exists here" \
  test "$(probe "${work}/probe/dir" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-root")" = outside
check "wizard container, path under a mount made into it: looked at (dir)" \
  test "$(probe "$ustore/docs" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-store")" = dir
check "... and missing when nothing is there" \
  test "$(probe "$ustore/nope" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-store")" = missing
printf '1 0 0:1 / / rw - overlay overlay rw\n99 1 0:50 / /mnt/my\\040storage rw - ext4 /dev/sda1 rw\n' > "${work}/mountinfo-space"
check "wizard container, mount point with a space (\\040 in mountinfo): matched" \
  test "$(probe "/mnt/my storage/docs" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-space")" = missing
check "... a sibling that merely shares the prefix is not" \
  test "$(probe "/mnt/my storage2/docs" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-space")" = outside
check "wizard container, path inside the checkout: looked at (missing)" \
  test "$(probe "$repo/signed-output" HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-root")" = missing
if [[ "$(uname -s)" == Linux && "$(id -u)" != 0 ]]; then
  mkdir -p "${work}/locked/inner"
  chmod 000 "${work}/locked"
  check "a path under a directory this user may not enter: denied" test "$(probe "${work}/locked/inner")" = denied
  chmod 755 "${work}/locked"
else
  echo "  (skipping the permission-denied case: needs Linux and a non-root user)"
fi

# ── validate-config.sh ──────────────────────────────────────────────────────
echo ""
echo "validate-config.sh (each run takes a while: it asks docker compose for the model):"
H=padsign.example.com
perl -i -pe "s/padsign\\.trustlynx\\.com/$H/g" "$repo/nginx/nginx.conf" "$repo/config/constants.json" "$repo/docker-compose.yml"
perl -i -pe "s#https://padsign\\.trustlynx\\.com#https://$H#g" "$repo/config/config.js"

validate() {  # [env assignments...]: validate-config.sh output for $repo
  (cd "$repo" && env "$@" bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)
}
section_lines() {  # <output>: the lines about the two stores
  grep -E '^  (OK|FAIL|WARN|INFO) +(signed-output|docs)' <<< "$1" || true
}
no_remedy() {  # <name> <lines>: neither an upgrade.sh nor a mkdir fix is offered
  if grep -qE 're-run upgrade\.sh|mkdir -p' <<< "$2"; then fail_case "$1" "$2"; else ok_case "$1"; fi
}
no_store_fail() {  # <name> <lines>
  if grep -qE '^  FAIL ' <<< "$2"; then fail_case "$1" "$2"; else ok_case "$1"; fi
}

# Ordinary relative mounts: unchanged.
rm -rf "$repo/signed-output" "$repo/docs"
out="$(validate)"; lines="$(section_lines "$out")"
has "relative mounts, directories absent: FAIL, upgrade.sh creates signed-output" "$out" "FAIL signed-output directory missing (re-run upgrade.sh, which creates it"
has "... and docs: mkdir -p docs" "$out" "FAIL docs directory missing (create with: mkdir -p docs"
lacks "... no 'mounted from' line (nothing is relocated)" "$out" "is mounted from"
mkdir -p "$repo/signed-output" "$repo/docs"
chmod 750 "$repo/signed-output"; chmod 770 "$repo/docs"
out="$(validate)"; lines="$(section_lines "$out")"
has "relative mounts, directories present: signed-output exists" "$out" "OK   signed-output directory exists"
has "... docs is not world-writable" "$out" "OK   docs directory is not world-writable"
no_store_fail "... no FAIL about either store" "$lines"

# Absolute mounts from the effective compose model (an override file).
cat > "$repo/docker-compose.override.yml" <<EOF
services:
  ps-server:
    volumes:
      - "$(native "$storage")/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - "$(native "$storage")/docs:/docs"
EOF
rm -rf "$repo/signed-output" "$repo/docs"
chmod 750 "$storage/signed-output"; chmod 770 "$storage/docs"
out="$(validate)"; lines="$(section_lines "$out")"
has "absolute mounts, storage present: signed-output is read from the mount" "$out" "OK   signed-output is mounted from "
has "... docs too" "$out" "OK   docs is mounted from "
has "... signed-output directory exists (the mount's, not the checkout's)" "$out" "OK   signed-output directory exists"
has "... docs is checked there" "$out" "OK   docs directory is not world-writable"
no_store_fail "... no FAIL about either store, though the checkout has neither directory" "$lines"
check "... nothing was created in the checkout" test ! -e "$repo/signed-output" -a ! -e "$repo/docs"

# A mount whose source is really missing on a host: still a FAIL, with no upgrade.sh/mkdir fix.
mv "$storage/docs" "${work}/docs.away"
out="$(validate)"; lines="$(section_lines "$out")"
has "absolute mount, directory missing on the host: FAIL, restore or re-point the mount" "$out" "(environment-overlay mount) is missing - restore or re-point the mount"
no_remedy "... and no upgrade.sh or mkdir fix" "$lines"
mv "${work}/docs.away" "$storage/docs"

# The same mounts, seen from the wizard container: only the checkout is there.
out="$(validate HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-root")"; lines="$(section_lines "$out")"
has "wizard container, storage not mounted into it: signed-output is INFO" "$out" "INFO signed-output is mounted from "
has "... docs too" "$out" "INFO docs is mounted from "
has "... says what was not checked and where to run it" "$out" "Ownership and mode were not checked; run validate-config.sh on the host"
no_store_fail "... no FAIL about either store" "$lines"
no_remedy "... no upgrade.sh or mkdir fix" "$lines"
lacks "... not reported as missing" "$out" "is missing"

# Same, with the directories genuinely absent on the host.
mv "$storage/signed-output" "${work}/so.away"; mv "$storage/docs" "${work}/docs.away"
out="$(validate HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-root")"; lines="$(section_lines "$out")"
no_store_fail "wizard container, storage absent: still no FAIL (it cannot tell)" "$lines"
no_remedy "... and no upgrade.sh or mkdir fix" "$lines"
mv "${work}/so.away" "$storage/signed-output"; mv "${work}/docs.away" "$storage/docs"

# The storage mounted into the wizard at the same path: inspected like on the host.
out="$(validate HOST_PROJECT_DIR="$repo" PADSIGN_MOUNTINFO="${work}/mountinfo-store")"; lines="$(section_lines "$out")"
has "wizard container with the storage mounted in: signed-output is inspected" "$out" "OK   signed-output directory exists"
has "... docs too" "$out" "OK   docs directory is not world-writable"

# A named volume: no host directory.
cat > "$repo/docker-compose.override.yml" <<EOF
services:
  ps-server:
    volumes:
      - signed_output_data:/signed-output
  dmss-archive-services-fallback:
    volumes:
      - "$(native "$storage")/docs:/docs"
volumes:
  signed_output_data:
EOF
out="$(validate)"; lines="$(section_lines "$out")"
has "signed-output a named volume: INFO, nothing to check on the host" "$out" "INFO signed-output is a named Docker volume"
has "... the mount is still recognised" "$out" "OK   signed-output volume mount in docker-compose.yml"
no_store_fail "... no FAIL about either store" "$lines"
has "... docs, mounted from a path, is checked as usual" "$out" "OK   docs directory is not world-writable"
rm -f "$repo/docker-compose.override.yml"

if [[ "$(uname -s)" == Linux && "$(id -u)" != 0 ]]; then
  # A path the user may not read.
  mkdir -p "${work}/locked2/signed-output" "${work}/locked2/docs"
  cat > "$repo/docker-compose.override.yml" <<EOF
services:
  ps-server:
    volumes:
      - "${work}/locked2/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - "${work}/locked2/docs:/docs"
EOF
  chmod 000 "${work}/locked2"
  out="$(validate)"; lines="$(section_lines "$out")"
  chmod 755 "${work}/locked2"
  has "mounted under a directory this user cannot enter: INFO permission denied" "$out" "INFO signed-output at ${work}/locked2/signed-output cannot be inspected: permission denied"
  no_store_fail "... no FAIL about either store" "$lines"
  no_remedy "... no upgrade.sh or mkdir fix" "$lines"
  rm -f "$repo/docker-compose.override.yml"
fi

echo ""
echo "== ${pass} passed, ${failed} failed =="
[[ "$failed" == 0 ]]
