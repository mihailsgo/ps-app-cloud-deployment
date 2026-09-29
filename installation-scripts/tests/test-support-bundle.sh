#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for support-bundle.sh:
#
#   - usage errors exit 2 (an unknown --since unit and a bad timeout included);
#   - a bundle is written, with every item, and "BUNDLE <path>" as the last
#     stdout line (the Deployment Wizard reads the path from there); two runs
#     in the same second do not overwrite each other;
#   - nothing secret reaches the archive. The deployment copy carries marker
#     values (LEAK...) where real deployments keep secrets: REGISTER_PDF_API_KEYS
#     entries, webhook URLs and headers, a JDBC password, PEM keys, YAML block
#     scalars, .env; the stub logs print them as real `docker compose logs
#     --timestamps` lines do, with a signing activity line. Signed documents,
#     the signing activity log and TLS keys are never read; the wizard's log
#     (by service name or by image) is never collected;
#   - a command that hangs is stopped by its timeout (a WARN, still a
#     bundle), and a TERM stops the run, its children and its staging dir;
#   - with Docker down and a report script missing, every failing collector
#     is a WARN and the bundle is still written.
#
# Usage:
#   ./installation-scripts/tests/test-support-bundle.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker`, `cosign` and `date` are stubs: `docker compose config`
# lists ps-server, nginx, wizard and setup-ui (a second wizard image),
# `docker compose logs` prints the marker lines, and every other call that
# would reach a daemon fails. The file-mode cases need real POSIX modes:
# Linux only (Git Bash on NTFS has none).
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
unset SUPPORT_BUNDLE_CMD_TIMEOUT SUPPORT_BUNDLE_LOGS_TIMEOUT SUPPORT_BUNDLE_REPORT_TIMEOUT SUPPORT_BUNDLE_DEADLINE

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
export STUB_LOG="${work}/stub-argv.log" STUB_B64 REAL_DATE="$(command -v date)"
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
      if [[ " $* " == *" --services "* ]]; then printf '%s\n' ps-server nginx wizard setup-ui; exit 0; fi
      if [[ " $* " == *" --format json "* ]]; then
        printf '{"name":"stub","services":{'
        printf '"ps-server":{"image":"mihailsgordijenko/ps-server:3.32"},'
        printf '"nginx":{"image":"nginx:1.30.5"},'
        printf '"wizard":{"image":"mihailsgordijenko/padsign-wizard:0.1.1"},'
        printf '"setup-ui":{"image":"mihailsgordijenko/padsign-wizard:0.1.1@sha256:%064d"}}}\n' 0
        exit 0
      fi
      exit 1 ;;
    logs)
      svc="${*: -1}"
      if [[ "$svc" == wizard || "$svc" == setup-ui ]]; then echo "${svc}-1  | 2026-09-29T10:00:00.000000000Z   Access token: WIZARD-TOKEN-MARKER"; exit 0; fi
      if [[ -n "${STUB_SLOW_LOGS:-}" ]]; then
        echo "$$" > "$STUB_SLOW_PID"
        sleep 30
      fi
      p="${svc}-1  | 2026-09-29T10:00:00.000000000Z"
      printf '%s Authorization: Bearer abcdef123456\n' "$p"
      printf '%s {"signatureImage":"data:image/png;base64,%s"}\n' "$p" "$STUB_B64"
      printf '%s   password: LEAKPW\n' "$p"
      printf '%s secret: LEAKSEC\n' "$p"
      printf '%s Using generated security password: 1b2c3d4e-LEAKGEN\n' "$p"
      printf "%s [documentRouting:webhook] delivered { url: 'https://hooks.example.com/T0/B0/LEAK40', status: 200 }\n" "$p"
      printf '%s POST https://fn.azurewebsites.net/api/hook?code=LEAK41\n' "$p"
      printf '%s GET https://padsign.example.com/archive/api/document/77 200\n' "$p"
      printf '%s GET http://dmss-archive-services:8090/api/document/1?token=LEAKQ1 200\n' "$p"
      printf '%s {"padsignAudit":1,"ts":"2026-09-29T10:00:00Z","event":"signature.visual","outcome":"ok","user":"LEAKMAIL@example.com","filename":"LEAKFILE.pdf"}\n' "$p"
      printf '%s ready\n' "${svc}-1  | 2026-09-29T10:00:01.000000000Z"
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
  info) echo "stub-info $*"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
# validate-config.sh verifies image signatures with cosign when it is
# installed: never let that reach a registry from here.
printf '#!/usr/bin/env bash\nexit 1\n' > "${bin}/cosign"
# STUB_DATE pins the UTC time support-bundle.sh names its archive after.
cat > "${bin}/date" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${STUB_DATE:-}" && "$*" == "-u +%Y-%m-%dT%H:%M:%SZ" ]]; then echo "$STUB_DATE"; exit 0; fi
exec "$REAL_DATE" "$@"
STUB
chmod +x "${bin}/docker" "${bin}/cosign" "${bin}/date"
export PATH="${bin}:${PATH}"

# Secrets where real deployments keep them. Every marker contains LEAK.
fixtures() {  # <repo>
  local d="$1"
  python3 - "$d/config/config.js" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
cut = s.rindex("};")
s = s[:cut] + '''    REGISTER_PDF_API_KEYS: [
      { company: "Amit", key: "tlx_pdf_LEAK1" },
      {
        company: "Beta",
        key: "tlx_pdf_LEAK2"
      }
    ],
    TEST_ROUTING: { strategies: [
      { type: "webhook", url: "https://hooks.example.com/services/T0/B0/LEAK3", headers: { "X-Hook-Signature": "LEAK6", "X-Webhook-Key": "LEAK7" } },
      { type: "webhook", url: "https://fn.example.net/api/hook?token=LEAK4",
        headers: {
          "X-Auth": "LEAK8",
          'X-Other': 'LEAK9'
        } }
    ] },
    TEST_JDBC: "jdbc:postgresql://db.example.com:5432/x?user=u&password=LEAK11",
''' + s[cut:]
open(p, "w", encoding="utf-8").write(s)
PY
  cat >> "$d/dmss-digital-stamping-service/application.yml" <<'YML'
test-fixture:
  private-key: |
    -----BEGIN PRIVATE KEY-----
    LEAKPEM1LEAKPEM1LEAKPEM1
    -----END PRIVATE KEY-----
  password: |
    LEAKBLOCK1
    LEAKBLOCK2
  after: visible
YML
  printf 'extra: |\n  -----BEGIN RSA PRIVATE KEY-----\n  LEAKPEM2\n' >> "$d/dmss-archive-services-fallback/application.yml"
}

fresh() {  # <name>: a throwaway deployment with a hostname, .env, secrets and data; prints its path
  local d="${work}/$1"
  copy_tree "$d"
  sed -i 's/padsign\.trustlynx\.com/padsign.example.com/g' "$d/nginx/nginx.conf" "$d/config/config.js" "$d/config/constants.json"
  printf 'KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD=supersecret1\n' > "$d/.env"
  fixtures "$d"
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
extract() {  # <archive> <dir>
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" 2>/dev/null
}

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
out="$(SUPPORT_BUNDLE_LOGS_TIMEOUT=abc bundle "$d")"; rc=$?
check "SUPPORT_BUNDLE_LOGS_TIMEOUT=abc: exit 2" test "$rc" = 2

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
check "... and no staging directory is left in the output directory" \
  bash -c '[[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -name ".*")" ]]' _ "${work}/out"

x="${work}/x"
extract "$path" "$x"
missing=""
for f in README.txt versions.txt compose-ps.txt monitor-status.txt validate-config.txt \
         config/config.js config/constants.json nginx/nginx.conf docker-compose.yml \
         dmss-digital-stamping-service/application.yml dmss-archive-services-fallback/application.yml \
         config/env-keys.txt logs/ps-server.log logs/nginx.log host.txt; do
  [[ -f "$x/$f" ]] || missing+="${f} "
done
if [[ -z "$missing" ]]; then
  ok_case "the archive holds every item (README, versions, compose-ps, both reports, config, env-keys, logs, host)"
else
  fail_case "the archive lacks: ${missing}" "$(cd "$x" && find . -type f | sort)"
fi
check "... and no log of the wizard, by service name or by image (setup-ui)" \
  bash -c '[[ ! -e "$1/logs/wizard.log" && ! -e "$1/logs/setup-ui.log" ]]' _ "$x"
check "... neither log was ever read" \
  bash -c '! grep -qE "compose logs .* (wizard|setup-ui)$" "$1"' _ "$STUB_LOG"
check "... logs asked for with --no-color --timestamps --since 24h" \
  grep -q -- '^docker compose logs --no-color --timestamps --since 24h ps-server$' "$STUB_LOG"

leaks="$(grep -rnE -e 'LEAK' -e 'abcdef123456' -e 'supersecret1' -e 'A{50}' -e 'WIZARD-TOKEN-MARKER' -e 'DO-NOT-SHIP-MARKER' "$x")"
if [[ -z "$leaks" ]]; then
  ok_case "no file holds a marker: config keys, webhook URLs and headers, JDBC and block-scalar passwords, PEM keys, log secrets, signer data, .env, documents"
else
  fail_case "secrets or documents reached the archive" "$leaks"
fi
check "config/env-keys.txt names KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD" grep -qx 'KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD' "$x/config/env-keys.txt"
check "logs/ps-server.log keeps its ordinary lines ('ready')" grep -q 'ready$' "$x/logs/ps-server.log"
check "... with the token and image elided in place" \
  bash -c 'grep -q "Authorization: <redacted>" "$1" && grep -q "data:image/png;base64,<base64 300 chars elided>" "$1"' _ "$x/logs/ps-server.log"
check "... the signing activity line reduced to its event and outcome" \
  grep -qF 'ps-server-1  | 2026-09-29T10:00:00.000000000Z <padsignAudit event=signature.visual outcome=ok omitted>' "$x/logs/ps-server.log"
check "... the deployment's own URLs keep their path, others keep their host" \
  bash -c 'grep -qF "https://padsign.example.com/archive/api/document/77" "$1" && grep -qF "https://hooks.example.com/<redacted>" "$1" \
    && grep -qF "http://dmss-archive-services:8090/api/document/1?token=<redacted>" "$1"' _ "$x/logs/ps-server.log"
check "config/config.js: REGISTER_PDF_API_KEY is <redacted>" grep -q 'REGISTER_PDF_API_KEY: "<redacted>"' "$x/config/config.js"
check "... own URLs keep their path; REGISTER_PDF_API_KEYS keep their company" \
  bash -c 'grep -qF "ARCHIVE_API_BASE_URL: \"https://padsign.example.com/archive/api/\"" "$1" && grep -qF "{ company: \"Amit\", key: \"<redacted>\" }" "$1"' _ "$x/config/config.js"
check "... same number of lines as the original (structure kept)" \
  test "$(wc -l < "$x/config/config.js")" = "$(wc -l < "$d/config/config.js")"
check "PEM keys: one <private key redacted> line; the YAML after them survives" \
  bash -c 'grep -q "<private key redacted>" "$1" && grep -q "^  after: visible" "$1" && grep -q "<private key redacted>" "$2"' _ \
  "$x/dmss-digital-stamping-service/application.yml" "$x/dmss-archive-services-fallback/application.yml"
check "README.txt says what is not included" \
  grep -qF "Not included: signed documents, the signing activity log, .env values, TLS private keys, the wizard's own log" "$x/README.txt"
check "README.txt says where host.txt's facts come from" grep -q 'host.txt describes the machine this script ran on' "$x/README.txt"
check "host.txt has the Docker host's operating system and kernel" grep -qF '{{.OperatingSystem}} {{.KernelVersion}}' "$x/host.txt"
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
  mkdir -m 755 "${work}/loose"
  out="$(bundle "$d" --output-dir "${work}/loose")"; rc=$?
  check "an existing output directory open to others: WARN, and the bundle is still written" \
    bash -c '[[ "$1" == 0 ]] && grep -q "^  WARN output directory: .* mode 755" <<< "$2" && [[ -f "$(tail -n 1 <<< "$2" | sed "s/^BUNDLE //")" ]]' _ "$rc" "$out"
else
  echo "  (file modes need Linux - skipped)"
fi

# ── two runs in one second ──────────────────────────────────────────────────
echo ""
echo "Two runs in the same second:"
first="$(last_line "$(STUB_DATE=2026-09-29T08:00:00Z bundle "$d" --output-dir "${work}/same")")"
second="$(last_line "$(STUB_DATE=2026-09-29T08:00:00Z bundle "$d" --output-dir "${work}/same")")"
check "the second archive gets -2, the first is kept" \
  bash -c '[[ "$1" == */padsign-support-padsign.example.com-20260929T080000Z.tar.gz && "$2" == */padsign-support-padsign.example.com-20260929T080000Z-2.tar.gz \
    && -f "${1#BUNDLE }" && -f "${2#BUNDLE }" ]]' _ "$first" "$second"

# ── timeouts and signals ────────────────────────────────────────────────────
echo ""
echo "A command that hangs:"
if command -v timeout >/dev/null 2>&1; then
  export STUB_SLOW_PID="${work}/slow.pid"
  started=$SECONDS
  out="$(STUB_SLOW_LOGS=1 SUPPORT_BUNDLE_LOGS_TIMEOUT=2 bundle "$d" --output-dir "${work}/slow")"; rc=$?
  took=$(( SECONDS - started ))
  check "exit 0, with a WARN per timed-out log" \
    bash -c '[[ "$1" == 0 ]] && grep -q "^  WARN logs/ps-server.log: timed out after 2s" <<< "$2" && grep -q "^  WARN logs/nginx.log: timed out after 2s" <<< "$2"' _ "$rc" "$out"
  check "... and the bundle is still written" bash -c '[[ -f "$(tail -n 1 <<< "$1" | sed "s/^BUNDLE //")" ]]' _ "$out"
  check "... without waiting for the stub (took ${took}s; each log sleeps 30s)" test "$took" -lt 50
  started=$SECONDS
  out="$(STUB_SLOW_LOGS=1 SUPPORT_BUNDLE_DEADLINE=4 bundle "$d" --output-dir "${work}/budget")"; rc=$?
  took=$(( SECONDS - started ))
  check "SUPPORT_BUNDLE_DEADLINE=4: later items are skipped (a WARN), exit 0, still a bundle (took ${took}s)" \
    bash -c '[[ "$1" == 0 && "$3" -lt 50 ]] && grep -q "^  WARN .*: skipped - the 4s time budget is used up" <<< "$2" \
      && [[ -f "$(tail -n 1 <<< "$2" | sed "s/^BUNDLE //")" ]]' _ "$rc" "$out" "$took"
else
  echo "  (no timeout command - skipped)"
fi

echo ""
echo "TERM while collecting:"
: > "$STUB_LOG"; rm -f "${work}/slow.pid"
export STUB_SLOW_PID="${work}/slow.pid"
( cd "$d" && STUB_SLOW_LOGS=1 exec bash installation-scripts/support-bundle.sh --output-dir "${work}/term" </dev/null >"${work}/term.out" 2>&1 ) &
bundle_pid=$!
for _ in $(seq 1 600); do [[ -s "${work}/slow.pid" ]] && break; sleep 0.2; done
stub_pid="$(cat "${work}/slow.pid" 2>/dev/null)"
kill -TERM "$bundle_pid" 2>/dev/null
wait "$bundle_pid"; rc=$?
check "exit 143 (TERM), with the stub's log call running (pid ${stub_pid:-none})" \
  bash -c '[[ "$1" == 143 && -n "$2" ]]' _ "$rc" "$stub_pid"
check "... no archive and no staging directory left" \
  bash -c '[[ -z "$(find "$1" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]' _ "${work}/term"
gone=false
for _ in $(seq 1 50); do kill -0 "$stub_pid" 2>/dev/null || { gone=true; break; }; sleep 0.2; done
check "... and the command it was waiting for was stopped too" test "$gone" = true

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
extract "${last#BUNDLE }" "$x"
check "... compose-ps.txt says the command failed" grep -q 'docker compose ps -a failed' "$x/compose-ps.txt"
check "... README.txt lists the warnings" grep -q '^Warnings while collecting:' "$x/README.txt"
check "... --since 2d reaches docker compose logs as 48h (docker takes no d unit)" \
  grep -q -- '^docker compose logs --no-color --timestamps --since 48h ps-server$' "$STUB_LOG"

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
exit $(( failed > 0 ))
