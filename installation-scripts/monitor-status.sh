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
# POSTs one JSON message per run to that URL. ALERT_WEBHOOK_FORMAT picks the
# message shape: json (default) or teams (the Adaptive Card a Microsoft Teams
# Workflows webhook requires; auto-selected for a Workflows URL). Run it from
# cron:
#
#   */10 * * * * cd /opt/padsign && ./installation-scripts/monitor-status.sh --alert >/dev/null
#
# --test-webhook sends one harmless test message through the same URL, format
# and auth header, prints the HTTP status and exits. It needs no running stack.
#
# In --alert mode the script keeps a small state file (.monitor-state/ by
# default) so that each run only scans logs written since the previous run
# and can compute restart deltas and buffer growth between runs. Report mode
# never reads or writes it.
#
# --format json is report mode for a program (the Deployment Wizard's
# Monitoring page): the same checks, and the alerts the thresholds would
# fire, as ONE JSON document on stdout, exit 0. Like report mode it never
# reads or writes the state file, and it never resolves or posts to a
# webhook, so it cannot be combined with --alert or --test-webhook. Schema 1:
#
#   schema       1
#   generated    RFC 3339 UTC timestamp;  host  string, or null when unknown
#   thresholds   {restartDelta, certDays, diskPct, bufferMax,
#                 bufferMaxAgeHours, failureMin}
#   services     [{service, state, health, restarts}]; state "missing" (with
#                health and restarts null) when no container exists; health
#                "none" for a container without a healthcheck
#   certificate  {host, path, found, notAfter, daysLeft}; null when the host
#                is unknown; notAfter and daysLeft null when not found/read
#   failures     {window, counts: [{key, label, count}]}; null when ps-server
#                is not running
#   disk         {stores: [{name, path, exists, size, inTree, volume,
#                 inspectable}], filesystems: [{mount, path, usedPct}]}; a
#                named-volume store has path, exists and size null; a store
#                this process cannot look at (mounted from outside what the
#                wizard container sees, or unreadable by this user) has
#                inspectable false and exists and size null; inspectable is
#                true for every store whose directory could be examined
#   buffer       {state, count, oldestAgeHours, error}; state "ok",
#                "not-in-use" (no filesystem strategy), "not-running"
#                (ps-server down) or "error"; count and oldestAgeHours are
#                null unless "ok"; error (null unless "error") says why, with
#                compose's own reason (redacted) when compose itself failed
#   alerts       [{key, message, samples}], as --alert posts them
#
# A number that is not an integer where one is expected is null.
#
# See documentation/09-10-monitoring-and-alerting.md for thresholds, the
# payload format and how to point it at Slack/Teams/any HTTP receiver.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${scripts_dir}/.." && pwd)"

host=""
log_lines=500
since=""
alert_mode=false
test_webhook=false
format="text"
compose_dir="$repo_root"
state_dir=""

# shellcheck source=lib/alert-webhook.sh
. "${scripts_dir}/lib/alert-webhook.sh"
# storage_mount: where the effective compose model mounts the stores from.
# shellcheck source=lib/dir-permissions.sh
. "${scripts_dir}/lib/dir-permissions.sh"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/monitor-status.sh [--host example.com] [--log-lines 500]
                                           [--since 15m|<RFC3339>]
                                           [--alert] [--state-dir DIR]
                                           [--compose-dir DIR]
  ./installation-scripts/monitor-status.sh --format json [--host example.com]
                                           [--log-lines 500] [--since 15m|<RFC3339>]
                                           [--compose-dir DIR]
  ./installation-scripts/monitor-status.sh --test-webhook [--host example.com]
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
--test-webhook Send ONE harmless test message ("PadSign monitor test from
               <host> - webhook works") with the same URL, format and auth
               header --alert uses, print the HTTP status and exit: 0 delivered
               (2xx), 3 not delivered, 2 not configured. Checks nothing else
               and needs no running stack.
--format       text (default): the report above. json: the same report, and the
               alerts the thresholds would fire, as one JSON document on stdout
               (schema 1, described in this script's header), for programs such
               as the Deployment Wizard. Read-only like the text report: never
               reads or writes --state-dir, never posts to a webhook, exits 0.
               Cannot be combined with --alert or --test-webhook.
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
  ALERT_WEBHOOK_URL                POST target (env var wins over .env). A secret:
                                   only its scheme and host are ever printed.
  ALERT_WEBHOOK_FORMAT             json (default): {"text":...,"alerts":[...]},
                                   for Slack and generic receivers.
                                   teams: an Adaptive Card message, which a
                                   Microsoft Teams Workflows webhook requires.
                                   Unset: teams when the URL host ends with
                                   .logic.azure.com or contains .powerplatform.com,
                                   otherwise json. An explicit value always wins.
  ALERT_WEBHOOK_AUTH_HEADER        optional full header line, e.g.
                                   "Authorization: Bearer abc"
  Any 2xx counts as delivered. Teams Workflows answers 202 before its flow
  runs, so a 202 does not prove the card was posted.

Exit codes: 0 ok / no alerts, 1 alerts fired, 2 usage error (including an
            unsupported ALERT_WEBHOOK_FORMAT), 3 alerts fired AND webhook
            delivery failed. --test-webhook: 0 delivered, 2 not configured,
            3 not delivered. --format json: 0, or 2 usage error.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --log-lines) log_lines="${2:-}"; shift 2;;
    --since) since="${2:-}"; shift 2;;
    --alert) alert_mode=true; shift 1;;
    --test-webhook) test_webhook=true; shift 1;;
    --format) format="${2:-}"; shift $(( $# >= 2 ? 2 : 1 ));;
    --state-dir) state_dir="${2:-}"; shift 2;;
    --compose-dir) compose_dir="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

case "$format" in
  text|json) ;;
  *) echo "ERROR: --format must be text or json (got '${format}')." >&2; exit 2;;
esac
if [[ "$format" == json && ( "$alert_mode" == true || "$test_webhook" == true ) ]]; then
  echo "ERROR: --format json is read-only; it cannot be combined with --alert or --test-webhook." >&2
  exit 2
fi

if [[ ! -d "$compose_dir" ]]; then
  echo "ERROR: --compose-dir '${compose_dir}' does not exist." >&2
  exit 2
fi
compose_dir="$(cd "$compose_dir" && pwd)"
# docker compose resolves the project from the working directory - run every
# compose call from there, not from wherever cron happened to start us.
cd "$compose_dir"

# --format json: the report below still runs as it is, its text going
# nowhere; the values it computes are collected on the way and printed as
# one JSON document on the original stdout (fd 3) where the text report ends.
if [[ "$format" == json ]]; then
  exec 3>&1 1>/dev/null
fi

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

# ── Webhook settings (--alert, --test-webhook) ──
# Resolved up front, so an unsupported ALERT_WEBHOOK_FORMAT stops the run
# (exit 2) at the first check by hand instead of when an alert finally fires.
webhook_url=""; webhook_auth=""; webhook_format="json"; webhook_format_why="default"
if [[ "$alert_mode" == true || "$test_webhook" == true ]]; then
  resolve_webhook_config "$compose_dir" || exit 2
fi

teams_202_note() {
  echo "  Teams Workflows answers 202 before its flow runs, so a 2xx does not prove the card was posted."
  echo "  If it is not in the channel within a minute, open the flow's run history (Power Automate > My flows)."
}

if [[ "$test_webhook" == true ]]; then
  echo "PadSign webhook test"
  echo "================================"
  if [[ -z "$webhook_url" ]]; then
    echo "ERROR: ALERT_WEBHOOK_URL is not set (environment, or ${compose_dir}/.env) - nothing to test." >&2
    exit 2
  fi
  test_generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  test_text="PadSign monitor test from ${host:-unknown host} - webhook works"
  webhook_target="$(webhook_url_target "$webhook_url")"
  if [[ "$webhook_format" == teams ]]; then
    payload="$(teams_card_payload "$(card_text_block "$test_text" '"weight":"Bolder","size":"Medium"'),$(card_text_block "Sent by monitor-status.sh --test-webhook. This is a test: no action needed."),$(card_footer "$test_generated")")"
  else
    payload="{\"text\":$(json_str "$test_text"),\"source\":\"padsign-monitor\",\"host\":$(json_str "${host:-}"),\"generated\":$(json_str "$test_generated"),\"test\":true,\"alerts\":[]}"
  fi
  echo "Webhook:   ${webhook_target} (scheme and host only; the URL is a secret and is never printed)"
  echo "Format:    ${webhook_format} (${webhook_format_why})"
  echo "Message:   ${test_text}"
  post_webhook "$webhook_url" "$webhook_auth" "$payload"
  if [[ "$webhook_http_code" =~ ^2[0-9][0-9]$ ]]; then
    echo "Result:    HTTP ${webhook_http_code} - delivered to ${webhook_target}."
    if [[ "$webhook_format" == teams ]]; then teams_202_note; fi
    exit 0
  fi
  echo "ERROR: HTTP ${webhook_http_code} - the test message was not delivered to ${webhook_target}." >&2
  if [[ -n "$webhook_curl_error" ]]; then echo "  ${webhook_curl_error}" >&2; fi
  exit 3
fi

# A log line (or a path) can hold bytes that are not UTF-8; a webhook payload
# and the --format json document must be UTF-8. Drops invalid sequences and
# keeps valid multi-byte characters. iconv -c exits non-zero when it dropped
# something, which is expected here.
utf8_clean() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -c -f UTF-8 -t UTF-8 || true
  elif command -v perl >/dev/null 2>&1; then
    perl -MEncode -pe '$_ = Encode::encode("UTF-8", Encode::decode("UTF-8", $_, sub { "" }))' || true
  else
    cat
  fi
}

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
# For --format json: one entry per service, in report order.
svc_names=(); svc_states=(); svc_healths=(); svc_restarts=()
for svc in "${services[@]}"; do
  cid="$(docker compose ps -a -q "$svc" 2>/dev/null | head -1 || true)"
  if [[ -z "$cid" ]]; then
    printf '  %-40s %-12s %-12s %-10s\n' "$svc" "missing" "-" "-"
    svc_names+=("$svc"); svc_states+=("missing"); svc_healths+=(""); svc_restarts+=("")
    add_alert "service_down" "${svc}: no container exists (expected under the current compose profiles)"
    continue
  fi
  read -r state health restarts < <(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$cid" 2>/dev/null || echo "unknown unknown 0")
  printf '  %-40s %-12s %-12s %-10s\n' "$svc" "$state" "$health" "$restarts"
  svc_names+=("$svc"); svc_states+=("$state"); svc_healths+=("$health"); svc_restarts+=("$restarts")

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
enddate=""; days_left=""
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
fail_keys=(); fail_labels=(); fail_counts=()   # for --format json
if [[ -n "$ps_server_cid" ]]; then
  recent_logs="$(docker compose logs --no-color "${log_window_args[@]}" ps-server 2>/dev/null || true)"
  # LC_ALL=C: the patterns are ASCII, and under a UTF-8 locale GNU grep takes
  # a line that is not valid UTF-8 for binary data and leaves it out.
  matches() { printf '%s\n' "$recent_logs" | LC_ALL=C grep -E "$1" || true; }
  count_of() { [[ -z "$1" ]] && echo 0 || printf '%s\n' "$1" | LC_ALL=C grep -c . ; }
  # Last three matching lines, trimmed, so an alert says which document or
  # dependency failed instead of just a number. The cut is at byte 400, and a
  # multi-byte character (a Latvian letter) it splits is dropped: half a
  # character makes the payload invalid UTF-8. So are any other bytes that
  # are not UTF-8 (utf8_clean).
  utf8_cut_tail=$'s/([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})$//'
  samples_of() { [[ -z "$1" ]] && return 0; printf '%s\n' "$1" | tail -3 | LC_ALL=C cut -b1-400 | LC_ALL=C sed -E "$utf8_cut_tail" | utf8_clean; }

  check_failures() {  # key label regex [exclude-regex]
    local key="$1" label="$2" re="$3" exclude="${4:-}" lines n
    lines="$(matches "$re")"
    if [[ -n "$exclude" && -n "$lines" ]]; then
      lines="$(printf '%s\n' "$lines" | LC_ALL=C grep -Ev "$exclude" || true)"
    fi
    n="$(count_of "$lines")"
    printf '  %-34s %s\n' "$label" "$n"
    fail_keys+=("$key"); fail_labels+=("$label"); fail_counts+=("$n")
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
# The two stores are wherever the effective compose model mounts them from
# (lib/digest_gate.py mounts, read by storage_mount in lib/dir-permissions.sh,
# as upgrade.sh does): on an overlay-managed checkout compose.overlay.yml
# mounts them from outside the checkout, where the documents already are, and
# the checkout's own signed-output/ and docs/ do not exist. When the model
# cannot be read (no python3), or has no such mount, the checkout paths are
# shown as before.
store_mounts=""
if command -v python3 >/dev/null 2>&1; then
  store_mounts="$(python3 "${scripts_dir}/lib/digest_gate.py" mounts "$compose_dir" 2>/dev/null | tr -d '\r' || true)"
fi
store_dirs=()
# For --format json: one entry per store. exists is true/false, empty for a
# named volume.
store_names=(); store_paths=(); store_exists=(); store_sizes=(); store_in_tree=(); store_volume=(); store_inspectable=()
for store in "ps-server /signed-output signed-output" "dmss-archive-services-fallback /docs docs"; do
  read -r store_svc store_target store_name <<< "$store"
  # storage_mount resolves in-tree mounts against repo_root: here, the
  # directory the model was read from.
  repo_root="$compose_dir" storage_mount "$store_svc" "$store_target" "${compose_dir}/${store_name}" "$store_mounts"
  store_names+=("$store_name")
  if [[ "$storage_how" == volume ]]; then
    echo "  ${store_name}: a named Docker volume (no host directory) - see 'docker system df -v'"
    store_paths+=(""); store_exists+=(""); store_sizes+=(""); store_in_tree+=(false); store_volume+=(true); store_inspectable+=(false)
    continue
  fi
  where=""
  [[ "$storage_in_tree" == true ]] || where=" (${store_name}, mounted from outside the checkout)"
  store_paths+=("$storage_path"); store_in_tree+=("$storage_in_tree"); store_volume+=(false)
  # A store mounted from outside what this process can see (the wizard
  # container sees the deployment directory only) or that this user may not
  # read is "cannot inspect", not "does not exist".
  repo_root="$compose_dir" store_probe "$storage_path"
  if [[ "$store_state" == outside || "$store_state" == denied ]]; then
    if [[ "$store_state" == denied ]]; then
      echo "  ${storage_path}: cannot inspect (permission denied for this user)${where}"
    else
      echo "  ${storage_path}: cannot inspect (outside what the wizard can read)${where}"
    fi
    store_exists+=(""); store_sizes+=(""); store_inspectable+=(false)
    continue
  fi
  store_inspectable+=(true)
  if [[ -d "$storage_path" ]]; then
    store_size="$(du -sh "$storage_path" 2>/dev/null | cut -f1 || echo "?")"
    echo "  ${storage_path}: ${store_size}${where}"
    store_dirs+=("$storage_path")
    store_exists+=(true); store_sizes+=("${store_size%%$'\n'*}")
  else
    echo "  ${storage_path}: does not exist${where}"
    store_exists+=(false); store_sizes+=("")
  fi
done
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
# The stores' filesystems too: overlay storage can be a separate volume.
disk_paths=("$compose_dir" ${store_dirs[@]+"${store_dirs[@]}"})
[[ -n "$docker_root" && -d "$docker_root" ]] && disk_paths+=("$docker_root")
declare -A seen_fs=()
fs_mounts=(); fs_paths=(); fs_pcts=()   # for --format json
for p in "${disk_paths[@]}"; do
  # || true: no df output (read hits EOF) skips the path instead of ending the run.
  read -r fs_name pct mount < <(df -P "$p" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $1, $5, $6}' || true) || true
  [[ -z "${pct:-}" || -n "${seen_fs[$fs_name]:-}" ]] && continue
  seen_fs[$fs_name]=1
  echo "  filesystem ${mount} (${p}): ${pct}% used"
  fs_mounts+=("$mount"); fs_paths+=("$p"); fs_pcts+=("$pct")
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
# For --format json: ok | not-in-use | not-running | error.
buffer_state="not-running"; buffer_error=""; buffer_count=""; buffer_age=""
if [[ -n "$ps_server_cid" ]]; then
  # MSYS_NO_PATHCONV stops Git Bash (Windows dev hosts) from rewriting the
  # script's /usr/... literals; it is ignored everywhere else. stderr is kept
  # apart: when compose itself fails (a compose file COMPOSE_FILE names is not
  # readable here, the daemon is gone) the error says why, with the first line
  # that is not a compose warning, redacted (lib/redact.py; without python3
  # the reason is left out rather than shown unredacted).
  buffer_errfile="$(mktemp)"
  if ! buffer_out="$(MSYS_NO_PATHCONV=1 docker compose exec -T ps-server node -e "$buffer_js" 2>"$buffer_errfile" </dev/null)"; then
    buffer_reason="$(tr -d '\r' < "$buffer_errfile" | grep -v -E '^(WARN\[[0-9]+\]|time="[^"]*" level=warning)' | sed -n '/[^[:space:]]/{p;q;}' || true)"
    buffer_out="error=docker compose exec into ps-server failed"
    if [[ -n "$buffer_reason" ]] && command -v python3 >/dev/null 2>&1; then
      buffer_reason="$(printf '%s\n' "${buffer_reason:0:300}" | python3 "${scripts_dir}/lib/redact.py" --filter --log 2>/dev/null | tr -d '\r' || true)"
      [[ -n "$buffer_reason" ]] && buffer_out+=": ${buffer_reason}"
    fi
  fi
  rm -f "$buffer_errfile"
  buffer_error="$(printf '%s\n' "$buffer_out" | sed -n 's/^error=//p')"
  if [[ -n "$buffer_error" ]]; then
    echo "  Could not read buffer: ${buffer_error}"
    buffer_state="error"
  else
    buffer_roots="$(printf '%s\n' "$buffer_out" | sed -n 's/^roots=//p')"
    buffer_count="$(printf '%s\n' "$buffer_out" | sed -n 's/^count=//p')"
    buffer_age="$(printf '%s\n' "$buffer_out" | sed -n 's/^oldest_age_hours=//p')"
    if [[ -z "$buffer_roots" ]]; then
      echo "  No enabled filesystem routing strategy - receive-back buffer not in use"
      buffer_state="not-in-use"
    else
      buffer_state="ok"
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

# ── --format json ──
# The values collected above, in the schema described in the header. Strings
# go through json_str (lib/alert-webhook.sh); a value that should be an
# integer and is not becomes null.
json_int() {  # <value> [signed]
  local v="$1" sign=""
  if [[ "${2:-}" == signed && "$v" == -?* ]]; then sign="-"; v="${v:1}"; fi
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then printf 'null'; return 0; fi
  v="${v#"${v%%[!0]*}"}"   # 007 is not a JSON number
  if [[ -z "$v" ]]; then v=0; sign=""; fi
  printf '%s%s' "$sign" "$v"
}
json_str_or_null() { if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi; }
json_bool() { if [[ "$1" == true ]]; then printf 'true'; else printf 'false'; fi; }

if [[ "$format" == json ]]; then
  j_services=""
  for ((i = 0; i < ${#svc_names[@]}; i++)); do
    if [[ "${svc_states[$i]}" == missing ]]; then
      j_health=null; j_restarts=null
    else
      j_health="$(json_str "${svc_healths[$i]}")"; j_restarts="$(json_int "${svc_restarts[$i]}")"
    fi
    j_services+="${j_services:+,}{\"service\":$(json_str "${svc_names[$i]}"),\"state\":$(json_str "${svc_states[$i]}"),\"health\":${j_health},\"restarts\":${j_restarts}}"
  done

  j_certificate=null
  if [[ -n "$host" ]]; then
    j_found=false; [[ -f "$crt" ]] && j_found=true
    j_certificate="{\"host\":$(json_str "$host"),\"path\":$(json_str "$crt"),\"found\":${j_found},\"notAfter\":$(json_str_or_null "$enddate"),\"daysLeft\":$(json_int "$days_left" signed)}"
  fi

  j_failures=null
  if [[ -n "$ps_server_cid" ]]; then
    j_counts=""
    for ((i = 0; i < ${#fail_keys[@]}; i++)); do
      j_counts+="${j_counts:+,}{\"key\":$(json_str "${fail_keys[$i]}"),\"label\":$(json_str "${fail_labels[$i]}"),\"count\":$(json_int "${fail_counts[$i]}")}"
    done
    j_failures="{\"window\":$(json_str "$log_window_desc"),\"counts\":[${j_counts}]}"
  fi

  j_stores=""
  for ((i = 0; i < ${#store_names[@]}; i++)); do
    if [[ "${store_volume[$i]}" == true ]]; then
      j_store_where="\"path\":null,\"exists\":null,\"size\":null"
    else
      if [[ "${store_inspectable[$i]}" == true ]]; then
        j_store_where="\"path\":$(json_str "${store_paths[$i]}"),\"exists\":$(json_bool "${store_exists[$i]}"),\"size\":$(json_str_or_null "${store_sizes[$i]}")"
      else
        j_store_where="\"path\":$(json_str "${store_paths[$i]}"),\"exists\":null,\"size\":null"
      fi
    fi
    j_stores+="${j_stores:+,}{\"name\":$(json_str "${store_names[$i]}"),${j_store_where},\"inTree\":$(json_bool "${store_in_tree[$i]}"),\"volume\":$(json_bool "${store_volume[$i]}"),\"inspectable\":$(json_bool "${store_inspectable[$i]}")}"
  done
  j_filesystems=""
  for ((i = 0; i < ${#fs_mounts[@]}; i++)); do
    j_filesystems+="${j_filesystems:+,}{\"mount\":$(json_str "${fs_mounts[$i]}"),\"path\":$(json_str "${fs_paths[$i]}"),\"usedPct\":$(json_int "${fs_pcts[$i]}")}"
  done

  j_buffer_count=null; j_buffer_age=null
  if [[ "$buffer_state" == ok ]]; then
    j_buffer_count="$(json_int "$buffer_count")"; j_buffer_age="$(json_int "$buffer_age")"
  fi
  j_buffer_error=null
  [[ "$buffer_state" == error ]] && j_buffer_error="$(json_str "$buffer_error")"
  j_buffer="{\"state\":$(json_str "$buffer_state"),\"count\":${j_buffer_count},\"oldestAgeHours\":${j_buffer_age},\"error\":${j_buffer_error}}"

  # As --alert posts them: samples one per line, empty lines dropped.
  j_alerts=""
  for ((i = 0; i < ${#alert_keys[@]}; i++)); do
    j_samples=""
    if [[ -n "${alert_samples[$i]}" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        j_samples+="${j_samples:+,}$(json_str "$line")"
      done <<< "${alert_samples[$i]}"
    fi
    j_alerts+="${j_alerts:+,}{\"key\":$(json_str "${alert_keys[$i]}"),\"message\":$(json_str "${alert_messages[$i]}"),\"samples\":[${j_samples}]}"
  done

  j_thresholds="{\"restartDelta\":$(json_int "$restart_delta_max"),\"certDays\":$(json_int "$cert_days_min"),\"diskPct\":$(json_int "$disk_pct_max"),\"bufferMax\":$(json_int "$buffer_max"),\"bufferMaxAgeHours\":$(json_int "$buffer_age_max"),\"failureMin\":$(json_int "$failure_min")}"

  printf '{"schema":1,"generated":%s,"host":%s,"thresholds":%s,"services":[%s],"certificate":%s,"failures":%s,"disk":{"stores":[%s],"filesystems":[%s]},"buffer":%s,"alerts":[%s]}\n' \
    "$(json_str "$run_started")" "$(json_str_or_null "$host")" "$j_thresholds" "$j_services" "$j_certificate" \
    "$j_failures" "$j_stores" "$j_filesystems" "$j_buffer" "$j_alerts" | utf8_clean >&3
  exit 0
fi

if [[ "$alert_mode" != true ]]; then
  echo "================================"
  echo "Report complete."
  exit 0
fi

# ── Alerts ──
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

if [[ -z "$webhook_url" ]]; then
  echo "${n_alerts} alert(s) fired. ALERT_WEBHOOK_URL is not set - nothing delivered (exit code 1 only)."
  exit 1
fi

summary="PadSign ALERT on ${host:-unknown host}: ${n_alerts} alert(s)"
text="$summary"
alerts_json=""
# The Teams card: bold title, one TextBlock per alert (key: message), its log
# samples in small monospace, and a subtle source/timestamp footer.
card_body=""
if [[ "$webhook_format" == teams ]]; then
  card_body="$(card_text_block "PadSign: ${n_alerts} alert(s) on ${host:-unknown host}" '"weight":"Bolder","size":"Medium"')"
fi
for i in "${!alert_keys[@]}"; do
  text+=$'\n'"- ${alert_keys[$i]}: ${alert_messages[$i]}"
  if [[ "$webhook_format" == teams ]]; then
    card_body+=",$(card_text_block "${alert_keys[$i]}: ${alert_messages[$i]}")"
  fi
  samples_json=""
  if [[ -n "${alert_samples[$i]}" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      text+=$'\n'"    ${line}"
      samples_json+="${samples_json:+,}$(json_str "$line")"
      if [[ "$webhook_format" == teams ]]; then
        card_body+=",$(card_text_block "$line" '"fontType":"Monospace","size":"Small","isSubtle":true,"spacing":"None"')"
      fi
    done <<< "${alert_samples[$i]}"
  fi
  alerts_json+="${alerts_json:+,}{\"key\":$(json_str "${alert_keys[$i]}"),\"message\":$(json_str "${alert_messages[$i]}"),\"samples\":[${samples_json}]}"
done
if [[ "$webhook_format" == teams ]]; then
  payload="$(teams_card_payload "${card_body},$(card_footer "$run_started")")"
else
  payload="{\"text\":$(json_str "$text"),\"source\":\"padsign-monitor\",\"host\":$(json_str "${host:-}"),\"generated\":$(json_str "$run_started"),\"alerts\":[${alerts_json}]}"
fi

# Only the scheme+host is ever printed - Slack/Teams webhook URLs embed their
# secret in the path.
webhook_target="$(webhook_url_target "$webhook_url")"
echo "Webhook: ${webhook_target}, format ${webhook_format} (${webhook_format_why})"
post_webhook "$webhook_url" "$webhook_auth" "$payload"
http_code="$webhook_http_code"
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
  echo "${n_alerts} alert(s) fired and delivered to ${webhook_target} (HTTP ${http_code})."
  if [[ "$webhook_format" == teams ]]; then teams_202_note; fi
  exit 1
fi
echo "ERROR: ${n_alerts} alert(s) fired but delivery to ${webhook_target} failed (HTTP ${http_code:-none})." >&2
if [[ -n "$webhook_curl_error" ]]; then echo "  ${webhook_curl_error}" >&2; fi
exit 3
