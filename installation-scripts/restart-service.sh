#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Restart Service - restart ONE service of the running stack and wait
# until it is healthy again. The Deployment Wizard's per-service Restart
# button runs this; by hand it works the same.
#
# Usage:
#   ./installation-scripts/restart-service.sh --service ps-server [--health-timeout 480]
#
# What it does:
#   1) docker compose restart <service>: the same container is stopped and
#      started again, so it keeps its log. Bind-mounted configuration
#      (config/config.js, nginx/nginx.conf) is read again on the way up.
#   2) Waits until the service is running and healthy (lib/health-wait.sh,
#      as upgrade.sh does; documentation/09-09-health-checks-and-startup.md),
#      failing early when it reports unhealthy, exits or crash-loops. The
#      default wait, 480 s, covers the DMSS services' 300 s start_period.
#
# What it does not do:
#   - Pick up changes to docker-compose.yml or .env (an image tag, an
#     environment variable such as KC_HOSTNAME): a restart keeps the
#     container definition it was created with. Those take effect only when
#     the container is recreated: docker compose up -d
#   - Restart the services that depend on this one; only <service> restarts.
#   - Restart the wizard, which would stop the process running this script.
#     On the host: docker compose restart wizard
#
# Exit codes: 0 restarted and healthy, 1 the service has no container to
# restart, the restart failed, or it was not healthy in time (also when the
# services cannot be listed), 2 usage error, unknown service, or the wizard.
# ============================================================================

service=""
health_timeout="480"

usage() {
  cat <<'EOF'
Usage: ./installation-scripts/restart-service.sh --service NAME [--health-timeout 480]
Restarts one service of the running stack (docker compose restart, keeping the container
and its log) and waits until it is healthy again.

  --service NAME          A service of docker-compose.yml under the current profiles
                          (docker compose config --services), except the wizard.
  --health-timeout SECS   How long to wait for it to become healthy. Default 480.

A restart does not pick up docker-compose.yml or .env changes (use docker compose up -d
for those) and does not restart the services that depend on this one.

Exit: 0 restarted and healthy, 1 restart failed or not healthy in time, 2 usage / unknown service / wizard
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) service="${2:-}"; shift $(( $# >= 2 ? 2 : 1 ));;
    --health-timeout) health_timeout="${2:-}"; shift $(( $# >= 2 ? 2 : 1 ));;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$service" ]]; then
  echo "ERROR: --service is required" >&2
  usage
  exit 2
fi
if [[ ! "$health_timeout" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --health-timeout must be a whole number of seconds (got '${health_timeout}')" >&2
  exit 2
fi
if [[ "${#health_timeout}" -gt 6 ]]; then
  echo "ERROR: --health-timeout must be at most 6 digits (got '${health_timeout}')" >&2
  exit 2
fi
health_timeout=$((10#$health_timeout))   # 08 is 8 seconds, not an octal error
# Refused before docker is asked anything: the wizard runs this script, and
# restarting its own container would kill the run half-way.
if [[ "$service" == wizard ]]; then
  echo "ERROR: the wizard cannot restart itself; on the host run: docker compose restart wizard" >&2
  exit 2
fi

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"
# shellcheck source=lib/health-wait.sh
. "${scripts_dir}/lib/health-wait.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Missing dependency: docker" >&2
  exit 1
fi
# docker compose resolves the project (and .env's COMPOSE_PROFILES) from the
# working directory.
cd "$repo_root"

# compose's own error (a broken .env or YAML) goes into the message, so the
# wizard's log shows why.
config_err="$(mktemp)"
trap 'rm -f "$config_err"' EXIT
if ! services_out="$(docker compose config --services 2>"$config_err" </dev/null)"; then
  why="$(sed -n '/[^[:space:]]/{s/\r$//;p;q;}' "$config_err")"
  echo "ERROR: could not list the services (docker compose config --services failed in ${repo_root})${why:+: ${why}}" >&2
  exit 1
fi
found=false
list=""   # every service but the wizard, for the error message
while IFS= read -r s; do
  s="${s%$'\r'}"
  if [[ -z "$s" || "$s" == wizard ]]; then continue; fi
  list+="${list:+, }${s}"
  if [[ "$s" == "$service" ]]; then found=true; fi
done <<< "$services_out"
if [[ "$found" != true ]]; then
  echo "ERROR: unknown service '${service}'. Services: ${list}" >&2
  exit 2
fi

# A restart only restarts an existing container; one that was never created
# (or was removed) needs docker compose up -d, and waiting would only time out.
cids="$(docker compose ps -a -q "$service" 2>/dev/null </dev/null || true)"
if [[ -z "$cids" ]]; then
  echo "ERROR: ${service} has no container to restart; create it with: docker compose up -d ${service}" >&2
  exit 1
fi

echo "PadSign service restart"
echo "================================"

echo "Step 1/2: Restarting ${service}"
if ! docker compose restart "$service" </dev/null; then
  echo "ERROR: docker compose restart ${service} failed" >&2
  exit 1
fi

echo "Step 2/2: Waiting for ${service} to become healthy (up to ${health_timeout}s)"
if ! wait_for_healthy "$health_timeout" "$service"; then
  echo "ERROR: ${service} is not healthy after the restart - see the output above" >&2
  exit 1
fi
echo "  ${service}: OK (running and healthy)"
echo "Restart complete."
