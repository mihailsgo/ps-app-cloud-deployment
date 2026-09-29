#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign support bundle: one archive holding what TrustLynx support asks for
# when a problem is not in the troubleshooting table
# (documentation/12-troubleshooting.md).
#
#   ./installation-scripts/support-bundle.sh [--since 24h] [--output-dir DIR] [--host example.com]
#
# Writes <output-dir>/padsign-support-<host>-<UTC time>.tar.gz (mode 600, in a
# directory created mode 700; a second run in the same second gets -2, -3...)
# containing:
#
#   README.txt                what was collected, when, and what was not
#   versions.txt              git describe, docker compose images, the image: pins
#   compose-ps.txt            docker compose ps -a
#   monitor-status.txt        monitor-status.sh (read-only report mode)
#   validate-config.txt       validate-config.sh (its FAILs are content, not errors)
#   deployment-evidence.json  when present, without config_checksums: next to
#                             the redacted files, their sha256 would confirm
#                             a guessed secret offline
#   config/config.js, config/constants.json, nginx/nginx.conf,
#   docker-compose.yml, dmss-*/application.yml
#                             at their paths in the checkout, through
#                             lib/redact.py --filter: secret values, headers,
#                             PEM keys and URL paths outside the deployment's
#                             own host replaced by <redacted>
#   config/env-keys.txt       the variable NAMES in .env, never a value
#   logs/<service>.log        docker compose logs --since <window> of every
#                             service except the wizard, through
#                             lib/redact.py --filter --log (tokens, JWTs,
#                             base64 images and documents, signer data removed)
#   host.txt                  uname, df, the Docker server version, storage and OS
#
# Never included: signed documents (signed-output/, docs/), the signing
# activity log (signed-output/.padsign-audit/), .env values, TLS private keys,
# and the wizard's own log (any service named wizard or running a
# padsign-wizard image), which prints the wizard's access token. The script
# reads none of those paths.
#
# The output is a contract: the Deployment Wizard runs this script and parses
# it. One "  OK   <item>" or "  WARN <item>: <reason>" line per item (the
# format of validate-config.sh's ok()/warn()), a blank line, and as the very
# last stdout line "BUNDLE <absolute path of the archive>". A collector that
# fails (Docker down, a script missing, a timeout) is a WARN and a note in
# its file; it never stops the bundle.
#
# Time limits (seconds, environment variables, defaults in brackets). Each
# command is stopped (timeout -k 10) after its own limit, and none starts
# past the run's shared budget, so the run ends within about budget + 10 s
# plus the final archiving - inside the wizard's 600 s even with Docker hung:
#   SUPPORT_BUNDLE_CMD_TIMEOUT [60]     each docker compose ps/images/config,
#                                       docker version/info
#   SUPPORT_BUNDLE_LOGS_TIMEOUT [60]    each service's docker compose logs
#   SUPPORT_BUNDLE_REPORT_TIMEOUT [180] monitor-status.sh, validate-config.sh
#   SUPPORT_BUNDLE_REDACT_TIMEOUT [120] each lib/redact.py run (at least 15 s,
#                                       even past the budget, so a stuck
#                                       filter is a WARN, not a hang)
#   SUPPORT_BUNDLE_DEADLINE [480]       the whole run; an item that would
#                                       start after it is skipped (a WARN)
# Without a `timeout` command the limits are not enforced.
#
# INT, TERM or HUP stop the command being waited for, remove the staging
# directory and any half-written archive, and exit 130/143/129.
#
# Exit codes: 0 bundle written (items may WARN), 1 the archive could not be
# written, 2 usage error, or python3 / tar missing.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

since="24h"
output_dir=""
host=""
cmd_timeout="${SUPPORT_BUNDLE_CMD_TIMEOUT:-60}"
logs_timeout="${SUPPORT_BUNDLE_LOGS_TIMEOUT:-60}"
report_timeout="${SUPPORT_BUNDLE_REPORT_TIMEOUT:-180}"
redact_timeout="${SUPPORT_BUNDLE_REDACT_TIMEOUT:-120}"
time_budget="${SUPPORT_BUNDLE_DEADLINE:-480}"
kill_grace=10

usage() {
  cat <<'EOF'
Usage: ./installation-scripts/support-bundle.sh [--since 24h] [--output-dir DIR] [--host example.com]

Writes one archive for TrustLynx support: configuration with secret values
replaced by <redacted>, service logs with tokens, embedded images and signer
data removed, image versions, container state and the monitor-status.sh and
validate-config.sh reports. Signed documents, the signing activity log, .env
values, TLS private keys and the wizard's own log are never included.
See documentation/12-troubleshooting.md.

  --since       log window passed to docker compose logs: N[smhd] or RFC3339
                (default 24h)
  --output-dir  default <repo>/support-bundles (created mode 700); the
                archive itself is mode 600
  --host        default: server_name from nginx/nginx.conf. URLs on this
                host keep their path in the bundle; others keep only the host.

Time limits in seconds (environment): SUPPORT_BUNDLE_CMD_TIMEOUT [60],
SUPPORT_BUNDLE_LOGS_TIMEOUT [60] per service, SUPPORT_BUNDLE_REPORT_TIMEOUT
[180] per report script, SUPPORT_BUNDLE_REDACT_TIMEOUT [120] per redaction,
SUPPORT_BUNDLE_DEADLINE [480] for the whole run.

Prints one "  OK   <item>" or "  WARN <item>: <reason>" line per item and,
as the last line, "BUNDLE <path of the archive>".

Exit: 0 bundle written (items may WARN), 1 archive could not be written,
      2 usage / missing python3 or tar
EOF
}

usage_error() {
  echo "ERROR: $1" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since|--output-dir|--host)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "$1 needs a value"
      case "$1" in
        --since) since="$2" ;;
        --output-dir) output_dir="$2" ;;
        --host) host="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done

check_seconds() {  # <variable name> <value>
  [[ "$2" =~ ^[1-9][0-9]{0,4}$ ]] || usage_error "$1 must be a number of seconds (1-99999), not '$2'"
}
check_seconds SUPPORT_BUNDLE_CMD_TIMEOUT "$cmd_timeout"
check_seconds SUPPORT_BUNDLE_LOGS_TIMEOUT "$logs_timeout"
check_seconds SUPPORT_BUNDLE_REPORT_TIMEOUT "$report_timeout"
check_seconds SUPPORT_BUNDLE_DEADLINE "$time_budget"
check_seconds SUPPORT_BUNDLE_REDACT_TIMEOUT "$redact_timeout"

if [[ -n "$host" && ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  usage_error "--host '${host}' is not a hostname"
fi

# docker's --since takes a Go duration (s, m, h - no d) or a timestamp.
rfc3339_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}(Z|[+-][0-9:]{5})?$'
if [[ "$since" =~ ^([0-9]+)d$ ]]; then
  since_arg="$(( 10#${BASH_REMATCH[1]} * 24 ))h"
elif [[ "$since" =~ ^[0-9]+[smh]$ || "$since" =~ $rfc3339_re ]]; then
  since_arg="$since"
else
  usage_error "--since '${since}' is neither N[smhd] (24h, 7d) nor an RFC3339 time (2026-09-29T08:00:00Z)"
fi

for c in python3 tar; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "ERROR: ${c} is required to write a support bundle. Install it, or collect the reports and logs by hand (documentation/12-troubleshooting.md)." >&2
    exit 2
  fi
done

# docker compose resolves the project (and .env: COMPOSE_FILE, COMPOSE_PROFILES)
# from the working directory, and every path below is relative to the checkout.
cd "$repo_root"
redact_py="installation-scripts/lib/redact.py"

if [[ -z "$host" && -r nginx/nginx.conf ]]; then
  host="$(awk '$1 == "server_name" { gsub(/[;\r]/, "", $2); print $2; exit }' nginx/nginx.conf 2>/dev/null || true)"
fi
safe_host="$(printf '%s' "$host" | LC_ALL=C tr -cd 'A-Za-z0-9.-')"
[[ -n "$safe_host" ]] || safe_host="unknown"
# The deployment's own URLs keep their path in the bundle (lib/redact.py).
keep_args=()
host_args=()
if [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
  keep_args=(--keep-host "$host")
  host_args=(--host "$host")
fi

# Everything this script creates is owner-only: the bundle holds this
# deployment's configuration and logs.
umask 077
[[ -n "$output_dir" ]] || output_dir="${repo_root}/support-bundles"
dir_warning=""
if [[ -d "$output_dir" ]]; then
  dir_mode="$(stat -c %a "$output_dir" 2>/dev/null || stat -f %Lp "$output_dir" 2>/dev/null || true)"
  if [[ "$dir_mode" =~ ^[0-7]+$ ]] && (( 8#$dir_mode & 8#077 )); then
    dir_warning="output directory: ${output_dir} is mode ${dir_mode} - other users can see the bundles in it; chmod 700 it"
  fi
elif ! mkdir -p -m 700 "$output_dir" 2>/dev/null; then
  echo "ERROR: cannot create the output directory ${output_dir}. Pass --output-dir, or run as a user who may write there." >&2
  exit 1
fi
if [[ ! -w "$output_dir" ]]; then
  echo "ERROR: cannot write the output directory ${output_dir}. Pass --output-dir, or run as a user who may write there." >&2
  exit 1
fi
output_dir="$(cd "$output_dir" && pwd)"

# Staging on the output directory's filesystem, owner-only (mktemp -d is
# 700): bundle/ becomes the archive, raw/ holds each command's unredacted
# output until lib/redact.py has filtered it.
# A run stopped by SIGKILL leaves its staging directory, unredacted output
# included: remove any older than an hour (a younger one may be a run in
# progress).
find "$output_dir" -mindepth 1 -maxdepth 1 -type d -name '.support-bundle.*' -mmin +60 \
  -exec rm -rf {} + 2>/dev/null || true
if ! work="$(mktemp -d "${output_dir}/.support-bundle.XXXXXX" 2>/dev/null)"; then
  echo "ERROR: cannot create a staging directory in ${output_dir}." >&2
  exit 1
fi
staging="${work}/bundle"
raw="${work}/raw"
mkdir "$staging" "$raw"

# â”€â”€ Stopping cleanly â”€â”€
child=""          # the command run_capped is waiting for
archive=""
archive_done=""
stop_child() {
  [[ -n "$child" ]] || return 0
  # Its children first (a report function's timeout), then the command:
  # `timeout` leads its own process group, so -PID reaches what runs under it.
  pkill -TERM -P "$child" 2>/dev/null || true
  kill -TERM -- "-${child}" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
  child=""
}
cleanup() {
  stop_child
  rm -rf "$work"
  if [[ -n "$archive" && -z "$archive_done" ]]; then rm -f "$archive"; fi
}
on_signal() {
  trap - EXIT INT TERM HUP
  cleanup
  echo "ERROR: interrupted - no bundle written" >&2
  exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

# â”€â”€ Time limits â”€â”€
printf -v run_started '%(%s)T' -1
deadline=$(( run_started + time_budget ))
have_timeout=false
command -v timeout >/dev/null 2>&1 && have_timeout=true

time_left() {  # <cap>: sets limit = min(cap, seconds left in the budget), at least 0
  local now
  printf -v now '%(%s)T' -1
  limit=$(( deadline - now ))
  (( limit > $1 )) && limit="$1"
  (( limit > 0 )) || limit=0
}

# run_capped <cap> <file> <command...>
#   Runs <command> in the background with stdin from /dev/null and stdout +
#   stderr to <file>, and waits for it (a wait a signal interrupts, unlike a
#   foreground command). Stopped after min(<cap>, time left) seconds. Sets
#   cmd_rc to its exit status, "timeout" or "skipped", and cmd_limit.
#   A shell function runs without `timeout` (it cannot run one); the report
#   functions below cap each of their own commands instead.
run_capped() {
  local cap="$1" file="$2"
  local -a wrap=()
  shift 2
  time_left "$cap"
  cmd_limit="$limit"
  if (( cmd_limit < 1 )); then
    : > "$file"
    cmd_rc=skipped
    return 0
  fi
  if [[ "$have_timeout" == true ]] && ! declare -F "$1" >/dev/null; then
    wrap=(timeout -k "$kill_grace" "$cmd_limit")
  fi
  ${wrap[@]+"${wrap[@]}"} "$@" </dev/null >"$file" 2>&1 &
  child=$!
  cmd_rc=0
  wait "$child" || cmd_rc=$?
  child=""
  if [[ "${#wrap[@]}" -gt 0 && ( "$cmd_rc" == 124 || "$cmd_rc" == 137 ) ]]; then
    cmd_rc=timeout
  fi
}

# capped <cap> <command...>: <command> in the foreground under the same
# limits, for the report functions (run in the background by run_capped).
capped() {
  local cap="$1"
  shift
  time_left "$cap"
  if (( limit < 1 )); then
    echo "(skipped: the ${time_budget}s time budget is used up)"
    return 125
  fi
  if [[ "$have_timeout" == true ]]; then
    timeout -k "$kill_grace" "$limit" "$@"
  else
    "$@"
  fi
}

created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp="${created//[-:]/}"   # 20260929T080000Z, the same second

collected=()   # archive paths, in collection order, for README.txt
warn_lines=()
ok()   { printf '  OK   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; warn_lines+=("$*"); }

# redact_file <config|log> <raw file> <archive file>: lib/redact.py --filter,
# then the raw copy is removed. Returns 1 (and keeps no half-filtered file)
# when redact.py fails.
#   Runs under `timeout` too (SUPPORT_BUNDLE_REDACT_TIMEOUT, at least 15 s
#   or that value if smaller, even past the budget: a stuck filter is a
#   WARN, never a hang). Sets redact_rc ("timeout" or the exit status).
redact_file() {
  local -a args=(--filter) wrap=()
  [[ "$1" == log ]] && args+=(--log)
  time_left "$redact_timeout"
  local floor=$(( redact_timeout < 15 ? redact_timeout : 15 ))
  (( limit >= floor )) || limit="$floor"
  redact_limit="$limit"
  if [[ "$have_timeout" == true ]]; then wrap=(timeout -k "$kill_grace" "$limit"); fi
  ${wrap[@]+"${wrap[@]}"} python3 "$redact_py" "${args[@]}" ${keep_args[@]+"${keep_args[@]}"} < "$2" > "$3" 2>/dev/null &
  child=$!
  redact_rc=0
  wait "$child" || redact_rc=$?
  child=""
  rm -f "$2"
  [[ "$redact_rc" == 0 ]] && return 0
  if [[ "${#wrap[@]}" -gt 0 && ( "$redact_rc" == 124 || "$redact_rc" == 137 ) ]]; then redact_rc=timeout; fi
  rm -f "$3"
  return 1
}
redact_failed() {  # <archive path>: the WARN for a redact_file failure
  if [[ "$redact_rc" == timeout ]]; then
    warn "${1}: lib/redact.py timed out after ${redact_limit}s - left out"
  else
    warn "${1}: lib/redact.py could not filter it (exit ${redact_rc}) - left out"
  fi
}

# collect <archive path> <config|log> <cap> <what> <command...>
#   run_capped, then redact_file into the staging copy of <archive path>,
#   then one OK or WARN line. A failed, timed-out or skipped command leaves
#   what it printed in the file, plus a note saying so. With rc1_ok=true, an
#   exit status of 1 is a report's verdict (validate-config.sh), not a failure.
collect() {
  local path="$1" mode="$2" cap="$3" what="$4" out
  shift 4
  out="${staging}/${path}"
  mkdir -p "$(dirname "$out")"
  run_capped "$cap" "${raw}/current" "$@"
  if ! redact_file "$mode" "${raw}/current" "$out"; then
    redact_failed "$path"
    return 0
  fi
  collected+=("$path")
  case "$cmd_rc" in
    0) ok "$path" ;;
    1) if [[ "${rc1_ok:-}" == true ]]; then ok "${path} (some checks FAILED - see the file)"; return 0; fi
       printf '\n[support-bundle.sh] %s failed (exit 1); the lines above are all it printed.\n' "$what" >> "$out"
       warn "${path}: ${what} failed (exit 1)" ;;
    timeout)
      printf '\n[support-bundle.sh] %s timed out after %ss; the lines above are what it printed until then.\n' "$what" "$cmd_limit" >> "$out"
      warn "${path}: timed out after ${cmd_limit}s" ;;
    skipped)
      printf '[support-bundle.sh] %s was skipped: the %ss time budget was used up.\n' "$what" "$time_budget" >> "$out"
      warn "${path}: skipped - the ${time_budget}s time budget is used up" ;;
    *)
      printf '\n[support-bundle.sh] %s failed (exit %s); the lines above are all it printed.\n' "$what" "$cmd_rc" >> "$out"
      warn "${path}: ${what} failed (exit ${cmd_rc})" ;;
  esac
}

versions_report() {
  local rc=0
  echo "== git describe --always --dirty --tags =="
  if [[ -e .git ]] && command -v git >/dev/null 2>&1; then
    git describe --always --dirty --tags 2>&1 || echo "(git describe failed)"
  else
    echo "(not a git checkout)"
  fi
  echo ""
  echo "== docker compose images =="
  capped "$cmd_timeout" docker compose images 2>&1 || { rc=$?; echo "(docker compose images failed, exit ${rc})"; }
  echo ""
  echo "== image: lines of docker-compose.yml =="
  grep -nE '^[[:space:]]*image:' docker-compose.yml 2>&1 || echo "(none found)"
  return "$rc"
}

host_report() {
  local rc=0 r
  echo "== uname -a =="
  uname -a 2>&1 || echo "(uname failed)"
  echo ""
  echo "== df -P ${repo_root} =="
  df -P "$repo_root" 2>&1 || echo "(df failed)"
  echo ""
  echo "== docker version (server) =="
  capped "$cmd_timeout" docker version --format '{{.Server.Version}}' 2>&1 || { rc=$?; echo "(docker version failed, exit ${rc})"; }
  echo ""
  echo "== docker info: storage driver, root dir =="
  capped "$cmd_timeout" docker info --format '{{.Driver}} {{.DockerRootDir}}' 2>&1 || { rc=$?; echo "(docker info failed, exit ${rc})"; }
  echo ""
  echo "== docker info: the Docker host's operating system, kernel =="
  capped "$cmd_timeout" docker info --format '{{.OperatingSystem}} {{.KernelVersion}}' 2>&1 || { r=$?; rc=$r; echo "(docker info failed, exit ${r})"; }
  return "$rc"
}

# Service names from the effective compose model, leaving out the wizard by
# name and by image (a renamed copy of the wizard service prints the same
# access token).
list_services_py='
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
try:
    model, _ = json.JSONDecoder().raw_decode(text[text.index("{"):])
    services = model.get("services") or {}
except (ValueError, AttributeError):
    sys.exit(1)
for name, svc in services.items():
    image = str((svc or {}).get("image") or "")
    if name != "wizard" and "padsign-wizard" not in image:
        print(name)
'

user_name="$(id -un 2>/dev/null || id -u)"

echo "PadSign support bundle"
echo "================================"
echo "Host:    ${host:-<unknown, pass --host>}"
echo "Logs:    since ${since}"
echo "Output:  ${output_dir}"
echo ""
if [[ -n "$dir_warning" ]]; then warn "$dir_warning"; fi

# Configuration, at its path in the checkout. The first four always exist on
# a deployment; the DMSS files are copied when present.
for f in config/config.js config/constants.json nginx/nginx.conf docker-compose.yml \
         dmss-archive-services/application.yml dmss-archive-services-fallback/application.yml \
         dmss-container-and-signature-services/application.yml dmss-digital-stamping-service/application.yml; do
  if [[ ! -e "$f" ]]; then
    case "$f" in
      config/*|nginx/*|docker-compose.yml) warn "${f}: missing from ${repo_root}" ;;
    esac
    continue
  fi
  if [[ ! -r "$f" ]]; then
    warn "${f}: not readable by ${user_name} - run as root, or as a member of its group, to include it"
    continue
  fi
  collect "$f" config "$cmd_timeout" "reading ${f}" cat "$f"
done

if [[ -f .env ]]; then
  mkdir -p "${staging}/config"
  if [[ -r .env ]] && sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' .env > "${staging}/config/env-keys.txt"; then
    collected+=(config/env-keys.txt)
    ok "config/env-keys.txt (variable names only)"
  else
    rm -f "${staging}/config/env-keys.txt"
    warn "config/env-keys.txt: .env is not readable by ${user_name}"
  fi
fi

# config_checksums are sha256 of the very files bundled redacted: with them,
# a guessed password could be confirmed offline. Everything else stays.
strip_checksums_py='
import json, sys
evidence = json.load(open(sys.argv[1], encoding="utf-8"))
if isinstance(evidence, dict):
    evidence.pop("config_checksums", None)
json.dump(evidence, sys.stdout, indent=2)
print()
'
if [[ -f deployment-evidence.json ]]; then
  collect deployment-evidence.json config "$cmd_timeout" "reading deployment-evidence.json" \
    python3 -c "$strip_checksums_py" deployment-evidence.json
fi

collect compose-ps.txt log "$cmd_timeout" "docker compose ps -a" docker compose ps -a
collect versions.txt log "$cmd_timeout" "docker compose images" versions_report

# Logs of every service the current profiles enable, never the wizard's.
services=()
services_ok=false
run_capped "$cmd_timeout" "${raw}/compose-model" docker compose config --format json
if [[ "$cmd_rc" == 0 ]] && python3 -c "$list_services_py" "${raw}/compose-model" > "${raw}/services" 2>/dev/null; then
  services_ok=true
else
  # Older Compose without --format json: by name only.
  run_capped "$cmd_timeout" "${raw}/services-all" docker compose config --services
  if [[ "$cmd_rc" == 0 ]]; then
    grep -vx 'wizard' "${raw}/services-all" > "${raw}/services" || true
    services_ok=true
  fi
fi
if [[ "$services_ok" == true ]]; then
  while IFS= read -r svc; do
    svc="${svc%$'\r'}"
    [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && services+=("$svc")
  done < "${raw}/services"
  if [[ "${#services[@]}" -eq 0 ]]; then
    warn "logs/: docker compose config listed no services"
  fi
else
  warn "logs/: docker compose config failed - no service logs collected (is Docker running, and docker-compose.yml valid?)"
fi
rm -f "${raw}/compose-model" "${raw}/services" "${raw}/services-all"
for svc in ${services[@]+"${services[@]}"}; do
  collect "logs/${svc}.log" log "$logs_timeout" "docker compose logs ${svc}" \
    docker compose logs --no-color --timestamps --since "$since_arg" "$svc"
done

collect host.txt log "$cmd_timeout" "docker version / docker info" host_report
collect monitor-status.txt log "$report_timeout" "monitor-status.sh" \
  bash installation-scripts/monitor-status.sh ${host_args[@]+"${host_args[@]}"}
# validate-config.sh exits 1 when a check FAILs: that is its report.
rc1_ok=true collect validate-config.txt log "$report_timeout" "validate-config.sh" \
  bash installation-scripts/validate-config.sh ${host_args[@]+"${host_args[@]}"}

{
  echo "PadSign support bundle"
  echo "======================"
  echo "Created:     ${created} (UTC)"
  echo "Host:        ${host:-unknown}"
  echo "Log window:  since ${since} (docker compose logs --since ${since_arg})"
  echo "Checkout:    ${repo_root}"
  echo "Written by:  installation-scripts/support-bundle.sh"
  echo ""
  echo "Contents:"
  echo "  README.txt"
  for p in ${collected[@]+"${collected[@]}"}; do echo "  ${p}"; done
  echo ""
  echo "Every file except this one went through installation-scripts/lib/redact.py:"
  echo "secret-named values, header values and PEM private keys are <redacted>;"
  echo "URLs keep their path only on this deployment's own host and inside the"
  echo "stack. In logs and reports, bearer tokens and JWTs are removed, base64 or"
  echo "other token runs of 200+ characters (drawn signatures, documents) are"
  echo "elided, and signing activity lines keep only their event and outcome."
  echo "config/env-keys.txt lists the names in .env, not the values. Logs can"
  echo "still hold personal data of the people who sign (names, e-mail"
  echo "addresses): share this bundle with TrustLynx support only."
  echo ""
  echo "redaction is best effort; read the bundle before sending it. It does not"
  echo "recognise a secret in prose without a ':' or '=' (\"the password is x\"),"
  echo "Map-style dumps, URLs without a scheme or URL-encoded, or ws:// URLs."
  echo "deployment-evidence.json, when present, has no config_checksums (the"
  echo "sha256 of the files above would let a guessed secret be confirmed)."
  echo ""
  echo "host.txt describes the machine this script ran on: run from the"
  echo "Deployment Wizard, that is the wizard's container, not the host. Its"
  echo "docker lines describe the Docker engine the stack runs on either way."
  echo ""
  echo "Not included: signed documents, the signing activity log, .env values, TLS private keys, the wizard's own log"
  if [[ "${#warn_lines[@]}" -gt 0 ]]; then
    echo ""
    echo "Warnings while collecting:"
    for w in "${warn_lines[@]}"; do echo "  ${w}"; done
  fi
} > "${staging}/README.txt"
ok "README.txt"

# Claim a name no other run has taken (noclobber creates it atomically).
base="${output_dir}/padsign-support-${safe_host}-${stamp}"
candidate="${base}.tar.gz"
n=2
until ( set -o noclobber; : > "$candidate" ) 2>/dev/null; do
  if (( n > 999 )); then
    echo "ERROR: could not create an archive named ${base}*.tar.gz" >&2
    exit 1
  fi
  candidate="${base}-${n}.tar.gz"
  n=$((n + 1))
done
archive="$candidate"
if ! tar -czf "$archive" -C "$staging" . ; then
  echo "ERROR: could not write ${archive}" >&2
  exit 1
fi
if ! chmod 600 "$archive"; then
  echo "ERROR: could not make ${archive} owner-only (chmod 600) - remove it, or restrict it by hand before sending it" >&2
  exit 1
fi
archive_done=1

echo ""
echo "Wrote ${archive} ($(( ${#collected[@]} + 1 )) files, ${#warn_lines[@]} warning(s), mode 600)."
echo "Send it to TrustLynx support; README.txt inside lists what it holds."
echo "BUNDLE ${archive}"
