#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Status Report + alerting.
#
# Default (report) mode is read-only: it prints a point-in-time snapshot and
# always exits 0, exactly as before.
#
# --alert mode evaluates the same numbers against thresholds, prints an
# "== Alerts ==" section, exits 1 when anything fired, and - when
# ALERT_WEBHOOK_URL is set (environment, or .env next to docker-compose.yml) -
# POSTs one JSON message per run to that URL. Run it from cron:
#
#   */10 * * * * cd /opt/padsign && ./installation-scripts/monitor-status.sh --alert >/dev/null
#
# In --alert mode the script keeps a small state file (.monitor-state/ by
# default) so that each run only scans logs written since the previous run
# and can compute restart deltas and buffer growth between runs. Report mode
# never reads or writes it.
#
# See documentation/40-03-monitoring-and-alerting.md for thresholds, the
# payload format and how to point it at Slack/Teams/any HTTP receiver.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

host=""
log_lines=500
since=""
alert_mode=false
compose_dir="$repo_root"
state_dir=""

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/monitor-status.sh [--host example.com] [--log-lines 500]
                                           [--since 15m|<RFC3339>]
                                           [--alert] [--state-dir DIR]
                                           [--compose-dir DIR]

Reports:
  - Per-service container state, health and restart count
  - Certificate days-to-expiry for nginx/certs/<host>.crt
  - Stamping / archive / routing failure counts from ps-server logs
  - Disk usage (directory sizes + filesystem use%)
  - Signed-PDF receive-back buffer: unacknowledged entries on disk + oldest age

--alert        Evaluate thresholds, exit 1 if any alert fired, and POST them to
               ALERT_WEBHOOK_URL when set. Keeps state in --state-dir
               (default: <repo>/.monitor-state) between runs.
--since        Log window for failure counts. Default in --alert mode: since the
               previous run (first run: last --log-lines lines). Default in
               report mode: last --log-lines lines.
--compose-dir  Directory holding docker-compose.yml (and .env, nginx/). Default:
               this repo's root. COMPOSE_PROJECT_NAME / COMPOSE_FILE are honored.

Thresholds (environment variables, defaults in brackets):
  ALERT_RESTART_DELTA [2]          restarts of one container since the last run
  ALERT_CERT_DAYS [14]             certificate expires within this many days
  ALERT_DISK_PCT [85]              filesystem use% at or above this
  ALERT_BUFFER_MAX [100]           unacknowledged receive-back entries
  ALERT_BUFFER_MAX_AGE_HOURS [72]  oldest unacknowledged entry older than this
  ALERT_FAILURE_MIN [1]            failure log lines per category in the window

Delivery:
  ALERT_WEBHOOK_URL                POST target (env var wins over .env)
  ALERT_WEBHOOK_AUTH_HEADER        optional full header line, e.g.
                                   "Authorization: Bearer abc"

Exit codes: 0 ok / no alerts, 1 alerts fired, 2 usage error,
            3 alerts fired AND webhook delivery failed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --log-lines) log_lines="${2:-}"; shift 2;;
    --since) since="${2:-}"; shift 2;;
    --alert) alert_mode=true; shift 1;;
    --state-dir) state_dir="${2:-}"; shift 2;;
    --compose-dir) compose_dir="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ ! -d "$compose_dir" ]]; then
  echo "ERROR: --compose-dir '${compose_dir}' does not exist." >&2
  exit 2
fi
compose_dir="$(cd "$compose_dir" && pwd)"
# docker compose resolves the project from the working directory - run every
# compose call from there, not from wherever cron happened to start us.
cd "$compose_dir"

[[ -z "$state_dir" ]] && state_dir="${repo_root}/.monitor-state"
state_file="${state_dir}/state"

restart_delta_max="${ALERT_RESTART_DELTA:-2}"
cert_days_min="${ALERT_CERT_DAYS:-14}"
disk_pct_max="${ALERT_DISK_PCT:-85}"
buffer_max="${ALERT_BUFFER_MAX:-100}"
buffer_age_max="${ALERT_BUFFER_MAX_AGE_HOURS:-72}"
failure_min="${ALERT_FAILURE_MIN:-1}"

# Derive --host from nginx.conf the same way verify-served-cert.sh does, if
# not given explicitly.
if [[ -z "$host" ]]; then
  host="$(awk '/server_name/{print $2; exit}' "${compose_dir}/nginx/nginx.conf" 2>/dev/null | tr -d ';' || true)"
fi

# ── Alert bookkeeping ──
alert_keys=()
alert_messages=()
alert_samples=()   # newline-separated sample lines per alert (may be empty)
add_alert() {
  alert_keys+=("$1")
  alert_messages+=("$2")
  alert_samples+=("${3:-}")
}

# ── Previous-run state (--alert only) ──
declare -A prev=()
if [[ "$alert_mode" == true && -f "$state_file" ]]; then
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] && prev["$k"]="$v"
  done < "$state_file"
fi
declare -A next=()

run_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ -z "$since" && "$alert_mode" == true && -n "${prev[last_run]:-}" ]]; then
  since="${prev[last_run]}"
fi
if [[ -n "$since" ]]; then
  log_window_args=(--since "$since")
  log_window_desc="since ${since}"
else
  log_window_args=(--tail "$log_lines")
  log_window_desc="in the last ${log_lines} log lines"
fi

echo "PadSign Status Report"
echo "================================"
echo "Generated: ${run_started}"
echo "Host:      ${host:-<unknown, pass --host>}"
echo "Mode:      $([[ "$alert_mode" == true ]] && echo alert || echo report)"
echo ""

# ── Containers ──
# `docker compose config --services` lists exactly the services active under
# the current profiles (COMPOSE_PROFILES in .env), so an enabled-but-crashed
# dmss-digital-stamping-service is reported as missing, while a deployment
# that never enabled local e-sealing does not expect it. The wizard is an
# on-demand tool, not part of the running service set.
mapfile -t services < <(docker compose config --services 2>/dev/null | grep -vx 'wizard' || true)
if [[ "${#services[@]}" -eq 0 ]]; then
  services=(keycloak dmss-archive-services dmss-container-and-signature-services dmss-archive-services-fallback ps-server nginx ps-client)
fi

echo "== Container health & restarts =="
printf '  %-40s %-12s %-12s %-10s\n' "SERVICE" "STATE" "HEALTH" "RESTARTS"
unhealthy_count=0
for svc in "${services[@]}"; do
  cid="$(docker compose ps -a -q "$svc" 2>/dev/null | head -1 || true)"
  if [[ -z "$cid" ]]; then
    printf '  %-40s %-12s %-12s %-10s\n' "$svc" "missing" "-" "-"
    add_alert "service_down" "${svc}: no container exists (expected under the current compose profiles)"
    continue
  fi
  read -r state health restarts < <(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$cid" 2>/dev/null || echo "unknown unknown 0")
  printf '  %-40s %-12s %-12s %-10s\n' "$svc" "$state" "$health" "$restarts"

  next["container.${svc}"]="$cid"
  next["restarts.${svc}"]="$restarts"

  if [[ "$state" != "running" ]]; then
    add_alert "service_down" "${svc}: container state is '${state}'"
  elif [[ "$health" == "unhealthy" ]]; then
    unhealthy_count=$((unhealthy_count + 1))
    add_alert "service_unhealthy" "${svc}: health check reports unhealthy"
  fi

  # A recreated container (upgrade, rollback, manual `up -d`) starts its
  # RestartCount at 0 again, so only diff counts for the same container id.
  if [[ -n "${prev[container.${svc}]:-}" && "${prev[container.${svc}]}" == "$cid" ]]; then
    delta=$(( restarts - ${prev[restarts.${svc}]:-0} ))
  else
    delta="$restarts"
    [[ -z "${prev[last_run]:-}" ]] && delta=0   # first run: no baseline yet
  fi
  if [[ "$delta" =~ ^[0-9]+$ && "$delta" -ge "$restart_delta_max" ]]; then
    add_alert "repeated_restarts" "${svc}: restarted ${delta} time(s) since the previous check (total ${restarts})"
  fi
done
echo ""
if [[ "$unhealthy_count" -gt 0 ]]; then
  echo "  WARNING: ${unhealthy_count} service(s) unhealthy."
  echo ""
fi

# ── Certificate ──
echo "== Certificate expiry =="
crt="${compose_dir}/nginx/certs/${host}.crt"
if [[ -n "$host" && -f "$crt" ]]; then
  enddate="$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  end_epoch="$(date -d "$enddate" +%s 2>/dev/null || echo "")"
  if [[ -n "$end_epoch" ]]; then
    days_left=$(( (end_epoch - $(date +%s)) / 86400 ))
    echo "  ${host}: expires ${enddate} (${days_left} days left)"
  else
    echo "  ${host}: expires ${enddate:-<unreadable>}"
  fi
  # -checkend is evaluated by openssl itself, so it works on hosts whose
  # `date` cannot parse openssl's date format.
  if [[ -z "$enddate" ]]; then
    add_alert "certificate_risk" "${crt}: certificate could not be read"
  elif ! openssl x509 -in "$crt" -noout -checkend $(( cert_days_min * 86400 )) >/dev/null 2>&1; then
    add_alert "certificate_risk" "${host}: certificate expires within ${cert_days_min} days (${enddate})"
  fi
elif [[ -n "$host" ]]; then
  echo "  Could not locate on-disk certificate for '${host}' at ${crt}"
  add_alert "certificate_risk" "${host}: no certificate found at ${crt}"
else
  echo "  Host unknown (pass --host); certificate not checked"
fi
echo ""

# ── Failure signals ──
# Each pattern matches what ps-server actually writes to stdout, not the
# errorCode strings it returns in HTTP bodies (those never reach the log).
archive_re='Error registering PDF:|Archive download failed|Archive service returned error status|Archive service response missing id field|Failed to upload PDF to archive'
stamp_re='\[stamp\] upstream unavailable|Error proxying stamp|Stamping config is incomplete'
webhook_permanent_re='\[documentRouting:webhook\] PERMANENT FAILURE after retries'
routing_re='\[documentRouting[^]]*\] .*(failed|error after stamp)|\[signedPdfBuffer\] failed to'
# Individual retry attempts are not failures yet - a later attempt may succeed;
# the PERMANENT FAILURE line is what reports a retry sequence that gave up.
retry_attempt_re='attempt [0-9]+ failed'
circuit_re='\[circuit:open\]'

echo "== Stamping / archive / routing failure signals (${log_window_desc}) =="
ps_server_cid="$(docker compose ps -q ps-server 2>/dev/null | head -1 || true)"
if [[ -n "$ps_server_cid" ]]; then
  recent_logs="$(docker compose logs --no-color "${log_window_args[@]}" ps-server 2>/dev/null || true)"
  matches() { printf '%s\n' "$recent_logs" | grep -E "$1" || true; }
  count_of() { [[ -z "$1" ]] && echo 0 || printf '%s\n' "$1" | grep -c . ; }
  # Last three matching lines, trimmed, so an alert says which document or
  # dependency failed instead of just a number.
  samples_of() { [[ -z "$1" ]] && return 0; printf '%s\n' "$1" | tail -3 | cut -c1-400; }

  check_failures() {  # key label regex [exclude-regex]
    local key="$1" label="$2" re="$3" exclude="${4:-}" lines n
    lines="$(matches "$re")"
    if [[ -n "$exclude" && -n "$lines" ]]; then
      lines="$(printf '%s\n' "$lines" | grep -Ev "$exclude" || true)"
    fi
    n="$(count_of "$lines")"
    printf '  %-34s %s\n' "$label" "$n"
    if [[ "$n" -ge "$failure_min" ]]; then
      add_alert "$key" "${label}: ${n} ${log_window_desc}" "$(samples_of "$lines")"
    fi
  }
  check_failures "archive_failure"                   "archive failures"             "$archive_re"
  check_failures "stamping_failure"                  "stamping failures"            "$stamp_re"
  check_failures "routing_webhook_permanent_failure" "webhook permanent failures"   "$webhook_permanent_re"
  check_failures "routing_failure"                   "other routing/buffer failures" "$routing_re" "${webhook_permanent_re}|${retry_attempt_re}"
  check_failures "circuit_open"                      "circuit-breaker opens"        "$circuit_re"
else
  echo "  ps-server not running - no logs to scan"
fi
echo ""

# ── Disk ──
echo "== Disk usage =="
for dir in "${compose_dir}/signed-output" "${compose_dir}/docs"; do
  if [[ -d "$dir" ]]; then
    echo "  ${dir}: $(du -sh "$dir" 2>/dev/null | cut -f1 || echo "?")"
  else
    echo "  ${dir}: does not exist"
  fi
done
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
disk_paths=("$compose_dir")
[[ -n "$docker_root" && -d "$docker_root" ]] && disk_paths+=("$docker_root")
declare -A seen_fs=()
for p in "${disk_paths[@]}"; do
  read -r fs_name pct mount < <(df -P "$p" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $1, $5, $6}' || true)
  [[ -z "${pct:-}" || -n "${seen_fs[$fs_name]:-}" ]] && continue
  seen_fs[$fs_name]=1
  echo "  filesystem ${mount} (${p}): ${pct}% used"
  if [[ "$pct" =~ ^[0-9]+$ && "$pct" -ge "$disk_pct_max" ]]; then
    add_alert "disk_pressure" "filesystem ${mount} holding ${p} is ${pct}% full (threshold ${disk_pct_max}%)"
  fi
done
if [[ -z "$docker_root" || ! -d "$docker_root" ]]; then
  echo "  Docker root dir not on this host's filesystem (Docker Desktop?) - use 'docker system df -v'"
fi
echo ""

# ── Receive-back buffer ──
# Counts <file>.meta.json sidecars whose PDF still exists, under every enabled
# filesystem strategy's basePath (and bufferPath), from inside the ps-server
# container - the same rule signedPdfBuffer.rebuildFromDisk() applies, so the
# number equals the pending index size. Works with any ps-server image; no
# endpoint needed.
echo "== Signed-PDF receive-back buffer =="
buffer_js='
const fs=require("fs"),path=require("path");
let cfg=null;
for (const p of ["/usr/src/app/config.js", path.join(process.cwd(),"config.js")]) { try { cfg=require(p); break; } catch (e) {} }
if (!cfg) { console.log("error=config.js not readable"); process.exit(0); }
const strategies=((cfg.DOCUMENT_ROUTING||{}).strategies)||[];
const roots=[];
for (const s of strategies) {
  if (!s||!s.enabled||s.type!=="filesystem"||!s.basePath) continue;
  for (const r of [s.basePath, s.bufferPath]) if (r && !roots.includes(r)) roots.push(r);
}
let count=0, oldest=null; const stack=roots.filter(r=>fs.existsSync(r)); const seen=new Set();
while (stack.length) {
  const d=stack.pop(); let ents;
  try { ents=fs.readdirSync(d,{withFileTypes:true}); } catch (e) { continue; }
  for (const e of ents) {
    const f=path.join(d,e.name);
    if (e.isDirectory()) { stack.push(f); continue; }
    if (!e.name.endsWith(".meta.json")||seen.has(f)) continue;
    seen.add(f);
    try {
      const m=JSON.parse(fs.readFileSync(f,"utf8"));
      if (!m.docid||!m.path||!fs.existsSync(m.path)) continue;
      count++;
      const t=Date.parse(m.signedAt);
      if (!isNaN(t)&&(oldest===null||t<oldest)) oldest=t;
    } catch (e) {}
  }
}
console.log("roots="+roots.join(","));
console.log("count="+count);
console.log("oldest_age_hours="+(oldest===null?"":Math.floor((Date.now()-oldest)/3600000)));
'
if [[ -n "$ps_server_cid" ]]; then
  # MSYS_NO_PATHCONV stops Git Bash (Windows dev hosts) from rewriting the
  # script's /usr/... literals; it is ignored everywhere else.
  buffer_out="$(MSYS_NO_PATHCONV=1 docker compose exec -T ps-server node -e "$buffer_js" 2>/dev/null </dev/null || echo "error=docker compose exec into ps-server failed")"
  buffer_error="$(printf '%s\n' "$buffer_out" | sed -n 's/^error=//p')"
  if [[ -n "$buffer_error" ]]; then
    echo "  Could not read buffer: ${buffer_error}"
  else
    buffer_roots="$(printf '%s\n' "$buffer_out" | sed -n 's/^roots=//p')"
    buffer_count="$(printf '%s\n' "$buffer_out" | sed -n 's/^count=//p')"
    buffer_age="$(printf '%s\n' "$buffer_out" | sed -n 's/^oldest_age_hours=//p')"
    if [[ -z "$buffer_roots" ]]; then
      echo "  No enabled filesystem routing strategy - receive-back buffer not in use"
    else
      echo "  Scan roots (inside ps-server): ${buffer_roots}"
      echo "  Unacknowledged entries: ${buffer_count}"
      echo "  Oldest unacknowledged:  $([[ -n "$buffer_age" ]] && echo "${buffer_age}h old" || echo "n/a")"
      if [[ -n "${prev[buffer_count]:-}" ]]; then
        echo "  Change since previous check: $(( buffer_count - ${prev[buffer_count]} ))"
      fi
      next["buffer_count"]="$buffer_count"
      if [[ "$buffer_count" =~ ^[0-9]+$ && "$buffer_count" -ge "$buffer_max" ]]; then
        add_alert "buffer_growth" "${buffer_count} signed PDFs waiting for Manager acknowledgement (threshold ${buffer_max})"
      fi
      if [[ "$buffer_age" =~ ^[0-9]+$ && "$buffer_age" -ge "$buffer_age_max" ]]; then
        add_alert "buffer_stale" "oldest unacknowledged signed PDF is ${buffer_age}h old (threshold ${buffer_age_max}h) - a Manager may be offline"
      fi
    fi
  fi
else
  echo "  ps-server not running - buffer not checked"
fi
echo ""

if [[ "$alert_mode" != true ]]; then
  echo "================================"
  echo "Report complete."
  exit 0
fi

# ── Alerts ──
json_str() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

echo "== Alerts =="
n_alerts="${#alert_keys[@]}"
if [[ "$n_alerts" -eq 0 ]]; then
  echo "  none"
else
  for i in "${!alert_keys[@]}"; do
    echo "  ALERT ${alert_keys[$i]}: ${alert_messages[$i]}"
    if [[ -n "${alert_samples[$i]}" ]]; then
      printf '%s\n' "${alert_samples[$i]}" | sed 's/^/      | /'
    fi
  done
fi
echo ""

# Persist state only after a complete run, so a crashed run re-scans its
# window next time rather than silently skipping it.
mkdir -p "$state_dir"
{
  echo "last_run=${run_started}"
  for k in "${!next[@]}"; do echo "${k}=${next[$k]}"; done
} > "${state_file}.tmp"
mv -f "${state_file}.tmp" "$state_file"

[[ "$n_alerts" -eq 0 ]] && { echo "No alerts."; exit 0; }

webhook_url="${ALERT_WEBHOOK_URL:-}"
webhook_auth="${ALERT_WEBHOOK_AUTH_HEADER:-}"
if [[ -f "${compose_dir}/.env" ]]; then
  env_val() { sed -n "s/^$1=//p" "${compose_dir}/.env" | tail -1 | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'; }
  [[ -z "$webhook_url" ]] && webhook_url="$(env_val ALERT_WEBHOOK_URL)"
  [[ -z "$webhook_auth" ]] && webhook_auth="$(env_val ALERT_WEBHOOK_AUTH_HEADER)"
fi

if [[ -z "$webhook_url" ]]; then
  echo "${n_alerts} alert(s) fired. ALERT_WEBHOOK_URL is not set - nothing delivered (exit code 1 only)."
  exit 1
fi

summary="PadSign ALERT on ${host:-unknown host}: ${n_alerts} alert(s)"
text="$summary"
alerts_json=""
for i in "${!alert_keys[@]}"; do
  text+=$'\n'"- ${alert_keys[$i]}: ${alert_messages[$i]}"
  samples_json=""
  if [[ -n "${alert_samples[$i]}" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      text+=$'\n'"    ${line}"
      samples_json+="${samples_json:+,}$(json_str "$line")"
    done <<< "${alert_samples[$i]}"
  fi
  alerts_json+="${alerts_json:+,}{\"key\":$(json_str "${alert_keys[$i]}"),\"message\":$(json_str "${alert_messages[$i]}"),\"samples\":[${samples_json}]}"
done
payload="{\"text\":$(json_str "$text"),\"source\":\"padsign-monitor\",\"host\":$(json_str "${host:-}"),\"generated\":$(json_str "$run_started"),\"alerts\":[${alerts_json}]}"

curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 15 --retry 2 -X POST -H 'Content-Type: application/json')
[[ -n "$webhook_auth" ]] && curl_args+=(-H "$webhook_auth")
# Only the scheme+host is ever printed - Slack/Teams webhook URLs embed their
# secret in the path.
webhook_target="$(printf '%s' "$webhook_url" | sed -E 's#^([a-zA-Z]+://[^/]+).*#\1#')"
http_code="$(printf '%s' "$payload" | curl "${curl_args[@]}" --data-binary @- "$webhook_url" 2>/dev/null || true)"
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
  echo "${n_alerts} alert(s) fired and delivered to ${webhook_target} (HTTP ${http_code})."
  exit 1
fi
echo "ERROR: ${n_alerts} alert(s) fired but delivery to ${webhook_target} failed (HTTP ${http_code:-none})." >&2
exit 3
