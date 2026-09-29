#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for support-bundle.sh:
#
#   - usage errors exit 2 (an unknown --since unit included);
#   - a bundle is written, with every item, and "BUNDLE <path>" as the last
#     stdout line (the Deployment Wizard reads the path from there);
#   - nothing secret reaches the archive: bearer tokens and base64 images in
#     logs, .env values, config.js keys; signed documents, the signing
#     activity log and TLS keys are never read; the wizard's log is never
#     collected;
#   - with Docker down and a report script missing, every failing collector
#     is a WARN and the bundle is still written.
#
# Usage:
#   ./installation-scripts/tests/test-support-bundle.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` and `cosign` are stubs: `docker compose config
# --services` lists ps-server, nginx and wizard, `docker compose logs` prints
# a bearer token, a base64 signature image and a "ready" line, and every
# other call that would reach a daemon fails. The file-mode case needs real
# POSIX modes: Linux only (Git Bash on NTFS has none).
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency,
# 124 the watchdog (lib/watchdog.sh) stopped it.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git tar; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR
unset CI PADSIGN_REQUIRE_SIGNATURES KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD ALERT_WEBHOOK_URL

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 40 | sed 's/^/       | /'; return 0; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}

copy_tree() {  # <dest>: tracked files as they are on disk now
  mkdir -p "$1"
  (cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$src_root" && xargs -0 cp --parents -t "$1" 2>/dev/null) || true
}

# ── stubs ───────────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
STUB_B64="$(printf '%*s' 300 '' | tr ' ' A)"
export STUB_LOG="${work}/stub-argv.log" STUB_B64
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
down() { echo "Cannot connect to the Docker daemon (stub)" >&2; exit 1; }
if [[ "${1:-}" == compose ]]; then
  shift
  sub="${1:-}"; shift || true
  # compose config reads files only; everything else needs the daemon.
  [[ -n "${STUB_DOCKER_DOWN:-}" && "$sub" != config ]] && down
  case "$sub" in
    config)
      if [[ " $* " == *" --services "* ]]; then printf '%s\n' ps-server nginx wizard; exit 0; fi
      exit 1 ;;
    logs)
      svc="${*: -1}"
      if [[ "$svc" == wizard ]]; then echo "Access token: WIZARD-TOKEN-MARKER"; exit 0; fi
      printf '2026-09-29T10:00:00Z %s Authorization: Bearer abcdef123456\n' "$svc"
      printf '2026-09-29T10:00:00Z %s {"signatureImage":"data:image/png;base64,%s"}\n' "$svc" "$STUB_B64"
      printf '2026-09-29T10:00:01Z %s ready\n' "$svc"
      exit 0 ;;
    ps)
      [[ " $* " == *" -q "* ]] && exit 1
      echo "NAME  IMAGE  SERVICE  STATUS (stub compose ps)"
      exit 0 ;;
    images) echo "CONTAINER  REPOSITORY  TAG (stub compose images)"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
[[ -n "${STUB_DOCKER_DOWN:-}" ]] && down
case "${1:-}" in
  version) echo "27.0.0-stub"; exit 0 ;;
  info) echo "overlay2 /var/lib/docker-stub"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
# validate-config.sh verifies image signatures with cosign when it is
# installed: never let that reach a registry from here.
printf '#!/usr/bin/env bash\nexit 1\n' > "${bin}/cosign"
chmod +x "${bin}/docker" "${bin}/cosign"
export PATH="${bin}:${PATH}"

fresh() {  # <name>: a throwaway deployment with a hostname, .env and data; prints its path
  local d="${work}/$1"
  copy_tree "$d"
  sed -i 's/server_name [^;]*;/server_name padsign.example.com;/' "$d/nginx/nginx.conf"
  printf 'KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=supersecret1\n' > "$d/.env"
  # What must never be read: documents, the signing activity log, TLS keys.
  mkdir -p "$d/signed-output/.padsign-audit" "$d/docs" "$d/nginx/certs"
  echo "DO-NOT-SHIP-MARKER audit" > "$d/signed-output/.padsign-audit/2026-09.jsonl"
  echo "DO-NOT-SHIP-MARKER signed" > "$d/signed-output/signed.pdf"
  echo "DO-NOT-SHIP-MARKER archive" > "$d/docs/doc.pdf"
  echo "DO-NOT-SHIP-MARKER key" > "$d/nginx/certs/padsign.example.com.key"
  printf '%s' "$d"
}
bundle() {  # <repo> [args...]: stdout only (the wizard parses stdout)
  local d="$1"; shift
  : > "$STUB_LOG"
  (cd "$d" && bash installation-scripts/support-bundle.sh "$@" </dev/null 2>"${work}/stderr")
}
last_line() { printf '%s\n' "$1" | tail -n 1; }

# ── usage ───────────────────────────────────────────────────────────────────
echo ""
echo "Usage errors:"
d="$(fresh main)"
out="$(bundle "$d" --since 1x --output-dir "${work}/usage-out")"; rc=$?
check "--since 1x: exit 2" test "$rc" = 2
check "... and nothing written" test ! -e "${work}/usage-out"
out="$(bundle "$d" --bogus)"; rc=$?
check "an unknown argument: exit 2" test "$rc" = 2
out="$(bundle "$d" --output-dir)"; rc=$?
check "--output-dir without a value: exit 2" test "$rc" = 2

# ── a bundle ────────────────────────────────────────────────────────────────
echo ""
echo "A bundle:"
out="$(bundle "$d" --output-dir "${work}/out")"; rc=$?
check "exit 0" test "$rc" = 0
last="$(last_line "$out")"
path="${last#BUNDLE }"
if [[ "$last" == "BUNDLE ${work}/out/"* ]] \
   && [[ "$(basename "$path")" =~ ^padsign-support-padsign\.example\.com-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]; then
  ok_case "last stdout line: BUNDLE ${work}/out/padsign-support-padsign.example.com-<UTC>.tar.gz"
else
  fail_case "last stdout line is not the BUNDLE line" "$out"
fi
check "... and that file exists" test -f "$path"

x="${work}/x"
mkdir -p "$x"
tar -xzf "$path" -C "$x" 2>/dev/null
missing=""
for f in README.txt versions.txt compose-ps.txt monitor-status.txt validate-config.txt \
         config/config.js config/constants.json nginx/nginx.conf docker-compose.yml \
         config/env-keys.txt logs/ps-server.log logs/nginx.log host.txt; do
  [[ -f "$x/$f" ]] || missing+="${f} "
done
if [[ -z "$missing" ]]; then
  ok_case "the archive holds every item (README, versions, compose-ps, both reports, config, env-keys, logs, host)"
else
  fail_case "the archive lacks: ${missing}" "$(cd "$x" && find . -type f | sort)"
fi
check "... and no logs/wizard.log" test ! -e "$x/logs/wizard.log"
check "... the wizard's log was never read (no 'compose logs ... wizard')" \
  bash -c '! grep -q "compose logs .* wizard$" "$1"' _ "$STUB_LOG"
check "... logs asked for with --no-color --timestamps --since 24h" \
  grep -q -- '^docker compose logs --no-color --timestamps --since 24h ps-server$' "$STUB_LOG"

leaks="$(grep -rlE -e 'abcdef123456' -e 'supersecret1' -e 'A{50}' -e 'WIZARD-TOKEN-MARKER' -e 'DO-NOT-SHIP-MARKER' "$x")"
if [[ -z "$leaks" ]]; then
  ok_case "no file holds the bearer token, the .env value, a base64 image, the wizard token or document/key content"
else
  fail_case "secrets or documents reached the archive" "$leaks"
fi
check "config/env-keys.txt names KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD" grep -qx 'KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD' "$x/config/env-keys.txt"
check "logs/ps-server.log keeps its ordinary lines ('ready')" grep -q 'ps-server ready$' "$x/logs/ps-server.log"
check "... with the token and image elided in place" \
  bash -c 'grep -q "Authorization: Bearer <redacted>" "$1" && grep -q "data:image/png;base64,<base64 300 chars elided>" "$1"' _ "$x/logs/ps-server.log"
check "config/config.js: REGISTER_PDF_API_KEY is <redacted>" grep -q 'REGISTER_PDF_API_KEY: "<redacted>"' "$x/config/config.js"
check "README.txt says what is not included" \
  grep -qF "Not included: signed documents, the signing activity log, .env values, TLS private keys, the wizard's own log" "$x/README.txt"
check "an '  OK   ' line for logs/ps-server.log" grep -q '^  OK   logs/ps-server\.log$' <<< "$out"
# The wizard's parseHelperCheckOutput reads /^\s{2,4}(OK|FAIL|WARN)\b\s+(.*)$/.
bad_shape="$(grep -E '^[[:space:]]*(OK|WARN|FAIL)' <<< "$out" | grep -vE '^  (OK   |WARN )[^ ]' || true)"
check "every item line is '  OK   <item>' or '  WARN <item>: ...' (and none is FAIL)" test -z "$bad_shape"
# ... and folds every non-blank line after an item into that item's message.
check "a blank line ends the item list, before the summary and BUNDLE lines" \
  bash -c 'grep -A1 "^  OK   README.txt$" <<< "$1" | tail -n 1 | grep -qx ""' _ "$out"
if [[ "$linux" == true ]]; then
  check "archive mode 600" test "$(stat -c %a "$path")" = 600
  check "output directory created mode 700" test "$(stat -c %a "${work}/out")" = 700
else
  echo "  (file modes need Linux - skipped)"
fi

# ── Docker down, a report script missing ────────────────────────────────────
echo ""
echo "Docker down, monitor-status.sh missing:"
d="$(fresh down)"
rm -f "$d/installation-scripts/monitor-status.sh"
out="$(STUB_DOCKER_DOWN=1 bundle "$d" --since 2d --output-dir "${work}/out-down")"; rc=$?
check "exit 0: the bundle is still written" test "$rc" = 0
last="$(last_line "$out")"
check "... BUNDLE is still the last line, and the file exists" \
  bash -c '[[ "$1" == "BUNDLE $2/"*.tar.gz && -f "${1#BUNDLE }" ]]' _ "$last" "${work}/out-down"
for item in versions.txt compose-ps.txt monitor-status.txt logs/ps-server.log logs/nginx.log host.txt; do
  check "... WARN ${item}" grep -q "^  WARN ${item}" <<< "$out"
done
check "... config files still OK (they need no Docker)" grep -q '^  OK   config/config\.js$' <<< "$out"
x="${work}/x-down"
mkdir -p "$x"
tar -xzf "${last#BUNDLE }" -C "$x" 2>/dev/null
check "... compose-ps.txt says the command failed" grep -q 'docker compose ps -a failed' "$x/compose-ps.txt"
check "... README.txt lists the warnings" grep -q '^Warnings while collecting:' "$x/README.txt"
check "... --since 2d reaches docker compose logs as 48h (docker takes no d unit)" \
  grep -q -- '^docker compose logs --no-color --timestamps --since 48h ps-server$' "$STUB_LOG"

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
exit $(( failed > 0 ))
