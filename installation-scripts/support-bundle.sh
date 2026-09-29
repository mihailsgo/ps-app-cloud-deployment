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
# directory created mode 700) containing:
#
#   README.txt                what was collected, when, and what was not
#   versions.txt              git describe, docker compose images, the image: pins
#   compose-ps.txt            docker compose ps -a
#   monitor-status.txt        monitor-status.sh (read-only report mode)
#   validate-config.txt       validate-config.sh (its FAILs are content, not errors)
#   deployment-evidence.json  when present
#   config/config.js, config/constants.json, nginx/nginx.conf,
#   docker-compose.yml, dmss-*/application.yml
#                             at their paths in the checkout, secret values
#                             replaced by <redacted> (lib/redact.py)
#   config/env-keys.txt       the variable NAMES in .env, never a value
#   logs/<service>.log        docker compose logs --since <window> of every
#                             service except the wizard, through
#                             lib/redact.py --log (tokens, JWTs, base64
#                             signature images and documents removed)
#   host.txt                  uname, df, the Docker server version and storage
#
# Never included: signed documents (signed-output/, docs/), the signing
# activity log (signed-output/.padsign-audit/), .env values, TLS private keys,
# and the wizard's own log, which prints the wizard's access token. The script
# reads none of those paths.
#
# The output is a contract: the Deployment Wizard runs this script and parses
# it. One "  OK   <item>" or "  WARN <item>: <reason>" line per item (the
# format of validate-config.sh's ok()/warn()), and as the very last stdout
# line "BUNDLE <absolute path of the archive>". A collector that fails
# (Docker down, a script missing) is a WARN and a note in its file; it never
# stops the bundle.
#
# Exit codes: 0 bundle written (items may WARN), 1 the archive could not be
# written, 2 usage error, or python3 / tar missing.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

since="24h"
output_dir=""
host=""

usage() {
  cat <<'EOF'
Usage: ./installation-scripts/support-bundle.sh [--since 24h] [--output-dir DIR] [--host example.com]

Writes one archive for TrustLynx support: configuration with secret values
replaced by <redacted>, service logs with tokens and embedded images removed,
image versions, container state and the monitor-status.sh and
validate-config.sh reports. Signed documents, the signing activity log, .env
values, TLS private keys and the wizard's own log are never included.
See documentation/12-troubleshooting.md.

  --since       log window passed to docker compose logs: N[smhd] or RFC3339
                (default 24h)
  --output-dir  default <repo>/support-bundles (created mode 700); the
                archive itself is mode 600
  --host        default: server_name from nginx/nginx.conf

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

# Everything this script creates is owner-only: the bundle holds this
# deployment's configuration and logs.
umask 077
[[ -n "$output_dir" ]] || output_dir="${repo_root}/support-bundles"
if ! mkdir -p -m 700 "$output_dir" 2>/dev/null || [[ ! -w "$output_dir" ]]; then
  echo "ERROR: cannot create or write the output directory ${output_dir}. Pass --output-dir, or run as a user who may write there." >&2
  exit 1
fi
output_dir="$(cd "$output_dir" && pwd)"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp="${created//[-:]/}"   # 20260929T080000Z, the same second

collected=()   # archive paths, in collection order, for README.txt
warn_lines=()
ok()   { printf '  OK   %s\n' "$*"; }
warn() { printf '  WARN %s\n' "$*"; warn_lines+=("$*"); }

# run_redacted <archive path> <config|log> <command...>
#   Runs <command> with stdin from /dev/null; its stdout and stderr go
#   through lib/redact.py (--filter, plus --log for log mode) into the staging
#   copy of <archive path>. Sets cmd_rc to the command's exit status. Returns
#   1 when redact.py itself failed: that file is then removed, never kept
#   half-filtered.
run_redacted() {
  local path="$1" mode="$2" out
  local -a filter=(--filter) rcs
  shift 2
  [[ "$mode" == log ]] && filter+=(--log)
  out="${staging}/${path}"
  mkdir -p "$(dirname "$out")"
  set +e
  "$@" </dev/null 2>&1 | python3 "$redact_py" "${filter[@]}" > "$out"
  rcs=("${PIPESTATUS[@]}")
  set -e
  cmd_rc="${rcs[0]}"
  if [[ "${rcs[1]:-1}" != 0 ]]; then
    rm -f "$out"
    return 1
  fi
  collected+=("$path")
}

# collect <archive path> <config|log> <what> <command...>
#   run_redacted, then one OK or WARN line. A failed command leaves what it
#   printed in the file, plus a note saying it failed.
collect() {
  local path="$1" mode="$2" what="$3"
  shift 3
  if ! run_redacted "$path" "$mode" "$@"; then
    warn "${path}: lib/redact.py could not filter it - left out"
    return 0
  fi
  if [[ "$cmd_rc" == 0 ]]; then
    ok "$path"
  else
    printf '\n[support-bundle.sh] %s failed (exit %s); the lines above are all it printed.\n' "$what" "$cmd_rc" >> "${staging}/${path}"
    warn "${path}: ${what} failed (exit ${cmd_rc})"
  fi
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
  docker compose images 2>&1 || { rc=$?; echo "(docker compose images failed, exit ${rc})"; }
  echo ""
  echo "== image: lines of docker-compose.yml =="
  grep -nE '^[[:space:]]*image:' docker-compose.yml 2>&1 || echo "(none found)"
  return "$rc"
}

host_report() {
  local rc=0
  echo "== uname -a =="
  uname -a 2>&1 || echo "(uname failed)"
  echo ""
  echo "== df -P ${repo_root} =="
  df -P "$repo_root" 2>&1 || echo "(df failed)"
  echo ""
  echo "== docker version (server) =="
  docker version --format '{{.Server.Version}}' 2>&1 || { rc=$?; echo "(docker version failed, exit ${rc})"; }
  echo ""
  echo "== docker info: storage driver, root dir =="
  docker info --format '{{.Driver}} {{.DockerRootDir}}' 2>&1 || { rc=$?; echo "(docker info failed, exit ${rc})"; }
  return "$rc"
}

user_name="$(id -un 2>/dev/null || id -u)"
host_args=()
[[ -n "$host" ]] && host_args=(--host "$host")

echo "PadSign support bundle"
echo "================================"
echo "Host:    ${host:-<unknown, pass --host>}"
echo "Logs:    since ${since}"
echo "Output:  ${output_dir}"
echo ""

collect versions.txt log "docker compose images" versions_report
collect compose-ps.txt log "docker compose ps -a" docker compose ps -a
collect monitor-status.txt log "monitor-status.sh" \
  bash installation-scripts/monitor-status.sh ${host_args[@]+"${host_args[@]}"}

# validate-config.sh exits 1 when a check FAILs: that is its report, not a
# collection failure.
if run_redacted validate-config.txt log bash installation-scripts/validate-config.sh ${host_args[@]+"${host_args[@]}"}; then
  case "$cmd_rc" in
    0) ok "validate-config.txt" ;;
    1) ok "validate-config.txt (some checks FAILED - see the file)" ;;
    *) printf '\n[support-bundle.sh] validate-config.sh failed (exit %s).\n' "$cmd_rc" >> "${staging}/validate-config.txt"
       warn "validate-config.txt: validate-config.sh failed (exit ${cmd_rc})" ;;
  esac
else
  warn "validate-config.txt: lib/redact.py could not filter it - left out"
fi

if [[ -f deployment-evidence.json ]]; then
  collect deployment-evidence.json config "reading deployment-evidence.json" cat deployment-evidence.json
fi

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
  collect "$f" config "reading ${f}" cat "$f"
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

# Logs of every service the current profiles enable, never the wizard's.
services=()
if services_out="$(docker compose config --services 2>/dev/null </dev/null)"; then
  while IFS= read -r svc; do
    svc="${svc%$'\r'}"
    if [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$svc" != wizard ]]; then
      services+=("$svc")
    fi
  done <<< "$services_out"
  if [[ "${#services[@]}" -eq 0 ]]; then
    warn "logs/: docker compose config --services listed no services"
  fi
else
  warn "logs/: docker compose config --services failed - no service logs collected (is Docker running, and docker-compose.yml valid?)"
fi
for svc in ${services[@]+"${services[@]}"}; do
  collect "logs/${svc}.log" log "docker compose logs ${svc}" \
    docker compose logs --no-color --timestamps --since "$since_arg" "$svc"
done

collect host.txt log "docker version / docker info" host_report

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
  echo "secret-named values are <redacted>; in logs and reports, bearer tokens and"
  echo "JWTs are removed and base64 or other token runs of 200+ characters (drawn"
  echo "signatures, documents) are elided. config/env-keys.txt lists the names in"
  echo ".env, not the values."
  echo "Logs can still hold personal data of the people who sign (names, e-mail"
  echo "addresses): share this bundle with TrustLynx support only."
  echo ""
  echo "Not included: signed documents, the signing activity log, .env values, TLS private keys, the wizard's own log"
  if [[ "${#warn_lines[@]}" -gt 0 ]]; then
    echo ""
    echo "Warnings while collecting:"
    for w in "${warn_lines[@]}"; do echo "  ${w}"; done
  fi
} > "${staging}/README.txt"
ok "README.txt"

archive="${output_dir}/padsign-support-${safe_host}-${stamp}.tar.gz"
if ! tar -czf "$archive" -C "$staging" . ; then
  rm -f "$archive"
  echo "ERROR: could not write ${archive}" >&2
  exit 1
fi
if ! chmod 600 "$archive"; then
  echo "ERROR: could not make ${archive} owner-only (chmod 600) - remove it, or restrict it by hand before sending it" >&2
  exit 1
fi

echo ""
echo "Wrote ${archive} ($(( ${#collected[@]} + 1 )) files, ${#warn_lines[@]} warning(s), mode 600)."
echo "Send it to TrustLynx support; README.txt inside lists what it holds."
echo "BUNDLE ${archive}"
