#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Status Report — read-only observability snapshot.
#
# This is NOT an alerting system: it prints a point-in-time report an
# operator (or a cron job piping this into something else) can read. Nothing
# here pages anyone. See documentation/40-03-monitoring-and-alerting-proposal.md
# for how each section below is meant to feed a real alerting stack.
#
# Usage:
#   ./installation-scripts/monitor-status.sh [--host example.com] [--log-lines 500]
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

host=""
log_lines=500

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/monitor-status.sh [--host example.com] [--log-lines 500]

Reports (read-only, never mutates anything):
  - Per-service container health state + restart count
  - Certificate days-to-expiry (derived like verify-served-cert.sh)
  - Stamping/archive/routing failure counts, grepped from recent ps-server logs
  - Disk usage for signed-output/, docs/, and the keycloak_data volume
  - Signed-PDF receive-back buffer size (best-effort, see caveat in output)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --log-lines) log_lines="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

# Derive --host from nginx.conf the same way verify-served-cert.sh does, if
# not given explicitly.
if [[ -z "$host" ]]; then
  host="$(awk '/server_name/{print $2; exit}' "${repo_root}/nginx/nginx.conf" 2>/dev/null | tr -d ';')"
fi

services=(keycloak dmss-archive-services dmss-container-and-signature-services dmss-archive-services-fallback ps-server nginx ps-client)
if docker compose ps --services --filter "status=running" 2>/dev/null | grep -qx "dmss-digital-stamping-service"; then
  services+=(dmss-digital-stamping-service)
fi

echo "PadSign Status Report"
echo "================================"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host:      ${host:-<unknown, pass --host>}"
echo ""

echo "== Container health & restarts =="
printf '  %-40s %-12s %-10s\n' "SERVICE" "HEALTH" "RESTARTS"
unhealthy_count=0
for svc in "${services[@]}"; do
  cid="$(docker compose ps -q "$svc" 2>/dev/null || echo "")"
  if [[ -z "$cid" ]]; then
    printf '  %-40s %-12s %-10s\n' "$svc" "not running" "-"
    continue
  fi
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}(no healthcheck){{end}}' "$cid" 2>/dev/null || echo "unknown")"
  restarts="$(docker inspect --format '{{.RestartCount}}' "$cid" 2>/dev/null || echo "?")"
  printf '  %-40s %-12s %-10s\n' "$svc" "$health" "$restarts"
  [[ "$health" == "unhealthy" ]] && unhealthy_count=$((unhealthy_count + 1))
done
echo ""
if [[ "$unhealthy_count" -gt 0 ]]; then
  echo "  WARNING: ${unhealthy_count} service(s) unhealthy."
fi
echo ""

echo "== Certificate expiry =="
crt="${repo_root}/nginx/certs/${host}.crt"
if [[ -n "$host" && -f "$crt" ]]; then
  enddate="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [[ -n "$enddate" ]]; then
    end_epoch="$(date -d "$enddate" +%s 2>/dev/null || echo "")"
    now_epoch="$(date +%s)"
    if [[ -n "$end_epoch" ]]; then
      days_left=$(( (end_epoch - now_epoch) / 86400 ))
      echo "  ${host}: expires ${enddate} (${days_left} days left)"
      if [[ "$days_left" -lt 7 ]]; then
        echo "  WARNING: certificate expires in under 7 days."
      elif [[ "$days_left" -lt 30 ]]; then
        echo "  NOTE: certificate expires in under 30 days."
      fi
    else
      echo "  ${host}: expires ${enddate} (could not compute days remaining on this platform)"
    fi
  fi
else
  echo "  Could not locate on-disk certificate for '${host}' at ${crt}"
fi
echo ""

echo "== Stamping / archive / routing failure signals (last ${log_lines} log lines) =="
if docker compose ps -q ps-server >/dev/null 2>&1 && [[ -n "$(docker compose ps -q ps-server 2>/dev/null)" ]]; then
  recent_logs="$(docker compose logs --tail "$log_lines" ps-server 2>/dev/null || echo "")"
  count_matches() { printf '%s\n' "$recent_logs" | grep -cE "$1" || true; }
  archive_errors="$(count_matches 'ARCHIVE_ERROR|ARCHIVE_TIMEOUT|ARCHIVE_UNAVAILABLE|ARCHIVE_UPSTREAM_5XX|ARCHIVE_CIRCUIT_OPEN')"
  stamp_errors="$(count_matches 'STAMP_UPSTREAM_UNAVAILABLE|STAMP_CIRCUIT_OPEN|Error proxying stamp')"
  routing_errors="$(count_matches "documentRouting.*(FAILURE|failed)")"
  circuit_opens="$(count_matches '\[circuit:open\]')"
  printf '  %-30s %s\n' "archive failures" "$archive_errors"
  printf '  %-30s %s\n' "stamping failures" "$stamp_errors"
  printf '  %-30s %s\n' "routing failures" "$routing_errors"
  printf '  %-30s %s\n' "circuit-breaker opens" "$circuit_opens"
else
  echo "  ps-server not running — no logs to scan"
fi
echo ""

echo "== Disk usage =="
for dir in "${repo_root}/signed-output" "${repo_root}/docs"; do
  if [[ -d "$dir" ]]; then
    du_out="$(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")"
    echo "  ${dir}: ${du_out}"
  else
    echo "  ${dir}: does not exist"
  fi
done
kc_vol="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '_?keycloak_data$' | head -1 || echo "")"
if [[ -n "$kc_vol" ]]; then
  kc_mount="$(docker volume inspect "$kc_vol" --format '{{.Mountpoint}}' 2>/dev/null || echo "")"
  echo "  keycloak_data volume (${kc_vol}): mountpoint ${kc_mount:-unknown} (size not queryable from the host on Docker Desktop; use 'docker system df -v')"
fi
echo ""

echo "== Signed-PDF receive-back buffer (best-effort proxy) =="
echo "  NOTE: psapp/server/lib/signedPdfBuffer.js exposes no live stats getter today"
echo "  (only rebuildFromDisk() returns byDocid.size, and only at boot). The lines"
echo "  below are the closest available signal until a small psapp change adds a"
echo "  real getStats()/endpoint — see documentation/40-03-monitoring-and-alerting-proposal.md."
if docker compose ps -q ps-server >/dev/null 2>&1 && [[ -n "$(docker compose ps -q ps-server 2>/dev/null)" ]]; then
  last_rebuild="$(docker compose logs --tail "$log_lines" ps-server 2>/dev/null | grep 'index rebuilt from disk' | tail -1 || echo "")"
  buffered_count="$(docker compose logs --tail "$log_lines" ps-server 2>/dev/null | grep -c 'buffered signed document' || true)"
  acked_count="$(docker compose logs --tail "$log_lines" ps-server 2>/dev/null | grep -c 'acknowledged + removed from buffer' || true)"
  echo "  Last rebuild-from-disk log line: ${last_rebuild:-<none in last ${log_lines} lines>}"
  echo "  Buffered-document log lines in window: ${buffered_count}"
  echo "  Acknowledged/removed log lines in window: ${acked_count}"
  if [[ "$buffered_count" -gt 0 && "$acked_count" == "0" ]]; then
    echo "  NOTE: documents are being buffered but none acknowledged in this window — worth a closer look."
  fi
else
  echo "  ps-server not running — no logs to scan"
fi
echo ""

echo "================================"
echo "Report complete."
