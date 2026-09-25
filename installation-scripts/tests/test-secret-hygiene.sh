#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for the fresh-install secret hygiene (psapp-saas#6, #7):
#
#   - configure-host.sh --generate-secrets replaces the public shipped
#     REGISTER_PDF_API_KEY / SESSION_SECRET, once, and never prints them;
#   - the Keycloak admin password goes to .env (mode 600), never into the
#     tracked docker-compose.yml, and survives compose's .env parser verbatim;
#   - config/config.js ends up group <image gid>, mode 640, readable by the
#     ps-server image, or is left readable when that is not durable;
#   - validate-config.sh's Secret hygiene lines and their fixes;
#   - overlay.sh apply/verify give config.js the same treatment;
#   - the image uid lookup follows the EFFECTIVE compose model (overlay).
#
# Usage:
#   ./installation-scripts/tests/test-secret-hygiene.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included), never the real config. `docker run` is replaced by a stub that
# fakes the image uid:gid (STUB_IDS) and the in-image read probe; `docker
# compose` is passed to the real docker when there is one (the .env
# round-trip and overlay cases need it) and fails otherwise. Every call the
# scripts make to docker is logged and checked for secrets. Linux only for
# the file-mode cases (Git Bash on NTFS has no real modes).
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git perl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true
real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}

copy_tree() {  # <dest>: tracked files as they are on disk now
  mkdir -p "$1"
  (cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$src_root" && xargs -0 cp --parents -t "$1" 2>/dev/null) || true
  chmod 644 "$1/config/config.js"
}

# ── docker stub ─────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log" REAL_DOCKER="$real_docker"
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  compose)
    [[ -n "${REAL_DOCKER:-}" ]] && exec "$REAL_DOCKER" "$@"
    exit 1 ;;
  run)
    args=("$@")
    if [[ "$*" == *padsign-probe* ]]; then
      # The in-image read probe: decide from the mounted file's bits as the
      # uid:gid in STUB_IDS would (no supplementary groups).
      [[ -n "${STUB_PROBE:-}" ]] && { echo "$STUB_PROBE"; exit 0; }
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
    if [[ "$*" == *'id -u'* ]]; then
      [[ -n "${STUB_IDS:-}" ]] || exit 1
      echo "$STUB_IDS"; exit 0
    fi
    exit 1 ;;
  ps) exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${bin}/docker"
export PATH="${bin}:${PATH}"
me_ids="$(id -u):$(id -g)"

hygiene="installation-scripts/lib/secret_hygiene.py"
field() {  # <config.js> <FIELD>: the value, for comparisons inside this test only
  python3 - "$1" "$2" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^\s*[\"']?" + re.escape(sys.argv[2]) + r"[\"']?\s*:\s*[\"']([^\"'\n]*)[\"']", t, re.M)
print(m.group(1) if m else "")
PY
}
secret_section() {  # validate-config.sh's "Secret hygiene:" block for <repo>
  (cd "$1" && bash installation-scripts/validate-config.sh --host padsign.test.local 2>&1) \
    | awk '/^Secret hygiene:/{on=1; next} on && /^$/{exit} on'
}
mode_of() { stat -c '%a' "$1"; }

pristine="${work}/pristine"
copy_tree "$pristine"

echo ""
echo "Shipped values:"
out="$(python3 "${pristine}/${hygiene}" shipped "${pristine}/config/config.js")"
n="$(grep -c '^WARN' <<< "$out")"
if [[ "$n" == 5 ]] && grep -q 'REGISTER_PDF_API_KEY' <<< "$out" && grep -q 'SESSION_SECRET' <<< "$out" \
   && grep -q 'backend client secret' <<< "$out" && grep -q 'STAMP_API_KEY' <<< "$out" && grep -q 'STAMP_COMPANY_SECRET' <<< "$out"; then
  ok_case "every credential the checkout ships is in secret_hygiene.py's published list (5)"
else
  fail_case "secret_hygiene.py's published sha256 list does not cover the committed config.js (update FIELDS)" "$out"
fi

# ── configure-host.sh ───────────────────────────────────────────────────────
echo ""
echo "configure-host.sh:"
repo="${work}/repo"
copy_tree "$repo"
# Every character class compose's .env parser treats specially, plus a quote.
PW='p@ss "w0rd" $HOME \ `x` # y'"'"'z ${X}'
run_configure() {  # [extra args...]
  (cd "$repo" && CONFIGURE_HOST_ADMIN_PASS="$PW" bash installation-scripts/configure-host.sh \
     --host padsign.test.local --company-role Acme --admin-user admin "$@" 2>&1)
}
: > "$STUB_LOG"
out="$(STUB_IDS="$me_ids" run_configure --generate-secrets)"; rc=$?
reg="$(field "$repo/config/config.js" REGISTER_PDF_API_KEY)"
ses="$(field "$repo/config/config.js" SESSION_SECRET)"
check "exits 0" test "$rc" = 0
check "REGISTER_PDF_API_KEY replaced by tlx_pdf_ + 64 hex" grep -Eqx 'tlx_pdf_[0-9a-f]{64}' <<< "$reg"
check "SESSION_SECRET replaced by 64 hex" grep -Eqx '[0-9a-f]{64}' <<< "$ses"
check "STAMP_API_KEY left alone (the provider's credential)" test "$(field "$repo/config/config.js" STAMP_API_KEY)" = "$(field "$pristine/config/config.js" STAMP_API_KEY)"
check "no generated value and no admin password in the output" \
  bash -c '! grep -qF -- "$1" <<< "$4" && ! grep -qF -- "$2" <<< "$4" && ! grep -qF -- "$3" <<< "$4"' _ "$PW" "$reg" "$ses" "$out"
check "no secret on any docker command line" \
  bash -c '! grep -qF -- "$1" "$4" && ! grep -qF -- "$2" "$4" && ! grep -qF -- "$3" "$4"' _ "$PW" "$reg" "$ses" "$STUB_LOG"
leaks="$(cd "$repo" && grep -rlF -- "$PW" . --exclude=.env 2>/dev/null || true)"
check "admin password in no file but .env" test -z "$leaks"
check "docker-compose.yml reads it from .env" \
  grep -qxF '      - KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}' <(tr -d '\r' < "$repo/docker-compose.yml")
check ".env has exactly one KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD line" test "$(grep -c '^KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=' "$repo/.env")" = 1
if [[ -n "$real_docker" ]]; then
  got="$(cd "$repo" && "$real_docker" compose config --format json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["keycloak"]["environment"]["KEYCLOAK_ADMIN_PASSWORD"].replace("$$", "$"), end="")')"
  check "docker compose hands Keycloak the password verbatim (.env quoting round-trip)" test "$got" = "$PW"
else
  echo "  (no docker compose: .env round-trip through compose's parser not checked)"
fi
if [[ "$linux" == true ]]; then
  check ".env is mode 600" test "$(mode_of "$repo/.env")" = 600
  check "config/config.js is mode 640, group = the image gid" test "$(stat -c '%a %g' "$repo/config/config.js")" = "640 $(id -g)"
  check "config/config.js.bak is owner-only" test "$(( 8#$(mode_of "$repo/config/config.js.bak") & 8#077 ))" = 0
fi

out="$(STUB_IDS="$me_ids" run_configure --generate-secrets)"
check "re-run keeps both generated values (idempotent)" test "$(field "$repo/config/config.js" REGISTER_PDF_API_KEY)|$(field "$repo/config/config.js" SESSION_SECRET)" = "${reg}|${ses}"
check "re-run says they were kept" grep -q 'already changed from the shipped values - kept' <<< "$out"
check "re-run leaves one .env line" test "$(grep -c '^KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=' "$repo/.env")" = 1

perl -i -pe 's/(REGISTER_PDF_API_KEY:\s*")[^"]*/${1}my-own-integration-key/' "$repo/config/config.js"
STUB_IDS="$me_ids" run_configure --generate-secrets >/dev/null
check "a custom REGISTER_PDF_API_KEY is never rotated" test "$(field "$repo/config/config.js" REGISTER_PDF_API_KEY)" = my-own-integration-key

perl -i -pe 's/^(\s*-\s*KEYCLOAK_ADMIN_PASSWORD=).*/${1}inline-old-secret/' "$repo/docker-compose.yml"
out="$(STUB_IDS="$me_ids" run_configure)"
check "an inline password left by an older bootstrap is replaced by the reference" \
  bash -c '! grep -q inline-old-secret "$1" && grep -q "KEYCLOAK_ADMIN_PASSWORD=\${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}" "$1"' _ "$repo/docker-compose.yml"
check "... and says so" grep -q 'replaced the inline KEYCLOAK_ADMIN_PASSWORD' <<< "$out"

before="$(sha256sum "$repo/.env")"
out="$(cd "$repo" && CONFIGURE_HOST_ADMIN_PASS=$'bad\npassword' STUB_IDS="$me_ids" bash installation-scripts/configure-host.sh --host padsign.test.local 2>&1)"; rc=$?
check "a password with a newline is refused, .env untouched" bash -c '[[ "$1" != 0 ]] && [[ "$2" == "$(sha256sum "$3")" ]]' _ "$rc" "$before" "$repo/.env"

# ── config.js when this user cannot keep the image's group ─────────────────
if [[ "$linux" == true ]]; then
  echo ""
  echo "config/config.js for an image uid this user cannot serve:"
  chmod 644 "$repo/config/config.js"
  out="$(STUB_IDS="4242:4242" run_configure)"
  check "not restricted, and says why" bash -c '[[ "$(stat -c %a "$1")" == 644 ]] && grep -q "is not root, uid 4242 or in group 4242" <<< "$2"' _ "$repo/config/config.js" "$out"
  chmod 600 "$repo/config/config.js"
  out="$(STUB_IDS="4242:4242" run_configure)"
  check "unreadable by the image: made readable again, with the fix" \
    bash -c '(( 8#$(stat -c %a "$1") & 8#004 )) && grep -q "sudo chgrp 4242 config/config.js && sudo chmod 640" <<< "$2"' _ "$repo/config/config.js" "$out"
fi

# ── validate-config.sh ──────────────────────────────────────────────────────
echo ""
echo "validate-config.sh Secret hygiene:"
v="${work}/validate"
copy_tree "$v"
sec="$(STUB_IDS=1000:1000 secret_section "$v")"
for pat in 'WARN REGISTER_PDF_API_KEY is still the value shipped.*--generate-secrets' \
           'WARN SESSION_SECRET is still the value shipped' \
           'WARN backend client secret' \
           'WARN STAMP_API_KEY is the shared demo e-sealing credential' \
           'WARN Keycloak.s first-boot admin password falls back to the demo default admin' \
           'WARN config/config.js is world-readable .*sudo chgrp 1000 config/config.js && sudo chmod 640'; do
  check "fresh checkout: ${pat}" grep -Eq -- "$pat" <<< "$sec"
done
check "fresh checkout: the old root-only hint is gone" bash -c '! grep -q "ps-server runs as root and still reads it" <<< "$1"' _ "$sec"

sec="$(STUB_IDS="$me_ids" secret_section "$repo")"
check "after configure-host.sh: no shipped-value WARN for REGISTER_PDF_API_KEY / SESSION_SECRET" \
  bash -c '! grep -Eq "WARN (REGISTER_PDF_API_KEY|SESSION_SECRET)" <<< "$1"' _ "$sec"
check "after configure-host.sh: admin password read from .env" grep -q 'OK   Keycloak.s first-boot admin password is read from KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD' <<< "$sec"

cp "$repo/docker-compose.yml" "$v/docker-compose.yml"
perl -i -pe 's/^(\s*-\s*KEYCLOAK_ADMIN_PASSWORD=).*/${1}Real-Secret-123/' "$v/docker-compose.yml"
sec="$(STUB_IDS=1000:1000 secret_section "$v")"
check "an inline non-default password is a WARN (value not shown)" \
  bash -c 'grep -q "WARN docker-compose.yml, a tracked file, carries the Keycloak admin password inline" <<< "$1" && ! grep -q Real-Secret-123 <<< "$1"' _ "$sec"

if [[ "$linux" == true ]]; then
  sec="$(STUB_IDS=0:0 secret_section "$v")"
  check "root image: chmod 640 is offered, with the upgrade caveat" grep -q 'runs as root, so chmod 640 config/config.js is safe for it' <<< "$sec"
  chmod 640 "$v/config/config.js"
  sec="$(STUB_IDS=4242:4242 secret_section "$v")"
  check "config.js the image cannot read is a FAIL, with the fix" grep -q 'FAIL config/config.js cannot be read by 4242:4242.*sudo chgrp 4242' <<< "$sec"
  chmod 644 "$v/config/config.js"
  chmod 644 "$repo/.env"
  sec="$(STUB_IDS="$me_ids" secret_section "$repo")"
  check "world-readable .env: chmod 600, not the ps-server hint" grep -q 'WARN .env is world-readable .*chmod 600 .env' <<< "$sec"
  chmod 600 "$repo/.env"
fi
perl -0777 -i -pe 's/(STAMP_API_URL:)/STAMP_MODE: "local",\n    $1/' "$v/config/config.js"
sec="$(STUB_IDS=1000:1000 secret_section "$v")"
check "STAMP_MODE local: the unused demo stamping credentials are OK" \
  bash -c 'grep -q "OK   STAMP_API_KEY is the demo value shipped in the public repository, but unused here" <<< "$1" && ! grep -q "WARN STAMP_" <<< "$1"' _ "$sec"

# ── effective compose model for the image uid (overlay host) ───────────────
echo ""
echo "Image lookup follows the effective compose model:"
fb_old="trustlynx/dmss-archive-services-fallback:24.0.5@sha256:$(printf 'c%.0s' {1..64})"
printf 'services:\n  dmss-archive-services-fallback:\n    image: "%s"\n' "$fb_old" > "${work}/compose.overlay.yml"
if command -v cygpath >/dev/null 2>&1; then ovl_native="$(cygpath -m "${work}/compose.overlay.yml")"; sep=";"; else ovl_native="${work}/compose.overlay.yml"; sep=":"; fi
printf 'COMPOSE_FILE=docker-compose.yml%s%s\n' "$sep" "$ovl_native" > "$v/.env"
for mode in docker files; do
  [[ "$mode" == docker && -z "$real_docker" ]] && continue
  got="$(repo_root="$v" PADSIGN_DIGEST_GATE_NO_DOCKER="$([[ $mode == files ]] && echo 1)" bash -c \
    '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; pinned_image_ref "$dmss_fallback_image_repo"')"
  check "overlay's fallback image, not the release's (${mode})" test "$got" = "$fb_old"
done
rm -f "$v/.env"
got="$(repo_root="$v" bash -c '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; pinned_image_ref "$ps_server_image_repo"')"
check "no overlay: the release's ps-server pin" grep -q '^mihailsgordijenko/ps-server:[0-9.]*@sha256:' <<< "$got"

# ── diff-baseline-overlay.sh ────────────────────────────────────────────────
echo ""
echo "diff-baseline-overlay.sh:"
out="$(bash "$repo/installation-scripts/diff-baseline-overlay.sh" --baseline "$pristine" --live "$repo" 2>&1)"
check "generated REGISTER_PDF_API_KEY / SESSION_SECRET are expected overlay, not drift" \
  bash -c '! grep -Eq "DRIFT: .*(REGISTER_PDF_API_KEY|SESSION_SECRET)" <<< "$1"' _ "$out"

# ── overlay.sh apply / verify ───────────────────────────────────────────────
if [[ "$linux" == true && -n "$real_docker" ]]; then
  echo ""
  echo "overlay.sh apply/verify:"
  g() { git -c user.email=test@example.invalid -c user.name=test -c init.defaultBranch=main "$@"; }
  rel="${work}/release"
  copy_tree "$rel"
  (cd "$rel" && g init -q && g add -A && g commit -qm release) >/dev/null
  live="${work}/live"
  g clone -q "$rel" "$live"
  perl -i -pe 's/(DEMO_COMPANY_ROLE:\s*")[^"]*/${1}HostCo/' "$live/config/config.js"
  chmod 777 "$live/config/config.js"                       # the demo host's mode
  printf 'KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD="first-boot-only"\n' > "$live/.env"
  chmod 600 "$live/.env"
  ovl="${work}/overlay-dir"
  (cd "$live" && STUB_IDS="$me_ids" bash installation-scripts/overlay.sh capture --baseline "$rel" --from "$live" --out "$ovl") >/dev/null 2>&1
  new="${work}/new"
  g clone -q "$rel" "$new"
  out="$(cd "$new" && STUB_IDS="$me_ids" bash installation-scripts/overlay.sh apply --overlay "$ovl" 2>&1)"; rc=$?
  check "apply: exits 0" test "$rc" = 0
  check "apply: config.js gets the image's group, mode 640 (was 777 on the host)" test "$(stat -c '%a %g' "$new/config/config.js")" = "640 $(id -g)"
  check "apply: says so" grep -q 'OK   config/config.js: group .*mode 640 - readable by' <<< "$out"
  out="$(cd "$new" && STUB_IDS="$me_ids" bash installation-scripts/overlay.sh verify --overlay "$ovl" 2>&1)"
  check "verify: config.js readable by ps-server and not world-readable" grep -q 'OK   config/config.js is not world-readable, and .* can read it' <<< "$out"
  new2="${work}/new2"
  g clone -q "$rel" "$new2"
  out="$(cd "$new2" && STUB_IDS="4242:4242" bash installation-scripts/overlay.sh apply --overlay "$ovl" 2>&1)"; rc=$?
  check "apply: an image uid that cannot read it FAILs, exit 1, with the fix" \
    bash -c '[[ "$1" == 1 ]] && grep -q "FAIL .*cannot read config/config.js" <<< "$2" && grep -q "sudo chgrp 4242" <<< "$2"' _ "$rc" "$out"
  check "apply: ... and never widens it to world-readable" bash -c '! (( 8#$(stat -c %a "$1") & 8#004 ))' _ "$new2/config/config.js"
  check "capture: the first-boot admin password is not carried, and is listed as NOT captured" \
    bash -c '! grep -qs KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD "$1/env" && ! grep -qs first-boot-only "$1/env" \
      && grep -q "\.env KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD" "$1/MANIFEST.json"' _ "$ovl"
else
  echo ""
  echo "(overlay.sh apply/verify cases need Linux and docker compose - skipped)"
fi

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
