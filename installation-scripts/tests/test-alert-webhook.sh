#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for monitor-status.sh's alert webhook and its Disk usage section:
#
#   - ALERT_WEBHOOK_FORMAT: json (default, the payload unchanged byte for
#     byte) or teams (the Adaptive Card message a Microsoft Teams Workflows
#     webhook requires; the Workflows template fails on a plain {"text":...}
#     body but still answers 202), auto-selected for a Workflows URL host
#     (*.logic.azure.com, *.powerplatform.com); an explicit value always wins;
#   - escaping of quotes, backslashes, newlines, tabs and Latvian letters, and
#     a log sample cut at byte 400 never splitting a multi-byte character;
#   - --test-webhook: one harmless test message, the HTTP status, no stack;
#   - the webhook URL (a secret) and the auth header are never printed and
#     never on curl's command line;
#   - Disk usage reads the stores from the effective compose model, so an
#     overlay-managed checkout (storage mounted from outside it through
#     compose.overlay.yml) no longer reports them as "does not exist".
#
# Usage:
#   ./installation-scripts/tests/test-alert-webhook.sh
#
# Hermetic. `docker` is a stub for a two-service stack (ps-server running,
# nginx exited) whose ps-server log is a fixture; `docker compose config` /
# `version` go to the real docker when there is one (the compose-model cases
# also run via the file fallback, PADSIGN_DIGEST_GATE_NO_DOCKER=1), so no
# case can reach a daemon or start anything. The webhook receiver is a small
# python3 http.server on 127.0.0.1 with a random port that records every
# request; a `curl` wrapper resolves the fake Teams hosts to it (--resolve)
# and logs curl's argv. Runs the scripts from this checkout, with every
# --compose-dir and --state-dir in a throwaway directory.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
monitor="${src_root}/installation-scripts/monitor-status.sh"
lib="${src_root}/installation-scripts/lib/alert-webhook.sh"
for c in python3 curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done

# The caller's environment must not steer the script under test.
unset ALERT_WEBHOOK_URL ALERT_WEBHOOK_FORMAT ALERT_WEBHOOK_AUTH_HEADER \
  ALERT_RESTART_DELTA ALERT_CERT_DAYS ALERT_BUFFER_MAX ALERT_BUFFER_MAX_AGE_HOURS ALERT_FAILURE_MIN \
  COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER \
  http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export NO_PROXY='*' no_proxy='*'
# This machine's real disk use must not add a disk_pressure alert.
export ALERT_DISK_PCT=101

work="$(mktemp -d)"
rx_pid=""
cleanup() {
  [[ -n "$rx_pid" ]] && kill "$rx_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
sep=":"; command -v cygpath >/dev/null 2>&1 && sep=";"

real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi
real_curl="$(command -v curl)"

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 25 | sed 's/^/       | /'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }  # <text> <fixed string>

# ── stubs ───────────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log" STUB_LOGS="${work}/ps-server.log" REAL_DOCKER="$real_docker"
export CURL_ARGV_LOG="${work}/curl-argv.log" REAL_CURL="$real_curl"
: > "$STUB_LOG"; : > "$CURL_ARGV_LOG"

cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
# Stub docker for test-alert-webhook.sh.
printf '%s\n' "$*" >> "$STUB_LOG"
if [[ "${1:-}" == compose ]]; then
  if [[ " $* " == *" config "* && " $* " == *" --services "* ]]; then
    printf '%s\n' ps-server nginx; exit 0
  fi
  for a in "$@"; do
    if [[ "$a" == config || "$a" == version ]]; then
      [[ -n "${REAL_DOCKER:-}" ]] && exec "$REAL_DOCKER" "$@"
      exit 1
    fi
  done
  case "${2:-}" in
    ps) echo "stubcid-${*: -1}" ;;
    logs) cat "$STUB_LOGS" ;;
    exec) cat >/dev/null; printf 'roots=\ncount=0\noldest_age_hours=\n' ;;
  esac
  exit 0
fi
case "${1:-}" in
  inspect) if [[ "${*: -1}" == stubcid-nginx ]]; then echo "exited none 0"; else echo "running healthy 0"; fi ;;
  *) exit 1 ;;
esac
exit 0
STUB

teams_logic_host="prod-42.westeurope.logic.azure.com"
teams_pp_host="default0123abcd.4a.environment.api.powerplatform.com"
cat > "${bin}/curl" <<'STUB'
#!/usr/bin/env bash
# Logs curl's argv, and sends the fake Teams Workflows hosts to the receiver.
printf '%s\n' "$*" >> "$CURL_ARGV_LOG"
exec "$REAL_CURL" --resolve "${TEAMS_LOGIC_HOST}:${RX_PORT}:127.0.0.1" \
  --resolve "${TEAMS_PP_HOST}:${RX_PORT}:127.0.0.1" "$@"
STUB
chmod +x "${bin}/docker" "${bin}/curl"
export PATH="${bin}:${PATH}" TEAMS_LOGIC_HOST="$teams_logic_host" TEAMS_PP_HOST="$teams_pp_host"

# ── receiver ────────────────────────────────────────────────────────────────
rx="${work}/rx"
mkdir -p "$rx"
cat > "${work}/receiver.py" <<'PY'
import http.server, json, os, sys, threading

out = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        n = len([f for f in os.listdir(out) if f.endswith(".body")]) + 1
        with open(os.path.join(out, "req-%03d.body" % n), "wb") as fh:
            fh.write(body)
        meta = {"path": self.path, "host": self.headers.get("Host"),
                "content_type": self.headers.get("Content-Type"),
                "authorization": self.headers.get("Authorization")}
        with open(os.path.join(out, "req-%03d.meta" % n), "w") as fh:
            json.dump(meta, fh)
        # Teams Workflows answers 202 Accepted; /fail plays a rejecting receiver.
        self.send_response(400 if "/fail" in self.path else 202)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(out, "port.tmp"), "w") as fh:
    fh.write(str(srv.server_address[1]))
os.replace(os.path.join(out, "port.tmp"), os.path.join(out, "port"))
threading.Timer(900, os._exit, [0]).start()   # never outlive a stuck test
srv.serve_forever()
PY
python3 "$(native "${work}/receiver.py")" "$(native "$rx")" &
rx_pid=$!
for _ in $(seq 1 100); do [[ -s "${rx}/port" ]] && break; sleep 0.1; done
if [[ ! -s "${rx}/port" ]]; then echo "ERROR: the local webhook receiver did not start" >&2; exit 2; fi
port="$(cat "${rx}/port")"
export RX_PORT="$port"

cat > "${work}/check.py" <<'PY'
import json, re, sys

def fail(msg):
    print(msg)
    sys.exit(1)

def load(path):
    raw = open(path, "rb").read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail("body is not valid UTF-8: %s" % exc)
    try:
        return raw, json.loads(text)
    except ValueError as exc:
        fail("body is not valid JSON: %s\n%r" % (exc, raw[:300]))

def expected_samples(path):
    """Each matching log line, cut at byte 400 without splitting a character."""
    out = []
    for line in open(path, "rb").read().split(b"\n"):
        if not line:
            continue
        b = line[:400]
        while True:
            try:
                out.append(b.decode("utf-8"))
                break
            except UnicodeDecodeError:
                b = b[:-1]
    return sorted(out)

def card(d):
    if d.get("type") != "message":
        fail("top-level type is %r, not 'message'" % d.get("type"))
    atts = d.get("attachments")
    if not isinstance(atts, list) or len(atts) != 1:
        fail("attachments is not a one-element list: %r" % atts)
    a = atts[0]
    if a.get("contentType") != "application/vnd.microsoft.card.adaptive":
        fail("attachments[0].contentType is %r" % a.get("contentType"))
    if "contentUrl" not in a or a["contentUrl"] is not None:
        fail("attachments[0].contentUrl is not null")
    c = a.get("content") or {}
    want = {"$schema": "http://adaptivecards.io/schemas/adaptive-card.json", "type": "AdaptiveCard", "version": "1.4"}
    for k, v in want.items():
        if c.get(k) != v:
            fail("content.%s is %r, not %r" % (k, c.get(k), v))
    body = c.get("body")
    if not isinstance(body, list) or len(body) < 2:
        fail("content.body is not a list of blocks: %r" % body)
    for b in body:
        if b.get("type") != "TextBlock" or b.get("wrap") is not True or not isinstance(b.get("text"), str):
            fail("not a wrapped TextBlock: %r" % b)
    if body[0].get("weight") != "Bolder":
        fail("the title block is not bold: %r" % body[0])
    foot = body[-1]
    if foot.get("size") != "Small" or foot.get("isSubtle") is not True or "padsign-monitor" not in foot["text"] \
            or not re.search(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", foot["text"]):
        fail("the last block is not the small subtle source/timestamp footer: %r" % foot)
    return body

def main(cmd, *a):
    if cmd == "json-exact":                     # <body> <host> <keys,csv> <samples-file>
        raw, d = load(a[0])
        if list(d) != ["text", "source", "host", "generated", "alerts"]:
            fail("top-level keys/order changed: %r" % list(d))
        alerts = d["alerts"]
        rebuilt = {"text": d["text"], "source": "padsign-monitor", "host": a[1], "generated": d["generated"],
                   "alerts": [{"key": x["key"], "message": x["message"], "samples": x["samples"]} for x in alerts]}
        if json.dumps(rebuilt, ensure_ascii=False, separators=(",", ":")).encode("utf-8") != raw:
            fail("payload is not byte-identical to the documented json format")
        text = "PadSign ALERT on %s: %d alert(s)" % (a[1], len(alerts))
        for x in alerts:
            text += "\n- %s: %s" % (x["key"], x["message"])
            text += "".join("\n    " + s for s in x["samples"])
        if d["text"] != text:
            fail("text is not the summary + '- key: message' + indented samples:\n%r" % d["text"])
        keys = [x["key"] for x in alerts]
        if keys != a[2].split(","):
            fail("alert keys %r, expected %r" % (keys, a[2].split(",")))
        got = sorted(s for x in alerts for s in x["samples"])
        if got != expected_samples(a[3]):
            fail("samples differ from the log lines:\n%r\n%r" % (got, expected_samples(a[3])))
    elif cmd == "teams-alert":                  # <body> <host> <keys,csv> <samples-file> [messages-from-json-body]
        raw, d = load(a[0])
        body = card(d)
        keys = a[2].split(",")
        if body[0]["text"] != "PadSign: %d alert(s) on %s" % (len(keys), a[1]):
            fail("title is %r" % body[0]["text"])
        for k in keys:
            if not any(b["text"].startswith(k + ": ") for b in body[1:-1]):
                fail("no '%s: <message>' block" % k)
        samples = sorted(b["text"] for b in body if b.get("fontType") == "Monospace")
        if samples != expected_samples(a[3]):
            fail("sample blocks differ from the log lines:\n%r\n%r" % (samples, expected_samples(a[3])))
        if len(a) > 4:
            _, j = load(a[4])
            want = ["%s: %s" % (x["key"], x["message"]) for x in j["alerts"]]
            got = [b["text"] for b in body[1:-1] if b.get("fontType") != "Monospace"]
            if got != want:
                fail("alert blocks %r differ from the json alerts %r" % (got, want))
    elif cmd == "json-test":                    # <body> <host>
        raw, d = load(a[0])
        want = {"text": "PadSign monitor test from %s - webhook works" % a[1], "source": "padsign-monitor",
                "host": a[1], "generated": d.get("generated"), "test": True, "alerts": []}
        if d != want or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d.get("generated") or ""):
            fail("test payload is %r" % d)
    elif cmd == "teams-test":                   # <body> <host>
        raw, d = load(a[0])
        body = card(d)
        if body[0]["text"] != "PadSign monitor test from %s - webhook works" % a[1]:
            fail("title is %r" % body[0]["text"])
    elif cmd == "meta":                         # <meta> <field>: prints the recorded value
        print(json.load(open(a[0])).get(a[1]) or "")
    elif cmd == "unit-escape":                  # <json_str output> <card_text_block output>
        want = 'say "hi" C:\\in\\x\nline2\tTab ā č ē ģ ī ķ ļ ņ š ū ž'
        raw, s = load(a[0])
        if s != want:
            fail("json_str round trip: %r != %r" % (s, want))
        raw, b = load(a[1])
        if b != {"type": "TextBlock", "text": want, "wrap": True, "weight": "Bolder"}:
            fail("card_text_block: %r" % b)
    else:
        fail("unknown check %r" % cmd)

main(*sys.argv[1:])
PY
check() { python3 "$(native "${work}/check.py")" "$@"; }  # args are paths or ASCII
nat() { native "$1"; }
# A recorded request's path / Host / Content-Type / Authorization. Compared
# here, not passed to python: Git Bash rewrites an argument like /hook/...
meta() { check meta "$(nat "$1")" "$2" | tr -d '\r'; }

# ── fixtures ────────────────────────────────────────────────────────────────
host="pf.example.test"
deploy="${work}/deploy"
mkdir -p "${deploy}/nginx"
printf 'server {\n  listen 443 ssl;\n  server_name %s;\n}\n' "$host" > "${deploy}/nginx/nginx.conf"

# Three failure lines ps-server really writes, with quotes, backslashes, a
# tab and Latvian letters in them, and an archive line whose byte 400 is the
# first byte of a two-byte letter.
webhook_line='ps-server  | [documentRouting:webhook] PERMANENT FAILURE after retries {"docid":"doc-7","url":"https://erp.example.test/in?a=1&b=\"q\"","status":500,"file":"C:\\in\\Līgums Nr.7.pdf"} ā č ē ģ ī ķ ļ ņ š ū ž'
stamp_line="ps-server  | [stamp] upstream unavailable, continuing without stamp"$'\t'"Ā Č Ē Ģ Ī Ķ Ļ Ņ Š Ū Ž"
archive_prefix='ps-server  | Archive download failed: '
archive_line="${archive_prefix}$(printf '%*s' $((399 - ${#archive_prefix})) '' | tr ' ' 'x')žurnāls (the byte-400 letter)"
printf '%s\n' "ps-server  | PadSign Server listening on port 3001" "$archive_line" "$stamp_line" \
  "ps-server  | GET /api/latestUser 200" "$webhook_line" > "$STUB_LOGS"
printf '%s\n' "$archive_line" "$stamp_line" "$webhook_line" > "${work}/samples.txt"
alert_keys="service_down,certificate_risk,archive_failure,stamping_failure,routing_webhook_permanent_failure"

secret_q="api-version=2016-06-01&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=S3CR3T-sig"
url_local="http://127.0.0.1:${port}/hook/wfpath-S3CR3T?${secret_q}"
url_logic="http://${teams_logic_host}:${port}/workflows/wfpath-S3CR3T/triggers/manual/paths/invoke?${secret_q}"
url_pp="http://${teams_pp_host}:${port}/powerautomate/automations/direct/workflows/wfpath-S3CR3T/triggers/manual/paths/invoke?${secret_q}"

all_out="${work}/all-output.log"
: > "$all_out"
run_n=0
rc=0
out=""
monitor_run() {  # <.env content> [monitor args...]; sets rc and out, clears the receiver
  run_n=$((run_n + 1))
  printf '%s' "$1" > "${deploy}/.env"; shift
  rm -f "${rx}"/req-*
  rc=0
  out="$(bash "$monitor" --compose-dir "$deploy" --state-dir "${work}/state-${run_n}" "$@" 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$all_out"
}
nreq() { find "$rx" -name 'req-*.body' | wc -l | tr -d ' '; }
last_body() { printf '%s' "${rx}/req-$(printf '%03d' "$(nreq)").body"; }
last_meta() { printf '%s' "${rx}/req-$(printf '%03d' "$(nreq)").meta"; }

echo "== unit: format detection, URL target, escaping =="

(
  . "$lib"
  bad=""
  while read -r want url; do
    [[ -z "$want" ]] && continue
    got="$(detect_webhook_format "$url")"
    [[ "$got" == "$want" ]] || bad+="${url} -> ${got} (expected ${want})"$'\n'
  done <<EOF
teams https://prod-42.westeurope.logic.azure.com:443/workflows/0123/triggers/manual/paths/invoke?${secret_q}
teams https://${teams_pp_host}:443/powerautomate/automations/direct/workflows/0123/triggers/manual/paths/invoke?${secret_q}
teams HTTPS://PROD-01.NorthEurope.Logic.Azure.com/workflows/0123
teams https://user:pw@prod-01.northeurope.logic.azure.com/workflows/0123
teams https://prod-01.northeurope.logic.azure.com./workflows/0123
teams https://env.api.powerplatform.com/workflows/0123
json https://hooks.slack.com/services/T000/B000/XXXX
json https://acme.webhook.office.com/webhookb2/0123/IncomingWebhook/4567/89
json https://logic.azure.com.evil.example/workflows/0123
json https://hooks.example.test/in?next=https://prod-1.x.logic.azure.com/
json http://127.0.0.1:${port}/hook
EOF
  [[ -z "$bad" ]] && echo OK || printf '%s' "$bad"
) > "${work}/unit.out" 2>&1
if [[ "$(cat "${work}/unit.out")" == OK ]]; then
  ok_case "detect_webhook_format: Logic Apps and Power Platform hosts -> teams (case, port, user@, trailing dot); Slack, legacy Office 365 connector, look-alikes, query-only -> json"
else
  fail_case "detect_webhook_format" "$(cat "${work}/unit.out")"
fi

(
  . "$lib"
  bad=""
  t() { local got; got="$(webhook_url_target "$1")"; [[ "$got" == "$2" ]] || bad+="$1 -> ${got} (expected $2)"$'\n'; }
  t "https://prod-42.westeurope.logic.azure.com:443/workflows/S3CR3T?sig=S3CR3T" "https://prod-42.westeurope.logic.azure.com:443"
  t "https://user:S3CR3T@hooks.example.test/in" "https://hooks.example.test"
  t "https://hooks.example.test?sig=S3CR3T" "https://hooks.example.test"
  t "hooks.example.test/in/S3CR3T" "<URL without a scheme>"
  [[ -z "$bad" ]] && echo OK || printf '%s' "$bad"
) > "${work}/unit.out" 2>&1
if [[ "$(cat "${work}/unit.out")" == OK ]]; then
  ok_case "webhook_url_target: scheme and host[:port] only - no path, query or user:password@; a URL without a scheme prints a placeholder"
else
  fail_case "webhook_url_target" "$(cat "${work}/unit.out")"
fi

(
  . "$lib"
  s=$'say "hi" C:\\in\\x\nline2\tTab\r\x01 ā č ē ģ ī ķ ļ ņ š ū ž'
  json_str "$s" > "${work}/unit-str.json"
  card_text_block "$s" '"weight":"Bolder"' > "${work}/unit-block.json"
)
if msg="$(check unit-escape "$(nat "${work}/unit-str.json")" "$(nat "${work}/unit-block.json")")"; then
  ok_case "json_str / card_text_block: quotes, backslashes, newline, tab and 'ā č ē ģ ī ķ ļ ņ š ū ž' round-trip as valid UTF-8 JSON (CR and control bytes dropped)"
else
  fail_case "json_str / card_text_block escaping" "$msg"
fi

# resolve_webhook_config: precedence, auto-detection, validation.
cfg_dir="${work}/cfg"
mkdir -p "$cfg_dir"
resolve() {  # <.env content> [VAR=value...]: prints "<rc> <format> | <why> | <url>"
  printf '%s' "$1" > "${cfg_dir}/.env"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    . "$lib"
    r=0; resolve_webhook_config "$cfg_dir" 2>/dev/null || r=$?
    printf '%s %s | %s | %s\n' "$r" "${webhook_format:-}" "${webhook_format_why:-}" "${webhook_url:-}" )
}
bad=""
got="$(resolve "ALERT_WEBHOOK_URL='${url_logic}'"$'\n')"
[[ "$got" == "0 teams | auto-detected"*"| ${url_logic}" ]] || bad+="auto-detect from .env: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=${url_logic}"$'\n'"ALERT_WEBHOOK_FORMAT=json"$'\n')"
[[ "$got" == "0 json | set by ALERT_WEBHOOK_FORMAT; NOTE: the URL looks like a Teams Workflows URL"* ]] || bad+="explicit json over a Teams URL: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T/B/X"$'\n'"ALERT_WEBHOOK_FORMAT=json"$'\n' ALERT_WEBHOOK_FORMAT=teams)"
[[ "$got" == "0 teams | set by ALERT_WEBHOOK_FORMAT |"* ]] || bad+="environment over .env: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T/B/X"$'\n' "ALERT_WEBHOOK_URL=${url_pp}")"
[[ "$got" == "0 teams | auto-detected"*"| ${url_pp}" ]] || bad+="URL from the environment over .env: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=\"https://hooks.slack.com/services/T/B/X\""$'\r\n'"ALERT_WEBHOOK_FORMAT=Teams"$'\r\n')"
[[ "$got" == "0 teams | set by ALERT_WEBHOOK_FORMAT | https://hooks.slack.com/services/T/B/X" ]] || bad+="CRLF .env, mixed case: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T/B/X"$'\n')"
[[ "$got" == "0 json | default |"* ]] || bad+="no format, non-Teams URL: ${got}"$'\n'
got="$(resolve "ALERT_WEBHOOK_URL=${url_logic}"$'\n'"ALERT_WEBHOOK_FORMAT=adaptivecard"$'\n')"
[[ "$got" == "1 "* ]] || bad+="unsupported value accepted: ${got}"$'\n'
if [[ -z "$bad" ]]; then
  ok_case "resolve_webhook_config: environment wins over .env (URL and format), explicit value wins over auto-detection (with a NOTE), CRLF/quotes/case tolerated, unsupported value refused"
else
  fail_case "resolve_webhook_config" "$bad"
fi

echo ""
echo "== --alert delivery =="

# json: the default, unchanged.
monitor_run "ALERT_WEBHOOK_URL='${url_local}'"$'\n' --alert --host "$host"
json_body="${work}/json-alert.body"
if [[ "$rc" == 1 && "$(nreq)" == 1 ]] && cp "$(last_body)" "$json_body" \
   && msg="$(check json-exact "$(nat "$json_body")" "$host" "$alert_keys" "$(nat "${work}/samples.txt")")"; then
  ok_case "json (default): exit 1, one POST, byte-identical to the documented format (keys, order, separators, text), samples intact"
else
  fail_case "json (default) payload (rc=${rc}, requests=$(nreq))" "${msg:-}"$'\n'"$out"
fi
if has "$out" "Webhook: http://127.0.0.1:${port}, format json (default)" \
   && has "$out" "5 alert(s) fired and delivered to http://127.0.0.1:${port} (HTTP 202)." \
   && [[ "$(meta "$(last_meta)" content_type)" == application/json ]]; then
  ok_case "json (default): HTTP 202 counts as delivered; Content-Type application/json; prints scheme+host only"
else
  fail_case "json (default) delivery output" "$out"
fi
long_ok=false
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); s=[x for a in d["alerts"] if a["key"]=="archive_failure" for x in a["samples"]]; sys.exit(0 if len(s)==1 and len(s[0].encode())==399 and s[0].endswith("x") else 1)' "$(nat "$json_body")"; then
  long_ok=true
fi
if [[ "$long_ok" == true ]]; then
  ok_case "a sample cut at byte 400 drops the half of the letter it split (399 bytes, valid UTF-8)"
else
  fail_case "a sample cut at byte 400 split a multi-byte letter"
fi

# teams, explicit in the environment, over a .env that says json.
export ALERT_WEBHOOK_FORMAT=teams
monitor_run "ALERT_WEBHOOK_URL='${url_local}'"$'\n'"ALERT_WEBHOOK_FORMAT=json"$'\n' --alert --host "$host"
unset ALERT_WEBHOOK_FORMAT
if [[ "$rc" == 1 && "$(nreq)" == 1 ]] \
   && msg="$(check teams-alert "$(nat "$(last_body)")" "$host" "$alert_keys" "$(nat "${work}/samples.txt")" "$(nat "$json_body")")"; then
  ok_case "teams (ALERT_WEBHOOK_FORMAT in the environment, over .env's json): Adaptive Card message - attachments[0].contentType, contentUrl null, v1.4, bold title, one 'key: message' TextBlock per alert, samples, subtle footer"
else
  fail_case "teams payload (rc=${rc}, requests=$(nreq))" "${msg:-}"$'\n'"$out"
fi
if has "$out" "format teams (set by ALERT_WEBHOOK_FORMAT)" && has "$out" "Teams Workflows answers 202 before its flow runs"; then
  ok_case "teams: says which format it used and that a 202 does not prove the card was posted"
else
  fail_case "teams: format / 202 note missing from the output" "$out"
fi

# Auto-detection: a Logic Apps Workflows host, resolved to the receiver.
monitor_run "ALERT_WEBHOOK_URL='${url_logic}'"$'\n' --alert --host "$host"
if [[ "$rc" == 1 && "$(nreq)" == 1 ]] \
   && check teams-alert "$(nat "$(last_body)")" "$host" "$alert_keys" "$(nat "${work}/samples.txt")" >/dev/null \
   && [[ "$(meta "$(last_meta)" host)" == "${teams_logic_host}:${port}" ]] \
   && has "$out" "format teams (auto-detected: the URL host is a Microsoft Teams Workflows one"; then
  ok_case "auto-detect: ALERT_WEBHOOK_FORMAT unset + a *.logic.azure.com URL -> teams card, and the output says it was auto-detected"
else
  fail_case "auto-detect by host (rc=${rc}, requests=$(nreq))" "$out"
fi

# An explicit json wins over auto-detection.
monitor_run "ALERT_WEBHOOK_URL='${url_logic}'"$'\n'"ALERT_WEBHOOK_FORMAT=json"$'\n' --alert --host "$host"
if [[ "$rc" == 1 && "$(nreq)" == 1 ]] \
   && check json-exact "$(nat "$(last_body)")" "$host" "$alert_keys" "$(nat "${work}/samples.txt")" >/dev/null \
   && has "$out" "NOTE: the URL looks like a Teams Workflows URL"; then
  ok_case "explicit ALERT_WEBHOOK_FORMAT=json wins over a Teams URL (json sent, with a NOTE)"
else
  fail_case "explicit json over a Teams URL (rc=${rc}, requests=$(nreq))" "$out"
fi

# Auth header: delivered, never on curl's command line.
: > "$CURL_ARGV_LOG"
monitor_run "ALERT_WEBHOOK_URL='${url_local}'"$'\n'"ALERT_WEBHOOK_AUTH_HEADER='Authorization: Bearer stub-bearer-T0KEN'"$'\n' --alert --host "$host"
if [[ "$rc" == 1 ]] && [[ "$(meta "$(last_meta)" authorization)" == "Bearer stub-bearer-T0KEN" ]] \
   && [[ "$(meta "$(last_meta)" path)" == "/hook/wfpath-S3CR3T?${secret_q}" ]] \
   && [[ -s "$CURL_ARGV_LOG" ]] && ! grep -qE 'S3CR3T|T0KEN' "$CURL_ARGV_LOG"; then
  ok_case "ALERT_WEBHOOK_AUTH_HEADER is sent; the URL, its query and the header reach curl on stdin, never on its command line"
else
  fail_case "auth header / curl argv (rc=${rc})" "$(cat "$CURL_ARGV_LOG")"$'\n'"$out"
fi

# Unsupported format: refused before anything is checked or sent.
: > "$STUB_LOG"
monitor_run "ALERT_WEBHOOK_URL='${url_local}'"$'\n'"ALERT_WEBHOOK_FORMAT=adaptivecard"$'\n' --alert --host "$host"
if [[ "$rc" == 2 && "$(nreq)" == 0 && ! -s "$STUB_LOG" ]] && has "$out" "ALERT_WEBHOOK_FORMAT='adaptivecard' is not supported"; then
  ok_case "unsupported ALERT_WEBHOOK_FORMAT: exit 2 before any check, nothing sent"
else
  fail_case "unsupported format (rc=${rc}, requests=$(nreq))" "$out"
fi

# A rejecting receiver, and one that is not there.
monitor_run "ALERT_WEBHOOK_URL=http://127.0.0.1:${port}/fail/wfpath-S3CR3T?${secret_q}"$'\n' --alert --host "$host"
if [[ "$rc" == 3 ]] && has "$out" "delivery to http://127.0.0.1:${port} failed (HTTP 400)"; then
  ok_case "non-2xx (400): exit 3, 'delivery ... failed (HTTP 400)'"
else
  fail_case "non-2xx delivery (rc=${rc})" "$out"
fi
monitor_run "ALERT_WEBHOOK_URL=http://127.0.0.1:1/wfpath-S3CR3T?${secret_q}"$'\n' --alert --host "$host"
if [[ "$rc" == 3 ]] && has "$out" "delivery to http://127.0.0.1:1 failed (HTTP 000)"; then
  ok_case "unreachable receiver: exit 3, HTTP 000, curl's error shown without the URL"
else
  fail_case "unreachable receiver (rc=${rc})" "$out"
fi

echo ""
echo "== --test-webhook =="

: > "$STUB_LOG"
monitor_run "ALERT_WEBHOOK_URL='${url_local}'"$'\n' --test-webhook --host "$host"
if [[ "$rc" == 0 && "$(nreq)" == 1 ]] && check json-test "$(nat "$(last_body)")" "$host" >/dev/null \
   && has "$out" "Result:    HTTP 202 - delivered to http://127.0.0.1:${port}." && [[ ! -s "$STUB_LOG" ]]; then
  ok_case "--test-webhook (json): exit 0, one POST '{\"text\":\"PadSign monitor test from ${host} - webhook works\",...,\"test\":true,\"alerts\":[]}', HTTP status printed, docker never called"
else
  fail_case "--test-webhook json (rc=${rc}, requests=$(nreq))" "$out"$'\n'"docker calls: $(cat "$STUB_LOG")"
fi

monitor_run "ALERT_WEBHOOK_URL='${url_pp}'"$'\n' --test-webhook
if [[ "$rc" == 0 && "$(nreq)" == 1 ]] && check teams-test "$(nat "$(last_body)")" "$host" >/dev/null \
   && has "$out" "Format:    teams (auto-detected" && has "$out" "Teams Workflows answers 202" && has "$out" "Message:   PadSign monitor test from ${host} - webhook works"; then
  ok_case "--test-webhook (a *.powerplatform.com URL, host taken from nginx.conf): teams card titled 'PadSign monitor test from ${host} - webhook works'"
else
  fail_case "--test-webhook teams (rc=${rc}, requests=$(nreq))" "$out"
fi

monitor_run "" --test-webhook
if [[ "$rc" == 2 && "$(nreq)" == 0 ]] && has "$out" "ALERT_WEBHOOK_URL is not set"; then
  ok_case "--test-webhook without ALERT_WEBHOOK_URL: exit 2, nothing sent"
else
  fail_case "--test-webhook, no URL (rc=${rc})" "$out"
fi

monitor_run "ALERT_WEBHOOK_URL=http://127.0.0.1:${port}/fail/wfpath-S3CR3T?${secret_q}"$'\n' --test-webhook
if [[ "$rc" == 3 ]] && has "$out" "ERROR: HTTP 400 - the test message was not delivered to http://127.0.0.1:${port}."; then
  ok_case "--test-webhook against a rejecting receiver: exit 3 with the HTTP status"
else
  fail_case "--test-webhook, rejected (rc=${rc})" "$out"
fi

echo ""
echo "== the URL is never printed =="
if [[ "$run_n" -ge 10 ]] && ! grep -qE 'S3CR3T|T0KEN|/hook/|/workflows/|/fail/' "$all_out"; then
  ok_case "no path, query or auth token in any of the ${run_n} runs' output (stdout and stderr)"
else
  fail_case "webhook URL or token printed" "$(grep -nE 'S3CR3T|T0KEN|/hook/|/workflows/|/fail/' "$all_out")"
fi

echo ""
echo "== Disk usage: the stores from the effective compose model =="

compose_base() {  # <dir>: a release-style docker-compose.yml with in-tree stores
  mkdir -p "$1/nginx"
  printf 'server {\n  server_name %s;\n}\n' "$host" > "$1/nginx/nginx.conf"
  cat > "$1/docker-compose.yml" <<'EOF'
services:
  ps-server:
    image: busybox:1.36
    volumes:
      - ./config/config.js:/usr/src/app/config.js
      - ./signed-output:/signed-output
  dmss-archive-services-fallback:
    image: busybox:1.36
    volumes:
      - ./docs:/docs
EOF
}
report() {  # <compose dir> [VAR=value]: report-mode output
  ( [[ -n "${2:-}" ]] && export "${2?}"
    bash "$monitor" --compose-dir "$1" --host "$host" 2>&1 )
}

plain="${work}/disk-plain"
compose_base "$plain"
mkdir -p "$plain/signed-output/acme" "$plain/docs"
printf 'pdf' > "$plain/signed-output/acme/a.pdf"
out="$(report "$plain")"
if has "$out" "${plain}/signed-output: " && has "$out" "${plain}/docs: " && ! has "$out" "does not exist" \
   && ! has "$out" "outside the checkout"; then
  ok_case "plain checkout: ./signed-output and ./docs sized as before"
else
  fail_case "plain checkout disk usage" "$(sed -n '/== Disk usage ==/,/^$/p' <<< "$out")"
fi

ovl="${work}/disk-overlay"
ovl_cfg="${work}/overlay-cfg"
ovl_store="${work}/documents-home"
compose_base "$ovl"
mkdir -p "$ovl_cfg" "$ovl_store/signed-output/acme" "$ovl_store/docs"
printf 'pdf' > "$ovl_store/signed-output/acme/a.pdf"
cat > "${ovl_cfg}/compose.overlay.yml" <<EOF
services:
  ps-server:
    volumes:
      - "$(native "$ovl_store")/signed-output:/signed-output"
  dmss-archive-services-fallback:
    volumes:
      - type: bind
        source: "$(native "$ovl_store")/docs"
        target: /docs
EOF
printf 'COMPOSE_FILE=docker-compose.yml%s%s\n' "$sep" "$(native "${ovl_cfg}/compose.overlay.yml")" > "${ovl}/.env"
for how in docker files; do
  [[ "$how" == docker && -z "$real_docker" ]] && { printf '  SKIP overlay-managed checkout via docker compose config (no docker compose here)\n'; continue; }
  flag=""; [[ "$how" == files ]] && flag="PADSIGN_DIGEST_GATE_NO_DOCKER=1"
  out="$(report "$ovl" $flag)"
  section="$(sed -n '/== Disk usage ==/,/^$/p' <<< "$out")"
  if has "$section" "documents-home/signed-output: " && has "$section" "(signed-output, mounted from outside the checkout)" \
     && has "$section" "documents-home/docs: " && has "$section" "(docs, mounted from outside the checkout)" \
     && ! has "$section" "does not exist"; then
    ok_case "overlay-managed checkout (${how}): both stores sized where compose.overlay.yml mounts them, no 'does not exist'"
  else
    fail_case "overlay-managed checkout disk usage (${how})" "$section"
  fi
done

vol="${work}/disk-volume"
compose_base "$vol"
cat > "$vol/docker-compose.yml" <<'EOF'
services:
  ps-server:
    image: busybox:1.36
    volumes:
      - signed_output_data:/signed-output
  dmss-archive-services-fallback:
    image: busybox:1.36
    volumes:
      - ./docs:/docs
volumes:
  signed_output_data:
EOF
mkdir -p "$vol/docs"
out="$(report "$vol" PADSIGN_DIGEST_GATE_NO_DOCKER=1)"
section="$(sed -n '/== Disk usage ==/,/^$/p' <<< "$out")"
if has "$section" "signed-output: a named Docker volume" && has "$section" "${vol}/docs: " && ! has "$section" "does not exist"; then
  ok_case "a named volume at /signed-output is reported as one, not as a missing directory"
else
  fail_case "named volume disk usage" "$section"
fi

nomodel="${work}/disk-nomodel"
mkdir -p "$nomodel/nginx" "$nomodel/signed-output"
printf 'server {\n  server_name %s;\n}\n' "$host" > "$nomodel/nginx/nginx.conf"
out="$(report "$nomodel" PADSIGN_DIGEST_GATE_NO_DOCKER=1)"
section="$(sed -n '/== Disk usage ==/,/^$/p' <<< "$out")"
if has "$section" "${nomodel}/signed-output: " && has "$section" "${nomodel}/docs: does not exist"; then
  ok_case "no readable compose model: falls back to the checkout's signed-output/ and docs/"
else
  fail_case "fallback to the checkout paths" "$section"
fi

echo ""
echo "== lint =="
lint=""
for f in "$monitor" "$lib"; do
  bash -n "$f" 2>&1 || lint+="${f}"$'\n'
done
if [[ -z "$lint" ]]; then
  ok_case "bash -n monitor-status.sh lib/alert-webhook.sh"
else
  fail_case "bash -n" "$lint"
fi

echo ""
echo "${pass} passed, ${failed} failed"
[[ "$failed" -eq 0 ]]
