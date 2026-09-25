#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Regression tests for two script-robustness bugs (v1.0.43):
#
#  1. `producer | grep -q ...` under `set -o pipefail`. grep -q exits at its
#     first match; a producer that is still writing (docker compose logs,
#     docker compose ps, buildx, a large printf) then dies of SIGPIPE and the
#     pipeline is false although the match was found. verify-keycloak.sh
#     reported "FAIL ps-server does not appear to be running" for a healthy
#     ps-server, and bootstrap.sh printed a false WARNING.
#  2. `docker compose exec -T` drops the TTY but still forwards stdin, so
#     every kc_exec read the caller's stdin to EOF. bootstrap.sh run from a
#     `bash -s` heredoc (ssh host 'sudo bash -s' <<EOF, CI, curl | bash)
#     silently swallowed the rest of the calling script.
#
# Usage:
#   ./installation-scripts/tests/test-pipefail-and-stdin.sh
#
# Hermetic: runs on a throwaway copy of this checkout's tracked files (plus
# any uncommitted edits to them), with stub docker / curl / sleep first on
# PATH. Never talks to a docker daemon or the network. The stub
# `docker compose logs ps-server` prints the ps-server banner and then about
# 2 MB more, so an early-exiting reader SIGPIPEs it every time (case 1 checks
# that the stub still reproduces the bug). The stub `docker compose exec`
# reads its stdin to EOF, as the real one does (checked against Compose
# v2.38.2 on a real Linux engine).
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 perl git seq; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done

# The caller's environment must not steer the scripts under test.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME KEYCLOAK_ADMIN KEYCLOAK_ADMIN_PASSWORD

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="${work}/repo"
mkdir -p "$repo"
# Tracked files as they are on disk now (edits included, untracked excluded).
(cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
  | (cd "$src_root" && xargs -0 cp --parents -t "$repo" 2>/dev/null) || true

stub_bin="${work}/bin"
mkdir -p "$stub_bin"
export STUB_LOG="${work}/stub.log"
: > "$STUB_LOG"

cat > "${stub_bin}/docker" <<'STUB'
#!/usr/bin/env bash
# Stub docker for test-pipefail-and-stdin.sh. Answers just enough for
# bootstrap.sh, keycloak-bootstrap.sh and verify-keycloak.sh to run.
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
id='"11111111-2222-3333-4444-555555555555"'
if [[ "${1:-}" == compose ]]; then
  shift
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -p|-f|--project-name|--file|--profile|--project-directory|--env-file) shift 2 ;;
      *) shift ;;
    esac
  done
  sub="${1:-}"; shift || true
  case "$sub" in
    version) echo "Docker Compose version v2.40.0 (stub)" ;;
    config) [[ " $* " == *" --services "* ]] && printf '%s\n' keycloak dmss-archive-services \
              dmss-container-and-signature-services dmss-archive-services-fallback ps-server nginx ps-client ;;
    ps)
      if [[ " $* " == *" --services "* ]]; then printf '%s\n' keycloak ps-server nginx
      elif [[ " $* " == *" -q "* ]]; then echo "stubcid-${*: -1}"
      elif [[ "$*" == *'{{.State}}'* ]]; then echo running
      fi ;;
    logs)
      if [[ " $* " == *" ps-server "* ]]; then
        echo "ps-server  | PadSign Server listening on port 3001"
        # ~2 MB after the banner: far more than a pipe buffer, so a reader that
        # stops at the banner leaves this writer to die of SIGPIPE, every time.
        exec seq -f 'ps-server  | GET /api/latestUser 200 - request %g' 1 50000
      fi ;;
    exec)
      # Real `docker compose exec -T` forwards stdin although there is no TTY:
      # it reads the caller's stdin until EOF. Do exactly that.
      cat >/dev/null
      cmd="${*: -1}"
      case "$cmd" in
        *" create "*) : ;;
        *"username=test"*) : ;;
        *protocol-mappers/models*)
          printf '[ { "name" : "padsign-backend-audience", "config" : { "included.client.audience" : "padsign-backend" } }'
          [[ -n "${STUB_MAPPERS_PAD:-}" ]] && seq -f ', { "name" : "stub-mapper-%g", "config" : { } }' 1 40000
          printf ' ]\n' ;;
        *"--format csv"*) printf '%s\n' "$id" ;;
        *" get clients/"*) printf '{}\n' ;;
      esac ;;
  esac
  exit 0
fi
case "${1:-}" in
  run) [[ "$*" == *'id -u'* ]] && echo "0:0" ;;
  inspect)
    case "$*" in
      *'{{.State.Status}}'*) echo "running healthy 0" ;;
      *'{{.RestartCount}}'*) echo 0 ;;
      *'{{.Config.Image}}'*) echo "busybox:1.36" ;;
      *'{{.Image}}'*) printf 'sha256:%064d\n' 0 ;;
    esac ;;
  buildx)
    if [[ "$*" == *"imagetools inspect"* ]]; then
      printf 'Name:      docker.io/stub/image:1.0\nMediaType: application/vnd.oci.image.index.v1+json\n'
      printf 'Digest:    sha256:%064d\n\nManifests:\n' 7
      exec seq -f '  Name:      docker.io/stub/image:1.0@sha256:%064g' 1 50000
    fi ;;
  ps) echo "  stub-ps-server: busybox:1.36 (Up)" ;;
esac
exit 0
STUB

cat > "${stub_bin}/curl" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -ksI "*) printf 'HTTP/1.1 301 Moved Permanently\r\nLocation: /portal/\r\n\r\n' ;;
  *openid-configuration*) printf '{"issuer":"https://pf.example.test/auth/realms/padsign"}' ;;
  *) exit 7 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "${stub_bin}/sleep"
chmod +x "${stub_bin}/docker" "${stub_bin}/curl" "${stub_bin}/sleep"
export PATH="${stub_bin}:${PATH}"

# With no controlling terminal (as over ssh or in CI), print_secret()'s
# /dev/tty write fails quietly instead of showing a stub password here.
detach=()
if command -v setsid >/dev/null 2>&1 && setsid -w true </dev/null 2>/dev/null; then detach=(setsid -w); fi

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/       | /'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }  # <text> <fixed string>

echo "== SIGPIPE under pipefail =="

# 1. Control: the stub still reproduces the original false negative.
reproduced=0
for _ in 1 2 3 4 5; do
  if ( set -o pipefail; docker compose logs ps-server 2>/dev/null | grep -q "PadSign Server listening" ); then :; else
    reproduced=$((reproduced + 1))
  fi
done
if [[ "$reproduced" -eq 5 ]]; then
  ok_case "control: 'docker compose logs ps-server | grep -q' under pipefail is false 5/5 against the stub (the bug)"
else
  fail_case "control: the stub reproduced the bug only ${reproduced}/5 times, so the cases below prove nothing"
fi

# 2. verify-keycloak.sh, the script that reported the running server as down.
vk_ok=0
vk_last=""
for _ in $(seq 1 10); do
  vk_last="$(cd "$repo" && KEYCLOAK_ADMIN_PASSWORD=stub-admin-pass ./installation-scripts/verify-keycloak.sh \
    --host pf.example.test --company-role Acme </dev/null 2>&1 || true)"
  if grep -qx 'OK   ps-server is running' <<< "$vk_last"; then vk_ok=$((vk_ok + 1)); fi
done
if [[ "$vk_ok" -eq 10 ]]; then
  ok_case "verify-keycloak.sh: 'OK ps-server is running' 10/10 with ~2 MB of ps-server log after the banner"
else
  fail_case "verify-keycloak.sh: ps-server reported running only ${vk_ok}/10 times" "$vk_last"
fi

# 3. kc_backend_audience_present with a mapper list far larger than a pipe
#    buffer, the audience mapper first (printf | tr | grep -q SIGPIPEd).
aud_out="$( (
  repo_root="$repo"
  . "${repo}/installation-scripts/lib/kcadm.sh"
  if STUB_MAPPERS_PAD=1 kc_backend_audience_present padsign stub-cid padsign-backend </dev/null; then echo "rc=0"; else echo "rc=$?"; fi
) 2>&1 )"
if [[ "$aud_out" == "rc=0" ]]; then
  ok_case "kc_backend_audience_present: finds the audience mapper in a ~2 MB mapper list"
else
  fail_case "kc_backend_audience_present: audience mapper reported absent (${aud_out})"
fi

# 4. digest_live with a manifest list far larger than a pipe buffer (awk exit
#    SIGPIPEd buildx, and set -e then aborted upgrade.sh's pre-flight).
dl_out="$( (
  repo_root="$repo"
  . "${repo}/installation-scripts/lib/digests.sh"
  if d="$(digest_live stub/image 1.0)"; then echo "rc=0 ${d}"; else echo "rc=$?"; fi
) 2>&1 )"
want_digest="$(printf 'sha256:%064d' 7)"
if [[ "$dl_out" == "rc=0 ${want_digest}" ]]; then
  ok_case "digest_live: returns the digest (exit 0) ahead of a ~2 MB manifest list"
else
  fail_case "digest_live: expected 'rc=0 ${want_digest}', got '${dl_out}'"
fi

# 5. Lint: no docker/curl producer piped straight into grep -q in the scripts.
lint_grep="$(cd "${repo}/installation-scripts" \
  && grep -nE '\b(docker|curl)\b[^#]*\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q' ./*.sh lib/*.sh \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$lint_grep" ]]; then
  ok_case "lint: no 'docker ... | grep -q' / 'curl ... | grep -q' in installation-scripts/ or lib/"
else
  fail_case "lint: early-exit grep -q on a docker/curl pipe (use grep -q ... < <(producer))" "$lint_grep"
fi

echo ""
echo "== caller's stdin =="

# 6. Lint: every `exec -T` gets </dev/null, or a pipe it is meant to read.
lint_exec="$(cd "${repo}/installation-scripts" \
  && grep -nE 'exec -T' ./*.sh lib/*.sh \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|\|)' | grep -v '</dev/null' || true)"
if [[ -z "$lint_exec" ]]; then
  ok_case "lint: every 'docker compose exec -T' reads </dev/null or an explicit pipe"
else
  fail_case "lint: 'docker compose exec -T' without </dev/null reads the caller's stdin" "$lint_exec"
fi

# 7. kc_exec in a `bash -s` heredoc.
out="$(bash -s <<EOF 2>&1
. "${repo}/installation-scripts/lib/kcadm.sh"
kc_exec true
echo "AFTER-KC-EXEC"
EOF
)" || true  # a swallowed heredoc exits with the eater's status
if has "$out" "AFTER-KC-EXEC"; then
  ok_case "kc_exec leaves a bash -s heredoc's remaining lines alone"
else
  fail_case "kc_exec swallowed the rest of the calling heredoc" "$out"
fi

# 8. keycloak-bootstrap.sh (every kcadm call is a kc_exec) in a heredoc.
: > "$STUB_LOG"
out="$(cd "$repo" && ${detach[@]+"${detach[@]}"} bash -s <<'EOF' 2>&1
KEYCLOAK_ADMIN_PASSWORD='PfStubAdmin-7Qm2Vx9Lr4Kp' ./installation-scripts/keycloak-bootstrap.sh \
  --host pf.example.test --company-role "Acme Corp" \
  --users "alice:Al1ce-Stub-Pass:padsign-admin,bob:B0b-Stub-Pass:psapp-integration"
echo "keycloak-bootstrap-rc=$?"
echo "AFTER-KEYCLOAK-BOOTSTRAP"
EOF
)" || true  # a swallowed heredoc exits with the eater's status
if has "$out" "keycloak-bootstrap-rc=0" && has "$out" "AFTER-KEYCLOAK-BOOTSTRAP" && has "$out" "BACKEND_CLIENT_SECRET="; then
  ok_case "keycloak-bootstrap.sh from a bash -s heredoc: exit 0, and the lines after it still run"
else
  fail_case "keycloak-bootstrap.sh from a bash -s heredoc: lines after it did not run (or it failed)" "$out"
fi
# The --users loop reads NUL-separated entries on its stdin. Fed through
# <<< "$(...)" the NULs were dropped and every entry merged into the first;
# fed through a pipe, a kc_exec inside the loop would eat the rest.
if grep -q "create users -r padsign -s username='bob'" "$STUB_LOG"; then
  ok_case "keycloak-bootstrap.sh --users: the second entry is processed too"
else
  fail_case "keycloak-bootstrap.sh --users: only the first entry was processed" \
    "$(grep -o "username='[a-z]*'\|rolename '[^']*'" "$STUB_LOG" | sort | uniq -c)"
fi
# A --users password reaches Keycloak only as stdin JSON (kc_set_password),
# never a command line; the merged entry put bob's into a role name.
if ! grep -qF -e "Al1ce-Stub-Pass" -e "B0b-Stub-Pass" "$STUB_LOG"; then
  ok_case "keycloak-bootstrap.sh --users: no user password on any docker command line"
else
  fail_case "keycloak-bootstrap.sh --users: a user password reached a docker command line" \
    "$(grep -F -e "Al1ce-Stub-Pass" -e "B0b-Stub-Pass" "$STUB_LOG")"
fi

# 9. verify-keycloak.sh in a heredoc (postdeploy-check.sh runs it).
out="$(cd "$repo" && bash -s <<'EOF' 2>&1
KEYCLOAK_ADMIN_PASSWORD=stub-admin-pass ./installation-scripts/verify-keycloak.sh --host pf.example.test --company-role Acme >/dev/null 2>&1
echo "AFTER-VERIFY-KEYCLOAK"
EOF
)" || true  # a swallowed heredoc exits with the eater's status
if has "$out" "AFTER-VERIFY-KEYCLOAK"; then
  ok_case "verify-keycloak.sh from a bash -s heredoc: the lines after it still run"
else
  fail_case "verify-keycloak.sh swallowed the rest of the calling heredoc" "$out"
fi

# 10. The reported case end to end: bootstrap.sh in `bash -s <<EOF`, then more
#     commands. Also checks step 8's ps-server log check against long logs.
#     Skipped under Git Bash: a native Windows python3 cannot open
#     the POSIX paths deployment-evidence.sh hands it through the environment.
if command -v cygpath >/dev/null 2>&1; then
  printf '  SKIP bootstrap.sh end to end (needs a POSIX python3; run on Linux)\n'
else
  out="$(cd "$repo" && ${detach[@]+"${detach[@]}"} bash -s <<'EOF' 2>&1
KEYCLOAK_ADMIN_PASSWORD='PfStubAdmin-7Qm2Vx9Lr4Kp' ./installation-scripts/bootstrap.sh \
  --host pf.example.test --company-role "Acme Corp"
echo "bootstrap-rc=$?"
echo "AFTER-BOOTSTRAP"
EOF
)" || true  # a swallowed heredoc exits with the eater's status
  if has "$out" "bootstrap-rc=0" && has "$out" "AFTER-BOOTSTRAP" && has "$out" "Bootstrap complete!"; then
    ok_case "bootstrap.sh from a bash -s heredoc: exit 0, and the lines after it still run"
  else
    fail_case "bootstrap.sh from a bash -s heredoc: lines after it did not run (or it failed)" "$out"
  fi
  if has "$out" "  ps-server: OK" && ! has "$out" "WARNING: ps-server may not have started"; then
    ok_case "bootstrap.sh step 8: 'ps-server: OK' with ~2 MB of ps-server log after the banner"
  else
    fail_case "bootstrap.sh step 8: ps-server check did not pass against long logs" "$out"
  fi
fi

echo ""
echo "${pass} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
