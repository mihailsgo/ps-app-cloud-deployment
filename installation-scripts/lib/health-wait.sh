# shellcheck shell=bash
# ============================================================================
# wait_for_healthy - block until compose services are healthy, or fail.
#
# Sourced by bootstrap.sh, upgrade.sh and rollback.sh so that a deployment
# which comes up unhealthy FAILS (non-zero exit) instead of printing a warning
# and reporting success. `docker compose up -d` returns as soon as containers
# are created; the depends_on: condition: service_healthy gates only order the
# dependencies, never the service that was just recreated.
#
# Usage (from the directory holding docker-compose.yml):
#   wait_for_healthy <timeout-seconds> <service>...
#
# Returns 0 when every service is running and healthy (or running with no
# healthcheck). Returns 1, after printing which service failed and its last
# health-probe output, as soon as a service:
#   - reports "unhealthy" (Docker has already exhausted its retries),
#   - is exited/dead,
#   - restarts 2+ times while we wait (crash loop - it will never be healthy),
#   - or has not become healthy within the timeout.
# Works with any Compose v2 (does not need `up --wait` / `--wait-timeout`).
# ============================================================================

_hw_describe_failure() {  # <service> <container-id> <reason>
  local svc="$1" cid="$2" reason="$3" last_probe
  echo "  FAILED: ${svc} ${reason}" >&2
  if [[ -n "$cid" ]]; then
    last_probe="$(docker inspect --format '{{if .State.Health}}{{range .State.Health.Log}}{{.Output}}{{"\x1f"}}{{end}}{{end}}' "$cid" 2>/dev/null | tr '\037' '\n' | grep -v '^$' | tail -1 | cut -c1-300 || true)"
    [[ -n "$last_probe" ]] && echo "          last health probe output: ${last_probe}" >&2
    echo "          recent logs (docker compose logs --tail 15 ${svc}):" >&2
    docker compose logs --no-color --tail 15 "$svc" 2>/dev/null | sed 's/^/            /' >&2 || true
  fi
}

wait_for_healthy() {
  local timeout="$1"; shift
  local deadline=$(( $(date +%s) + timeout ))
  local svc cid state health restarts pending
  declare -A _hw_start_restarts=()

  while :; do
    pending=()
    for svc in "$@"; do
      cid="$(docker compose ps -a -q "$svc" 2>/dev/null | head -1 || true)"
      if [[ -z "$cid" ]]; then
        pending+=("${svc}(no container)")
        continue
      fi
      read -r state health restarts < <(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$cid" 2>/dev/null || echo "unknown unknown 0")
      [[ -z "${_hw_start_restarts[$svc]:-}" ]] && _hw_start_restarts[$svc]="$restarts"

      case "${state}/${health}" in
        running/healthy|running/none) continue ;;
        */unhealthy) _hw_describe_failure "$svc" "$cid" "is unhealthy"; return 1 ;;
        exited/*|dead/*) _hw_describe_failure "$svc" "$cid" "container ${state}"; return 1 ;;
      esac
      if (( restarts - _hw_start_restarts[$svc] >= 2 )); then
        _hw_describe_failure "$svc" "$cid" "is crash-looping (restarted $(( restarts - _hw_start_restarts[$svc] )) times while waiting)"
        return 1
      fi
      pending+=("${svc}(${state}/${health})")
    done

    [[ "${#pending[@]}" -eq 0 ]] && return 0
    if (( $(date +%s) >= deadline )); then
      echo "  FAILED: not healthy after ${timeout}s: ${pending[*]}" >&2
      return 1
    fi
    sleep 3
  done
}
