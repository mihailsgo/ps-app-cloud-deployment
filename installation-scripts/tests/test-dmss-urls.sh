#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for the addresses ps-server uses to reach the DMSS services:
#
#   - lib/dmss_urls.py: reads the five keys, rewrites them in place in either
#     direction, byte for byte otherwise (CRLF and single quotes included),
#     idempotent, reversible, and leaves a value of the operator's own alone;
#   - upgrade.sh --use-internal-dmss-urls / --use-public-dmss-urls: the plan
#     and the real run agree, a plain upgrade never changes the addresses (the
#     default-behaviour invariant), the dmss-internal-urls capability gates the
#     switch while --require-capability keeps its meaning, and a real run
#     names ps-server and nothing else for `docker compose pull`;
#   - validate-config.sh accepts both address forms and flags the wrong ones,
#     and accepts a constants.json with or without the Keycloak URL keys;
#   - configure-host.sh leaves constants.json keys that were left out, and
#     relative values, as they are.
#
# Usage:
#   ./installation-scripts/tests/test-dmss-urls.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` is a stub (`compose config` / `version` go to the real
# docker when there is one; `run` fakes the image uid:gid and the in-image
# read probe; everything else fails, so every upgrade stops at its image
# pull). `cosign` is a stub that verifies. The file-mode case needs real POSIX
# modes: Linux only. config.js is loaded with node when it is installed.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency,
# 124 the watchdog (lib/watchdog.sh) stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git perl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER
unset CI PADSIGN_REQUIRE_SIGNATURES KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true
real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi
node_bin="$(command -v node || true)"

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}
has() {  # <name> <text> <fixed string>: PASS if the text contains the string
  if grep -qF -- "$3" <<< "$2"; then ok_case "$1"; else fail_case "$1" "wanted: $3"$'\n'"$2"; fi
}
lacks() {  # <name> <text> <fixed string>
  if grep -qF -- "$3" <<< "$2"; then fail_case "$1" "unexpected: $3"$'\n'"$2"; else ok_case "$1"; fi
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

tool="${src_root}/installation-scripts/lib/dmss_urls.py"
dmss() { python3 "$(native "$tool")" "$@"; }

pristine="${work}/pristine"
copy_tree "$pristine"
approved() {  # <key> -> approved tag
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["tag"])' \
    "$(native "${pristine}/release/approved-digests.json")" "$1"
}
srv_ok="$(approved ps-server)"; cli_ok="$(approved ps-client)"
H=padsign.example.com

loads() {  # <config.js> <key> <expected>: node loads it and the key has that value
  [[ -z "$node_bin" ]] && return 0
  MSYS2_ARG_CONV_EXCL='*' "$node_bin" -e 'process.exit(require(process.argv[1])[process.argv[2]] === process.argv[3] ? 0 : 1)' "$(native "$1")" "$2" "$3"
}
count_keys() {  # <config.js> <state>
  dmss status "$1" | awk -F'\t' -v st="$2" '$1 != "ARCHIVE_PUBLIC_BASE_URL" && $2 == st' | wc -l | tr -d ' '
}

# A config.js as a host installed before the switch has it: the five keys on
# the public address of $H.
make_public() {  # <config.js>
  # the shipped file also carries ARCHIVE_PUBLIC_BASE_URL (and its host would win
  # over --host); an older host has none
  perl -0777 -i -pe 's/\n    \/\/ The archive address a webhook receiver can reach\..*?ARCHIVE_PUBLIC_BASE_URL: "[^"]*",//s' "$1"
  dmss apply "$1" public --host "$H" >/dev/null
}

# ── lib/dmss_urls.py ────────────────────────────────────────────────────────
echo ""
echo "lib/dmss_urls.py:"
shipped="${pristine}/config/config.js"
check "the shipped config.js: all five keys in-network" test "$(count_keys "$shipped" internal)" = 5
check "... and it loads, with ARCHIVE_API_BASE_URL in-network" loads "$shipped" ARCHIVE_API_BASE_URL "http://dmss-archive-services:8090/api/"
check "... plan internal: nothing to do" test -z "$(dmss plan "$shipped" internal)"
check "... plan public --host: all five" test "$(dmss plan "$shipped" public --host "$H" | grep -c "	set	")" = 5

c="${work}/pub.js"
cp "$shipped" "$c"; make_public "$c"
cp "$c" "${work}/pub.orig.js"
check "(setup) an older host's config.js: five public keys, no ARCHIVE_PUBLIC_BASE_URL" \
  bash -c '[[ "$1" == 5 ]] && ! grep -q "ARCHIVE_PUBLIC_BASE_URL" "$2"' _ "$(count_keys "$c" public)" "$c"
plan="$(dmss plan "$c" internal)"
check "plan internal on it: five rewrites and the public address added" \
  bash -c '[[ "$(grep -c "	set	" <<< "$1")" == 5 ]] && grep -q "^ARCHIVE_PUBLIC_BASE_URL	add		https://'"$H"'/archive/api/$" <<< "$1"' _ "$plan"
check "... plan writes nothing" cmp -s "$c" "${work}/pub.orig.js"
dmss apply "$c" internal >/dev/null
check "apply internal: five in-network keys" test "$(count_keys "$c" internal)" = 5
check "... ARCHIVE_PUBLIC_BASE_URL keeps the old public address (webhook archiveUrl is unchanged)" \
  loads "$c" ARCHIVE_PUBLIC_BASE_URL "https://${H}/archive/api/"
check "... the file still loads" loads "$c" CREATE_DOCUMENT_API_URL "http://dmss-archive-services:8090/api/document/create"
check "... visual-signature template keeps {docid} and its path" \
  loads "$c" VISUAL_SIGNATURE_API_TEMPLATE "http://dmss-container-and-signature-services:8092/api/signing/visual/pdf/{docid}/sign"
check "... idempotent: a second plan and apply change nothing" \
  bash -c '[[ -z "$(python3 "$1" plan "$2" internal)" ]]' _ "$(native "$tool")" "$c"
cp "$c" "${work}/int.once.js"; dmss apply "$c" internal >/dev/null
check "... and the file is byte-identical after the second apply" cmp -s "$c" "${work}/int.once.js"
dmss apply "$c" public --host "$H" >/dev/null
check "apply public: back to byte-identical with the file before (the added key and its comments removed)" cmp -s "$c" "${work}/pub.orig.js"
check "... idempotent too" test -z "$(dmss plan "$c" public --host "$H")"

# the public address of an ARCHIVE_PUBLIC_BASE_URL beats --host
dmss apply "$c" internal >/dev/null
dmss apply "$c" public --host other.example.org >/dev/null
check "apply public takes the host from ARCHIVE_PUBLIC_BASE_URL, not --host" \
  bash -c 'grep -q "\"https://'"$H"'/archive/api/\"" "$1" && ! grep -q "other.example.org" "$1"' _ "$c"

# CRLF and single quotes
crlf="${work}/crlf.js"
perl -pe 's/\n/\r\n/' "${work}/pub.orig.js" > "$crlf"; cp "$crlf" "${work}/crlf.orig.js"
dmss apply "$crlf" internal >/dev/null
check "CRLF file: the added lines use CRLF, no bare LF appears" \
  bash -c '! perl -0777 -ne "exit(/(?<!\r)\n/ ? 0 : 1)" "$1"' _ "$crlf"
dmss apply "$crlf" public --host "$H" >/dev/null
check "CRLF file: internal then public is byte-identical" cmp -s "$crlf" "${work}/crlf.orig.js"
sq="${work}/sq.js"
perl -pe "s/\"(https:[^\"]*)\"/'\$1'/ if /_URL|_TEMPLATE/" "${work}/pub.orig.js" > "$sq"
check "(setup) single-quoted values are recognised" test "$(count_keys "$sq" public)" = 5
dmss apply "$sq" internal >/dev/null
check "single-quoted values: rewritten in place, quotes kept" \
  bash -c 'grep -q "ARCHIVE_API_BASE_URL: '"'"'http://dmss-archive-services:8090/api/'"'"'," "$1"' _ "$sq"

# a value of the operator's own, a mixed file, a key that is not a literal
mx="${work}/mixed.js"
cp "${work}/pub.orig.js" "$mx"
perl -i -pe 's#^(\s*FORM_FILL_API_URL:\s*)".*"#$1"http://forms.internal.example:9000/fill"#; s#^(\s*DOCUMENT_DOWNLOAD_API_URL:\s*)".*"#$1"http://dmss-archive-services:8090/api/document/"#; s#^(\s*CREATE_DOCUMENT_API_URL:\s*)".*"#$1process.env.CREATE_URL || "x"#' "$mx"
st="$(dmss status "$mx")"
has "mixed file: a hand-made address is reported as other" "$st" "FORM_FILL_API_URL	other	http://forms.internal.example:9000/fill"
has "... a JS expression is other too" "$st" "CREATE_DOCUMENT_API_URL	other	"
has "... an in-network key is internal" "$st" "DOCUMENT_DOWNLOAD_API_URL	internal	"
dmss apply "$mx" internal >/dev/null
check "apply internal: only the public keys change (other and internal left as they are)" \
  bash -c 'grep -q "forms.internal.example:9000/fill" "$1" && grep -q "process.env.CREATE_URL" "$1" && grep -q "ARCHIVE_API_BASE_URL: \"http://dmss-archive-services" "$1"' _ "$mx"

# an ARCHIVE_PUBLIC_BASE_URL the operator wrote is never removed or replaced
op="${work}/operator.js"
cp "${work}/pub.orig.js" "$op"
perl -i -pe 's#^(\s*ARCHIVE_API_BASE_URL:)#    ARCHIVE_PUBLIC_BASE_URL: "https://files.example.org/archive/api/",\n$1#' "$op"
dmss apply "$op" internal >/dev/null
check "an existing ARCHIVE_PUBLIC_BASE_URL is kept as written, none added" \
  bash -c '[[ "$(grep -c "ARCHIVE_PUBLIC_BASE_URL" "$1")" == 1 ]] && grep -q "files.example.org" "$1"' _ "$op"
dmss apply "$op" public --host "$H" >/dev/null
check "... and survives the reverse (it carries no marker)" grep -q 'ARCHIVE_PUBLIC_BASE_URL: "https://files.example.org' "$op"
check "... the reverse took the host from it" bash -c 'grep -q "ARCHIVE_API_BASE_URL: \"https://files.example.org/archive/api/\"" "$1"' _ "$op"

# nothing to name the host: refuse, write nothing
nh="${work}/nohost.js"
cp "$shipped" "$nh"; perl -0777 -i -pe 's/\n    \/\/ The archive address a webhook receiver can reach\..*?ARCHIVE_PUBLIC_BASE_URL: "[^"]*",//s' "$nh"
cp "$nh" "${work}/nohost.orig.js"
err="$(dmss apply "$nh" public 2>&1 >/dev/null)"; rc=$?
check "public with no ARCHIVE_PUBLIC_BASE_URL and no --host: exit 3, says why, file untouched" \
  bash -c '[[ "$1" == 3 ]] && grep -q "cannot tell which public hostname" <<< "$2" && cmp -s "$3" "$4"' _ "$rc" "$err" "$nh" "${work}/nohost.orig.js"
dmss status "${work}/does-not-exist.js" >/dev/null 2>&1; rc=$?
check "an unreadable config.js: exit 3" test "$rc" = 3
dmss plan "$shipped" sideways >/dev/null 2>&1; rc=$?
check "an unknown direction: exit 2" test "$rc" = 2

if [[ "$linux" == true ]]; then
  pm="${work}/perm.js"; cp "${work}/pub.orig.js" "$pm"; chmod 640 "$pm"
  ino="$(stat -c %i "$pm")"
  dmss apply "$pm" internal >/dev/null
  check "apply writes in place: same inode and mode 640" bash -c '[[ "$(stat -c %i "$1")" == "$2" && "$(stat -c %a "$1")" == 640 ]]' _ "$pm" "$ino"
fi

# ── upgrade.sh ──────────────────────────────────────────────────────────────
echo ""
echo "upgrade.sh:"
fresh() {  # <name> [public]: a new throwaway copy; "public" = an older host's addresses
  local d="${work}/$1"
  copy_tree "$d"
  chmod 640 "$d/config/config.js"
  [[ "${2:-}" == public ]] && make_public "$d/config/config.js"
  # the stores are mounted from outside the checkout, as on an overlay host,
  # so no case depends on who may own an in-tree signed-output/
  mkdir -p "${work}/storage-$1/signed-output" "${work}/storage-$1/docs"
  cat > "$d/docker-compose.override.yml" <<EOF
services:
  ps-server:
    volumes:
      - "$(native "${work}/storage-$1")/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - "$(native "${work}/storage-$1")/docs:/docs"
EOF
  printf '%s' "$d"
}
upgrade() {  # <repo> [args...]
  local d="$1"; shift
  : > "$STUB_LOG"
  (cd "$d" && bash installation-scripts/upgrade.sh "$@" 2>&1 </dev/null)
}
set_registry() {  # <repo> <capability> <python statements editing that entry as `e`>
  python3 - "$(native "$1/release/capabilities.json")" "$2" "$3" <<'PY'
import json, sys
path, cap, code = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path, encoding="utf-8"))
e = data["capabilities"][cap]
exec(code)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
}
# The two states a capability is in: merged but in no release (no min; the
# newest tag known to lack it), and released (a min). The cases use fixtures of
# each, so they hold whichever state release/capabilities.json is in.
pending() {  # <repo> <capability> <component> <newest tag lacking it>
  set_registry "$1" "$2" 'e["min"] = {}; e["unreleased"] = {"'"$3"'": "'"$4"'"}; e["todo"] = "x"'
}
released() {  # <repo> <capability> <component> <min tag>
  set_registry "$1" "$2" 'e["min"] = {"'"$3"'": "'"$4"'"}; e.pop("unreleased", None); e.pop("todo", None)'
}
plan_item() {  # <machine plan> <id> -> "status|body"
  awk -v id="$2" '
    $0 == "id=" id { on = 1; next }
    on && /^status=/ { st = substr($0, 8) }
    on && $0 == "###PLAN-BODY-BEGIN" { inbody = 1; next }
    on && $0 == "###PLAN-BODY-END" { printf "%s|%s", st, body; exit }
    inbody { body = body $0 "\n" }
  ' <<< "$1"
}
fingerprint() { (cd "$1" && sha256sum docker-compose.yml config/config.js config/constants.json); }

lacking="$srv_ok"
check "release/capabilities.json: dmss-internal-urls and client-origin-defaults are each released (a min) or marked unreleased (no min, the newest tag lacking it, a todo)" \
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))["capabilities"]
for name, comp in (("dmss-internal-urls", "ps-server"), ("client-origin-defaults", "ps-client")):
    e = c[name]
    released = bool(e["min"].get(comp))
    pending = bool(e.get("unreleased", {}).get(comp)) and e["min"] == {} and bool(e.get("todo"))
    if released == pending:
        sys.exit(1)
' "$(native "${pristine}/release/capabilities.json")"

# the default-behaviour invariant: an older host's plain upgrade leaves the addresses alone
d="$(fresh plain public)"
pending "$d" dmss-internal-urls ps-server "$lacking"
cp "$d/config/config.js" "${work}/plain.before"
out="$(upgrade "$d" --client-tag "$cli_ok")"
check "a plain upgrade on a public-address host: addresses unchanged (the stub pull then fails the run)" \
  bash -c 'cmp -s "$1" "$2" && grep -q "^UPGRADE FAILED: could not pull" <<< "$3"' _ "$d/config/config.js" "${work}/plain.before" "$out"
plan="$(upgrade "$d" --server-tag "$srv_ok" --plan-only --plan-format machine)"
check "its plan has no dmss-urls item" bash -c '! grep -q "^id=dmss-urls$" <<< "$1"' _ "$plan"
out="$(upgrade "$d" --plan-only)"; rc=$?
check "an upgrade with nothing to do is still refused (no flag, no tag)" test "$rc" = 2
has "... and the message names the new flags" "$out" "--use-internal-dmss-urls"

out="$(upgrade "$d" --use-internal-dmss-urls --use-public-dmss-urls --plan-only)"; rc=$?
check "both flags: exit 2" bash -c '[[ "$1" == 2 ]] && grep -q "are opposites" <<< "$2"' _ "$rc" "$out"

# the capability: merged, in no release yet
before="$(fingerprint "$d")"
out="$(upgrade "$d" --use-internal-dmss-urls --plan-only)"; rc=$?
check "--use-internal-dmss-urls on ps-server $srv_ok (no release has it yet): refused, exit 2" test "$rc" = 2
has "... says no released ps-server has it, and why" "$out" "has the capability yet"
has "... names the tag to beat" "$out" "newer than :${lacking}"
check "... nothing written (no pull, no edit)" bash -c '[[ "$1" == "$2" ]] && ! grep -q "^docker compose .*pull" "$3"' _ "$before" "$(fingerprint "$d")" "$STUB_LOG"
out="$(upgrade "$d" --require-capability dmss-internal-urls --plan-only)"; rc=$?
check "--require-capability dmss-internal-urls: the same refusal (exit 2)" bash -c '[[ "$1" == 2 ]] && grep -q "newer than :" <<< "$2"' _ "$rc" "$out"
out="$(upgrade "$d" --require-capability dmss-internal-urls --server-tag 9.99 --plan-only)"; rc=$?
check "... and a tag newer than the one known to lack it clears the capability gate (then the approved-tag gate refuses 9.99)" \
  bash -c '[[ "$1" == 2 ]] && ! grep -q "newer than :" <<< "$2" && grep -q "does not approve" <<< "$2"' _ "$rc" "$out"
out="$(upgrade "$d" --require-capability signing-audit --plan-only)"; rc=$?
check "--require-capability on a released capability: unchanged (signing-audit passes on ps-server $srv_ok)" test "$rc" = 0
before="$(fingerprint "$d")"
out="$(upgrade "$d" --require-capability signing-audit)"; rc=$?
check "--require-capability alone is a check of what is deployed: exit 0, nothing planned, written or pulled" \
  bash -c '[[ "$1" == 0 && "$2" == "$6" ]] && grep -q "^Capability check passed: signing-audit" <<< "$4" && ! grep -q "^docker compose" "$5"' _ "$rc" "$before" "$d" "$out" "$STUB_LOG" "$(fingerprint "$d")"
out="$(upgrade "$d" --require-capability no-such-capability --plan-only)"; rc=$?
check "... an unknown capability: still exit 2, naming the registry" bash -c '[[ "$1" == 2 ]] && grep -q "unknown capability" <<< "$2"' _ "$rc" "$out"
out="$(upgrade "$d" --use-public-dmss-urls --plan-only --plan-format machine)"; rc=$?
got="$(plan_item "$out" dmss-urls)"
check "--use-public-dmss-urls needs no capability: on a public host the plan says already applied" bash -c '[[ "$1" == 0 && "$2" == already-applied\|* ]]' _ "$rc" "$got"

# once a release has it
r="$(fresh released public)"
released "$r" dmss-internal-urls ps-server "$srv_ok"
out="$(upgrade "$r" --use-internal-dmss-urls --plan-only)"; rc=$?
check "with a minimum equal to the running ps-server: the plan is produced (exit 0)" test "$rc" = 0
has "... lists the migration and the file" "$out" "[WILL APPLY] dmss-urls"
has "... shows old and new for a key" "$out" "now: http://dmss-archive-services:8090/api/document/create"
has "... shows the public address kept for webhooks" "$out" "ARCHIVE_PUBLIC_BASE_URL (new): https://${H}/archive/api/"
has "... and that ps-server is recreated" "$out" "Recreates the ps-server container"
check "... a plan writes nothing" bash -c '! ls -A "$1" | grep -q "\.bak$" && [[ "$(python3 "$2" status "$1/config/config.js" | awk -F"\t" "\$2==\"public\"" | wc -l | tr -d " ")" == 5 ]]' _ "$r" "$(native "$tool")"
plan="$(upgrade "$r" --use-internal-dmss-urls --plan-only --plan-format machine)"
got="$(plan_item "$plan" dmss-urls)"
check "machine plan: dmss-urls will-apply, body shows the keys" bash -c '[[ "$1" == will-apply\|* ]] && grep -q "ARCHIVE_API_BASE_URL" <<< "$1"' _ "$got"
check "... and the other migrations are still listed" bash -c 'grep -q "^id=signing-audit$" <<< "$1" && grep -q "^id=keycloak-backend-audience$" <<< "$1"' _ "$plan"

out="$(upgrade "$r" --use-internal-dmss-urls)"; rc=$?
has "real run: Step 4a runs and rewrites the keys" "$out" "Step 4a/6: Switching the DMSS addresses in config.js (internal)"
has "... names a rewritten key" "$out" "ARCHIVE_API_BASE_URL: https://${H}/archive/api/ -> http://dmss-archive-services:8090/api/"
check "... config.js now has five in-network keys and loads" bash -c '[[ "$(python3 "$1" status "$2/config/config.js" | awk -F"\t" "\$2==\"internal\"" | wc -l | tr -d " ")" == 5 ]]' _ "$(native "$tool")" "$r"
check "... only ps-server is pulled (never the whole stack)" \
  bash -c 'grep -qx "docker compose pull ps-server" "$1" && ! grep -qx "docker compose pull" "$1"' _ "$STUB_LOG"
check "... the stub pull then fails the run, with a rollback command (rc=${rc})" bash -c 'grep -q "^UPGRADE FAILED: could not pull" <<< "$1" && grep -q "rollback.sh --to" <<< "$1"' _ "$out"
check "... a rollback snapshot and a config.js.bak were taken before the edit" bash -c 'ls "$1"/.rollback-snapshots/*/config.js >/dev/null 2>&1 && [[ -f "$1/config/config.js.bak" ]]' _ "$r"
plan="$(upgrade "$r" --use-internal-dmss-urls --plan-only --plan-format machine)"
got="$(plan_item "$plan" dmss-urls)"
check "afterwards the plan reports it already applied" bash -c '[[ "$1" == already-applied\|* ]]' _ "$got"
cp "$r/config/config.js" "${work}/released.after1"
out="$(upgrade "$r" --use-internal-dmss-urls)"
has "a second real run: nothing to change" "$out" "DMSS addresses already in the requested (internal) form - nothing changed"
check "... config.js byte-identical" cmp -s "$r/config/config.js" "${work}/released.after1"

out="$(upgrade "$r" --use-public-dmss-urls)"
has "--use-public-dmss-urls real run: restores the public keys" "$out" "ARCHIVE_API_BASE_URL: http://dmss-archive-services:8090/api/ -> https://${H}/archive/api/"
check "... byte-identical to the config.js before the switch" cmp -s "$r/config/config.js" "${work}/plain.before"

# a flag that restarts ps-server only
check "--use-public-dmss-urls alone also pulls ps-server only" bash -c 'grep -qx "docker compose pull ps-server" "$1"' _ "$STUB_LOG"

# a host whose nginx names no single server_name and a config.js with no public address
n="$(fresh nohost)"
released "$n" dmss-internal-urls ps-server "$srv_ok"
cp "$n/config/config.js" "${work}/nohost.config"
perl -0777 -i -pe 's/\n    \/\/ The archive address a webhook receiver can reach\..*?ARCHIVE_PUBLIC_BASE_URL: "[^"]*",//s' "$n/config/config.js"
perl -i -pe 's/server_name [^;]+;/server_name a.example.com b.example.com;/' "$n/nginx/nginx.conf"
out="$(upgrade "$n" --use-public-dmss-urls --plan-only)"; rc=$?
has "public direction with no host to write: the plan says so (and still exits 0)" "$out" "Cannot be done: cannot tell which public hostname"
out="$(upgrade "$n" --use-public-dmss-urls)"; rc=$?
check "... a real run stops with exit 3 and leaves config.js alone" bash -c '[[ "$1" == 3 ]] && grep -q "could not switch the DMSS addresses" <<< "$2" && grep -q "ARCHIVE_API_BASE_URL: \"http://dmss-archive" "$3/config/config.js"' _ "$rc" "$out" "$n"

# ── validate-config.sh ──────────────────────────────────────────────────────
echo ""
echo "validate-config.sh (each run takes a while: it asks docker compose for the model):"
sed_host() {  # <repo> <host>: nginx and the Keycloak URLs on <host>
  perl -i -pe "s/padsign\\.trustlynx\\.com/$2/g" "$1/nginx/nginx.conf" "$1/config/constants.json" "$1/docker-compose.yml"
  perl -i -pe "s#https://padsign\\.trustlynx\\.com#https://$2#g" "$1/config/config.js"
}

v="$(fresh validate1)"
sed_host "$v" "$H"
pending "$v" client-origin-defaults ps-client "$cli_ok"
released "$v" dmss-internal-urls ps-server "$srv_ok"
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "the shipped in-network addresses: accepted, with what that allows" "$section" "OK   ps-server reaches the DMSS services by their in-network addresses"
lacks "... no failure in the section" "$section" "FAIL"
has "constants.json with the Keycloak keys: KEYCLOAK_URL matches" "$out" "OK   constants.json KEYCLOAK_URL matches"

# public addresses naming this host: accepted
make_public "$v/config/config.js"
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "all public, naming this host: accepted, with the nginx routes they need" "$section" "OK   ps-server reaches the DMSS services through nginx at https://${H}/"
lacks "... no failure" "$section" "FAIL"

# public addresses naming another host, a mixed file and a wrong service
perl -i -pe 's#(CREATE_DOCUMENT_API_URL: ")https://[^/]+#${1}https://elsewhere.example.org#' "$v/config/config.js"
perl -i -pe 's#^(\s*FORM_FILL_API_URL:\s*)".*"#$1"http://dmss-container-and-signature-services:8092/api/forms/fill/template/application"#' "$v/config/config.js"
perl -i -pe 's#^(\s*DOCUMENT_DOWNLOAD_API_URL:\s*)".*"#$1"http://dmss-container-and-signature-services:8092/api/document/"#' "$v/config/config.js"
# constants.json without the Keycloak URL keys, on the current ps-client
python3 - "$(native "$v/config/constants.json")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k in ("KEYCLOAK_URL", "KEYCLOAK_REDIRECT_URI", "KEYCLOAK_POST_LOGOUT_REDIRECT_URI"):
    d.pop(k, None)
json.dump(d, open(p, "w", encoding="utf-8"), indent=4)
PY
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "a public key naming another host: FAIL, says which and what to run" "$section" "FAIL config.js CREATE_DOCUMENT_API_URL names elsewhere.example.org, not '${H}'"
has "a key holding the other service's address: FAIL" "$section" "FAIL config.js DOCUMENT_DOWNLOAD_API_URL is 'http://dmss-container-and-signature-services:8092/api/document/', the container service's address, but this key needs the archive service's"
has "a mix of in-network and public: WARN that closing the routes breaks the public ones" "$section" "WARN 1 DMSS address(es) are in-network and 2 go through nginx"
has "constants.json without the Keycloak keys on ps-client $cli_ok (no default yet): FAIL" "$out" "FAIL constants.json has no KEYCLOAK_URL KEYCLOAK_REDIRECT_URI KEYCLOAK_POST_LOGOUT_REDIRECT_URI, and ps-client ${cli_ok} has no default for it"

# the same constants.json on a ps-client that has the defaults
released "$v" client-origin-defaults ps-client "$cli_ok"
# an enabled webhook with in-network addresses and no ARCHIVE_PUBLIC_BASE_URL
cp "$shipped" "$v/config/config.js"
perl -i -pe "s#https://padsign\\.trustlynx\\.com#https://$H#g" "$v/config/config.js"
perl -0777 -i -pe 's/(type:\s*"webhook",\s*enabled:\s*)false/${1}true/; s/\n    \/\/ The archive address a webhook receiver can reach\..*?ARCHIVE_PUBLIC_BASE_URL: "[^"]*",//s' "$v/config/config.js"
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "constants.json without the Keycloak keys on a ps-client with the defaults: accepted" "$out" "OK   constants.json leaves out KEYCLOAK_URL KEYCLOAK_REDIRECT_URI KEYCLOAK_POST_LOGOUT_REDIRECT_URI: ps-client ${cli_ok} uses this page's origin"
has "an enabled webhook with in-network addresses and no ARCHIVE_PUBLIC_BASE_URL: WARN" "$section" "WARN a webhook strategy is enabled and the DMSS addresses are in-network, but config.js has no ARCHIVE_PUBLIC_BASE_URL"
lacks "... no FAIL in the section" "$section" "FAIL"

# ARCHIVE_PUBLIC_BASE_URL on the demo host (a stash pop that took the release's value)
perl -i -pe 's#^(\s*ARCHIVE_API_BASE_URL:)#    ARCHIVE_PUBLIC_BASE_URL: "https://padsign.trustlynx.com/archive/api/",\n$1#' "$v/config/config.js"
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "an ARCHIVE_PUBLIC_BASE_URL naming another host: WARN, with the fix" "$section" "WARN config.js ARCHIVE_PUBLIC_BASE_URL names padsign.trustlynx.com, not '${H}'"
# and the ps-server that ignores it
released "$v" dmss-internal-urls ps-server 99.0
perl -i -pe 's#^(\s*ARCHIVE_PUBLIC_BASE_URL:.*)$#    ARCHIVE_PUBLIC_BASE_URL: "https://'"$H"'/archive/api/",#' "$v/config/config.js"
out="$(cd "$v" && bash installation-scripts/validate-config.sh --host "$H" 2>&1 </dev/null)"
section="$(awk '/^DMSS service addresses/{on=1; next} on && /^$/{exit} on' <<< "$out")"
has "an enabled webhook on a ps-server older than the capability: WARN" "$section" "WARN ps-server ${srv_ok} ignores ARCHIVE_PUBLIC_BASE_URL"

# ── configure-host.sh ───────────────────────────────────────────────────────
echo ""
echo "configure-host.sh (constants.json and config.js):"
ch="$(fresh configure)"
python3 - "$(native "$ch/config/constants.json")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k in ("KEYCLOAK_URL", "KEYCLOAK_REDIRECT_URI", "KEYCLOAK_POST_LOGOUT_REDIRECT_URI"):
    d.pop(k, None)
d["PS_DOWNLOAD_API"] = "/archive/api/document/"
d["PDF_TEST_PATH"] = "/portal/template"
json.dump(d, open(p, "w", encoding="utf-8"), indent=4)
PY
: > "$STUB_LOG"
out="$(cd "$ch" && CONFIGURE_HOST_ADMIN_PASS=x bash installation-scripts/configure-host.sh --host padsign.test.local 2>&1 </dev/null)"; rc=$?
keys="$(python3 - "$(native "$ch/config/constants.json")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(sorted(k for k in d if k.startswith("KEYCLOAK_"))), d["PS_DOWNLOAD_API"], d["PDF_TEST_PATH"])
PY
)"
check "configure-host.sh --host on a constants.json without the Keycloak URL keys: exits 0 (rc=${rc})" test "$rc" = 0
check "... adds none of them (the client's same-origin defaults apply) and keeps the relative values: [${keys}]" \
  test "$keys" = "KEYCLOAK_CLIENT_ID,KEYCLOAK_REALM /archive/api/document/ /portal/template"
check "... the in-network DMSS addresses in config.js are untouched" test "$(count_keys "$ch/config/config.js" internal)" = 5
check "... ARCHIVE_PUBLIC_BASE_URL follows the host" loads "$ch/config/config.js" ARCHIVE_PUBLIC_BASE_URL "https://padsign.test.local/archive/api/"
ch2="$(fresh configure2 public)"
out="$(cd "$ch2" && CONFIGURE_HOST_ADMIN_PASS=x bash installation-scripts/configure-host.sh --host padsign.test.local 2>&1 </dev/null)"
check "a config.js on the public addresses is still re-pointed at the new host" \
  bash -c '[[ "$(python3 "$1" status "$2/config/config.js" | awk -F"\t" "\$2==\"public\" && \$3 ~ /padsign.test.local/" | wc -l | tr -d " ")" == 5 ]]' _ "$(native "$tool")" "$ch2"
ch3="$(fresh configure3)"
(cd "$ch3" && CONFIGURE_HOST_ADMIN_PASS=x bash installation-scripts/configure-host.sh --host padsign.test.local >/dev/null 2>&1 </dev/null)
keys="$(python3 - "$(native "$ch3/config/constants.json")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d["KEYCLOAK_URL"], d["KEYCLOAK_REDIRECT_URI"], d["PS_DOWNLOAD_API"])
PY
)"
check "a constants.json with the keys: rewritten to the host as before" \
  test "$keys" = "https://padsign.test.local/auth https://padsign.test.local/portal/ https://padsign.test.local/archive/api/document/"

# ── diff-baseline-overlay.sh ────────────────────────────────────────────────
echo ""
echo "diff-baseline-overlay.sh (overlay values it expects):"
drop_keycloak_keys() {  # <repo>: constants.json as the application now ships it
  python3 - "$(native "$1/config/constants.json")" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
for k in ("KEYCLOAK_URL", "KEYCLOAK_REDIRECT_URI", "KEYCLOAK_POST_LOGOUT_REDIRECT_URI"):
    d.pop(k, None)
d["PDF_TEST_PATH"] = "/portal/template"
json.dump(d, open(p, "w", encoding="utf-8"), indent=4)
PY
}
base="$(fresh ovbase)"; live="$(fresh ovlive public)"
dmss apply "$live/config/config.js" public --host "$H" >/dev/null
perl -i -pe "s#https://padsign\.trustlynx\.com#https://$H#g" "$live/config/constants.json"
out="$(bash "$base/installation-scripts/diff-baseline-overlay.sh" --baseline "$base" --live "$live" 2>&1 </dev/null)"
if grep -q Traceback <<< "$out"; then
  # Git Bash: the tool's python cannot open the /tmp paths bash hands it
  echo "  (diff-baseline-overlay.sh cannot run under this shell - skipped; Linux runs it)"
else
check "DMSS addresses public in the live file, in-network in the baseline: only expected overlay values differ"   bash -c '! grep -q "FAIL\|DRIFT" <<< "$1" && grep -q "config/config.js ==" <<< "$1"' _ "$out"
drop_keycloak_keys "$base"
out="$(bash "$base/installation-scripts/diff-baseline-overlay.sh" --baseline "$base" --live "$live" 2>&1 </dev/null)"
check "baseline constants.json without the Keycloak URL keys, live with them: no drift" bash -c '! grep -q "FAIL\|DRIFT" <<< "$1"' _ "$out"
out="$(bash "$live/installation-scripts/diff-baseline-overlay.sh" --baseline "$live" --live "$base" 2>&1 </dev/null)"
check "... and the other way round: no drift" bash -c '! grep -q "FAIL\|DRIFT" <<< "$1"' _ "$out"
fi

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
