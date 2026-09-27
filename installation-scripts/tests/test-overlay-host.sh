#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for two overlay-host follow-ups (psapp-saas#7):
#
#   - upgrade.sh's signed-output migration reads the stores from the
#     EFFECTIVE compose model: on an overlay-managed checkout signed-output/
#     and docs/ are mounted from outside the checkout (compose.overlay.yml),
#     and --plan-only used to report [WILL APPLY] signed-output there on
#     every run (runbook 42.6 says to expect no pending migration);
#   - overlay.sh drop removes a captured file (a DEVIATIONS.md entry marked
#     OBSOLETE, 42.3 O4) with its MANIFEST.json record, and rehash reports a
#     file the manifest lists but that is gone instead of a traceback.
#
# Usage:
#   ./installation-scripts/tests/test-overlay-host.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` is a stub: `docker compose config` / `version` go to
# the real docker when there is one (every compose-model case also runs via
# the file fallback, PADSIGN_DIGEST_GATE_NO_DOCKER=1), `docker run` fakes the
# image uid:gid and the in-image read probe, and everything else fails, so
# no case can reach a daemon. Nothing is pulled or started.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
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

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
sep=":"; command -v cygpath >/dev/null 2>&1 && sep=";"

copy_tree() {  # <dest>: tracked files as they are on disk now
  mkdir -p "$1"
  (cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$src_root" && xargs -0 cp --parents -t "$1" 2>/dev/null) || true
}

# ── docker stub ─────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log" REAL_DOCKER="$real_docker" STUB_IDS="$(id -u):$(id -g)"
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
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
chmod +x "${bin}/docker"
export PATH="${bin}:${PATH}"

pristine="${work}/pristine"
copy_tree "$pristine"
approved() {  # <key> -> approved tag
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["tag"])' \
    "$(native "${pristine}/release/approved-digests.json")" "$1"
}
srv_ok="$(approved ps-server)"; cli_ok="$(approved ps-client)"

# ── upgrade.sh --plan-only on an overlay-managed checkout ──────────────────
repo="${work}/repo"
overlay="${work}/overlay"
storage="${work}/storage"
copy_tree "$repo"
mkdir -p "$overlay" "$storage/signed-output" "$storage/docs"

write_overlay() {  # [short|long]: compose.overlay.yml mounting the stores from $storage
  if [[ "${1:-short}" == long ]]; then
    cat > "${overlay}/compose.overlay.yml" <<EOF
services:
  ps-server:
    volumes:
      - type: bind
        source: "$(native "$storage")/signed-output"
        target: /signed-output
  dmss-archive-services-fallback:
    volumes:
      - type: bind
        source: '$(native "$storage")/docs'
        target: /docs
EOF
  else
    cat > "${overlay}/compose.overlay.yml" <<EOF
services:
  # the documents' existing home, as overlay.sh capture writes it
  ps-server:
    volumes:
      - "$(native "$storage")/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - "$(native "$storage")/docs:/docs"
EOF
  fi
  printf 'COMPOSE_PROJECT_NAME=padsign\nCOMPOSE_FILE=docker-compose.yml%s%s\n' "$sep" "$(native "$overlay")/compose.overlay.yml" > "${repo}/.env"
  printf '{"overlay_dir": "%s"}\n' "$(native "$overlay")" > "${repo}/.overlay-applied.json"
}
no_overlay() { rm -f "${repo}/.env" "${repo}/.overlay-applied.json"; }

plan() {  # [text]: upgrade.sh --plan-only output for $repo
  local fmt=machine
  [[ "${1:-}" == text ]] && fmt=text
  (cd "$repo" && bash installation-scripts/upgrade.sh --server-tag "$srv_ok" --client-tag "$cli_ok" \
     --plan-only --plan-format "$fmt" 2>&1)
}
item() {  # <plan output> <id> -> "status|body" of that migration
  awk -v id="$2" '
    $0 == "id=" id { on = 1; next }
    on && /^status=/ { st = substr($0, 8) }
    on && $0 == "###PLAN-BODY-BEGIN" { inbody = 1; next }
    on && $0 == "###PLAN-BODY-END" { printf "%s|%s", st, body; exit }
    inbody { body = body $0 "\n" }
  ' <<< "$1"
}
lib() {  # <shell code>: run with lib/dir-permissions.sh sourced for $repo
  repo_root="$repo" bash -c '. "$repo_root/installation-scripts/lib/dir-permissions.sh"; '"$1"
}

run_plan_cases() {  # <label>
  local out got
  echo ""
  echo "upgrade.sh --plan-only, signed-output migration (${1}):"
  rm -rf "${repo}/signed-output" "${repo}/docs"

  write_overlay short
  out="$(plan)"; got="$(item "$out" signed-output)"
  check "overlay host, stores mounted from outside the checkout: already applied" test "${got%%|*}" = already-applied
  check "... and the ps-server/ps-client plan still renders (exit 0)" grep -q '^###PLAN-END' <<< "$out"
  check "... no signed-output/ or docs/ appeared in the checkout" test ! -e "${repo}/signed-output" -a ! -e "${repo}/docs"
  out="$(plan text)"
  check "... text plan: [already applied] signed-output" grep -qF '[already applied] signed-output' <<< "$out"

  write_overlay long
  got="$(item "$(plan)" signed-output)"
  check "long-syntax overlay mounts: already applied" test "${got%%|*}" = already-applied

  mv "$storage/docs" "$storage/docs.away"
  got="$(item "$(plan)" signed-output)"
  check "overlay storage missing: not a migration (upgrade.sh never creates the documents' home)" test "${got%%|*}" = already-applied
  mv "$storage/docs.away" "$storage/docs"

  no_overlay
  got="$(item "$(plan)" signed-output)"
  check "plain checkout, stores absent: will apply" test "${got%%|*}" = will-apply
  check "... body names the in-tree directories" bash -c 'grep -q "^mkdir -p signed-output/ (mode 750)" <<< "$1" && grep -q "^mkdir -p docs/ (mode 770)" <<< "$1"' _ "${got#*|}"
  mkdir -p "${repo}/signed-output" "${repo}/docs"
  got="$(item "$(plan)" signed-output)"
  check "plain checkout, stores present: already applied" test "${got%%|*}" = already-applied

  # docker-compose.yml without the ps-server mount line (a host from before it existed)
  cp "${repo}/docker-compose.yml" "${work}/compose.keep"
  sed -i '/signed-output:\/signed-output/d' "${repo}/docker-compose.yml"
  got="$(item "$(plan)" signed-output)"
  check "no mount anywhere: will apply, adding the volume line" bash -c '[[ "${1%%|*}" == will-apply ]] && grep -qF "./signed-output:/signed-output" <<< "${1#*|}"' _ "$got"
  write_overlay short
  got="$(item "$(plan)" signed-output)"
  check "no line in docker-compose.yml, but the overlay mounts /signed-output: already applied" test "${got%%|*}" = already-applied
  cp "${work}/compose.keep" "${repo}/docker-compose.yml"
  rm -rf "${repo}/signed-output" "${repo}/docs"

  out="$(lib 'signed_output_mount; printf "%s|%s|%s" "$storage_how" "$storage_in_tree" "$storage_path"')"
  check "storage_mount: the overlay's bind source, outside the checkout" \
    bash -c '[[ "$1" == bind\|false\|* ]] && python3 -c "import os, sys; sys.exit(not os.path.samefile(sys.argv[1], sys.argv[2]))" "$2" "$3"' \
    _ "$out" "$(native "${out##*|}")" "$(native "$storage/signed-output")"
  out="$(lib 'fix_signed_output_permissions; fix_docs_permissions')"
  check "fix_*_permissions: overlay storage left as is, nothing created in the checkout" \
    bash -c '[[ ! -e "$1/signed-output" && ! -e "$1/docs" ]] && grep -q "signed-output/: mounted from .* left as it is" <<< "$2"' _ "$repo" "$out"
  no_overlay
  out="$(lib 'docs_mount; printf "%s|%s|%s" "$storage_how" "$storage_in_tree" "$storage_path"')"
  check "storage_mount: plain checkout -> \${repo_root}/docs" test "$out" = "bind|true|${repo}/docs"
}

if [[ -n "$real_docker" ]]; then
  run_plan_cases "docker compose config"
else
  echo ""
  echo "(docker compose not available - skipping the docker-backed plan cases)"
fi
export PADSIGN_DIGEST_GATE_NO_DOCKER=1
run_plan_cases "file fallback"
unset PADSIGN_DIGEST_GATE_NO_DOCKER

# ── overlay.sh drop / rehash ────────────────────────────────────────────────
echo ""
echo "overlay.sh drop / rehash:"
g() { git -c user.email=test@example.invalid -c user.name=test -c init.defaultBranch=main "$@"; }
rel="${work}/release"
copy_tree "$rel"
(cd "$rel" && g init -q && g add -A && g commit -qm release) >/dev/null
live="${work}/live"
g clone -q "$rel" "$live"
perl -i -pe 's/(DEMO_COMPANY_ROLE:\s*")[^"]*/${1}HostCo/' "$live/config/config.js"
printf '# host tuning\n' >> "$live/dmss-archive-services/application.yml"
printf 'host-only file\n' > "$live/config/host-extra.txt"
mkdir -p "$live/nginx/certs"
printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' > "$live/nginx/certs/padsign.test.local.crt"
ovl="${work}/overlay-captured"
out="$(cd "$live" && bash installation-scripts/overlay.sh capture --baseline "$(native "$rel")" --from "$(native "$live")" --out "$(native "$ovl")" 2>&1)"
if grep -q 'Captured 3 file(s), 1 certificate file(s)' <<< "$out"; then ok_case "capture: 3 files and 1 certificate captured"
else fail_case "capture: 3 files and 1 certificate captured" "$out"; fi

ovl_sh() { (cd "$rel" && bash installation-scripts/overlay.sh "$@" 2>&1); }
state() { (cd "$ovl" && find . -type f | LC_ALL=C sort | xargs sha256sum); }
listed() { python3 -c 'import json,sys; print(" ".join(sorted(e["path"] for e in json.load(open(sys.argv[1]))["files"])))' "$(native "$ovl/MANIFEST.json")"; }

before="$(state)"
out="$(ovl_sh drop --overlay "$(native "$ovl")" config/not-captured.js)"; rc=$?
check "drop: a path not in the manifest is refused, exit 1" bash -c '[[ "$1" == 1 ]] && grep -q "FAIL config/not-captured.js: not a file captured in MANIFEST.json" <<< "$2"' _ "$rc" "$out"
check "... and lists what the overlay carries" grep -q '^    config/host-extra.txt$' <<< "$out"
out="$(ovl_sh drop --overlay "$(native "$ovl")" config/host-extra.txt nope.txt)"; rc=$?
check "drop: one unknown path among known ones refuses all, exit 1" test "$rc" = 1
out="$(ovl_sh drop --overlay "$(native "$ovl")" nginx/certs/padsign.test.local.crt)"; rc=$?
check "drop: a certificate is refused with the reason" bash -c '[[ "$1" == 1 ]] && grep -q "a certificate - not dropped this way" <<< "$2"' _ "$rc" "$out"
check "... a refused drop changed nothing in the overlay" test "$before" = "$(state)"

out="$(ovl_sh drop --overlay "$(native "$ovl")" files/config/host-extra.txt)"; rc=$?
check "drop: an extra file (files/ prefix accepted), exit 0" test "$rc" = 0
check "... files/ entry removed" test ! -e "$ovl/files/config/host-extra.txt"
check "... MANIFEST.json no longer lists it" test "$(listed)" = "config/config.js dmss-archive-services/application.yml"
check "... MANIFEST.json records the drop" grep -q '"dropped_at"' "$ovl/MANIFEST.json"
check "... DEVIATIONS.md notes it" grep -q '^- `config/host-extra.txt` (extra) - dropped .* the checkout no longer gets this file' "$ovl/DEVIATIONS.md"

out="$(ovl_sh drop --overlay "$(native "$ovl")" ./dmss-archive-services/application.yml)"; rc=$?
check "drop: an override, exit 0" test "$rc" = 0
check "... files/ and base/ copies removed (and the emptied directories)" \
  test ! -e "$ovl/files/dmss-archive-services" -a ! -e "$ovl/base/dmss-archive-services"
check "... DEVIATIONS.md: one section, two notes" \
  bash -c '[[ "$(grep -c "^## Dropped from the overlay" "$1")" == 1 && "$(grep -c "dropped .* with \`overlay.sh drop\`" "$1")" == 2 ]]' _ "$ovl/DEVIATIONS.md"
out="$(ovl_sh rehash --overlay "$(native "$ovl")")"; rc=$?
check "rehash after drops: exit 0, nothing to re-record" bash -c '[[ "$1" == 0 ]] && grep -q "0 checksum(s) updated" <<< "$2"' _ "$rc" "$out"

new="${work}/new"
g clone -q "$rel" "$new"
out="$(cd "$new" && bash installation-scripts/overlay.sh apply --overlay "$(native "$ovl")" 2>&1)"; rc=$?
check "apply after drops: the integrity check passes" bash -c '! grep -qiE "missing|changed since capture" <<< "$1" && grep -q "OK   config/config.js (override" <<< "$1"' _ "$out"
check "... the dropped override keeps the release's version, the dropped extra file is absent" \
  bash -c '[[ -z "$(git -C "$1" status --porcelain -- dmss-archive-services)" && ! -e "$1/config/host-extra.txt" ]]' _ "$new"
[[ "$(uname -s)" == Linux ]] && check "... apply exits 0" test "$rc" = 0

mv "$ovl/files/config/config.js" "${work}/config.js.away"
before="$(cat "$ovl/MANIFEST.json")"
out="$(ovl_sh rehash --overlay "$(native "$ovl")")"; rc=$?
check "rehash: a listed file deleted by hand is an error (exit 1), not a traceback" \
  bash -c '[[ "$1" == 1 ]] && grep -q "FAIL files/config/config.js is listed in MANIFEST.json but is missing" <<< "$2" && ! grep -q Traceback <<< "$2"' _ "$rc" "$out"
check "... it points at overlay.sh drop" grep -q 'overlay.sh drop --overlay .* config/config.js' <<< "$out"
check "... and re-records nothing" test "$before" = "$(cat "$ovl/MANIFEST.json")"
mv "${work}/config.js.away" "$ovl/files/config/config.js"
mv "$ovl/certs/padsign.test.local.crt" "${work}/crt.away"
out="$(ovl_sh rehash --overlay "$(native "$ovl")")"; rc=$?
check "rehash: a missing certificate is an error too" \
  bash -c '[[ "$1" == 1 ]] && grep -q "FAIL certs/padsign.test.local.crt is listed" <<< "$2" && grep -q "restored or re-captured" <<< "$2"' _ "$rc" "$out"
mv "${work}/crt.away" "$ovl/certs/padsign.test.local.crt"

out="$(ovl_sh drop --overlay "$(native "$ovl")")"; rc=$?
check "drop without a path: usage error, exit 2" test "$rc" = 2
out="$(ovl_sh drop --overlay "$(native "${work}/no-such-overlay")" config/config.js)"; rc=$?
check "drop on a directory that is not an overlay: exit 2" bash -c '[[ "$1" == 2 ]] && grep -q "MANIFEST.json not found" <<< "$2"' _ "$rc" "$out"

# ── apply/verify: DMSS application.yml and htpasswd modes ──────────────────
# overlay.sh apply used to copy them with the captured host mode (0775 on
# the demo host) and htpasswd with 0644, readable by every local user
# (psapp-saas#7). Needs Linux file modes: chmod on a Windows checkout is a no-op.
if [[ "$(uname -s)" == Linux ]]; then
  echo ""
  echo "apply/verify: secret-bearing service files:"
  csig=dmss-container-and-signature-services/application.yml
  live2="${work}/live2"
  g clone -q "$rel" "$live2"
  printf '# host client secret\n' >> "$live2/$csig"
  chmod 775 "$live2/$csig"
  mkdir -p "$live2/nginx/certs"
  printf 'dmss:$apr1$fake$hash\n' > "$live2/nginx/certs/htpasswd"
  printf -- '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n' > "$live2/nginx/certs/padsign.test.local.crt"
  ovl2="${work}/overlay-secrets"
  (cd "$live2" && bash installation-scripts/overlay.sh capture --baseline "$rel" --from "$live2" --out "$ovl2" >/dev/null 2>&1)
  new2="${work}/new2"
  g clone -q "$rel" "$new2"
  out="$(cd "$new2" && bash installation-scripts/overlay.sh apply --overlay "$ovl2" 2>&1)"; rc=$?
  mygid="$(id -g)"
  check "apply: exit 0" test "$rc" = 0
  check "... the 0775 host copy of $csig lands as 0640, group = the reader's gid" \
    bash -c '[[ "$(stat -c "%a %g" "$1")" == "640 $2" ]] && grep -q "OK   $3: group $2, mode 640 - readable by" <<< "$4"' _ "$new2/$csig" "$mygid" "$csig" "$out"
  check "... htpasswd lands as 0640 (was 0644), read as the image's nginx user" \
    bash -c '[[ "$(stat -c "%a" "$1")" == 640 ]] && grep -q "OK   nginx/certs/htpasswd: group .* (user nginx)" <<< "$2"' _ "$new2/nginx/certs/htpasswd" "$out"
  check "... a release application.yml the overlay does not carry is left as git has it" \
    test "$(stat -c %a "$new2/dmss-archive-services/application.yml")" = "$(stat -c %a "$rel/dmss-archive-services/application.yml")"
  check "... and git status shows only the carried file" \
    test "$(git -C "$new2" status --porcelain --untracked-files=no | awk '{print $2}')" = "$csig"
  check "... the certificate stays 0644" test "$(stat -c %a "$new2/nginx/certs/padsign.test.local.crt")" = 644
  check "... the reader's ids were read for the image's nginx user" grep -qF -- ':$(id -g "$0")" nginx' "$STUB_LOG"
  out="$(cd "$new2" && bash installation-scripts/overlay.sh verify --overlay "$ovl2" 2>&1)"
  check "verify: reports $csig and htpasswd as not world-readable" \
    bash -c 'grep -q "OK   $2 is not world-readable (mode 640)" <<< "$1" && grep -q "OK   nginx/certs/htpasswd is not world-readable" <<< "$1"' _ "$out" "$csig"
  chmod 644 "$new2/$csig"
  out="$(cd "$new2" && bash installation-scripts/overlay.sh verify --overlay "$ovl2" 2>&1)"
  check "verify: a world-readable $csig is a WARN" grep -q "WARN $csig is world-readable (mode 644)" <<< "$out"

  # A reader uid:gid this user can neither be nor chgrp to: apply must not
  # restrict (that would lock the service out), and says so...
  new3="${work}/new3"
  g clone -q "$rel" "$new3"
  out="$(cd "$new3" && STUB_IDS="$(( $(id -u) + 1 )):65534" bash installation-scripts/overlay.sh apply --overlay "$ovl2" 2>&1)"
  check "apply as a non-member of the reader's group: mode left, WARN" \
    bash -c '[[ "$(stat -c %a "$1")" == 775 ]] && grep -q "WARN $2: left world-readable (mode 775)" <<< "$3"' _ "$new3/$csig" "$csig" "$out"
  # ...and a copy the reader cannot read at all fails apply before the cut-over.
  chmod 600 "$ovl2/files/$csig"
  python3 - "$ovl2/MANIFEST.json" "$csig" <<'PY'
import json, sys
p, rel = sys.argv[1], sys.argv[2]
m = json.load(open(p))
for e in m["files"]:
    if e["path"] == rel:
        e["mode"] = "0o600"
json.dump(m, open(p, "w"), indent=2)
PY
  new4="${work}/new4"
  g clone -q "$rel" "$new4"
  out="$(cd "$new4" && STUB_IDS="$(( $(id -u) + 1 )):65534" bash installation-scripts/overlay.sh apply --overlay "$ovl2" 2>&1)"; rc=$?
  check "apply: a copy the reader cannot read is a FAIL with the fix, exit 1" \
    bash -c '[[ "$1" == 1 ]] && grep -q "FAIL $2: .* cannot read it (mode 600). Fix: sudo chgrp 65534 $2" <<< "$3"' _ "$rc" "$csig" "$out"
fi

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
