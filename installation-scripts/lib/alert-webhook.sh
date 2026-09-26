# shellcheck shell=bash
# ============================================================================
# Alert webhook helpers for monitor-status.sh (documentation/40-03).
#
# Sourced, never run. Defines functions only:
#
#   json_str <s>                   JSON string literal (quotes included)
#   webhook_url_target <url>       scheme://host[:port], the only part of the
#                                  URL that may be printed (the rest is a secret)
#   webhook_url_host <url>         the host alone, lowercased, for detection
#   detect_webhook_format <url>    "teams" for a Teams Workflows URL, else "json"
#   dotenv_val <file> <key>        a KEY=value from a .env file
#   resolve_webhook_config <dir>   sets webhook_url / webhook_auth /
#                                  webhook_format / webhook_format_why from the
#                                  environment, then <dir>/.env; returns 1 on an
#                                  unsupported ALERT_WEBHOOK_FORMAT
#   card_text_block <text> [props] one Adaptive Card TextBlock (wrap on)
#   card_footer <generated>        the small, subtle source/timestamp line
#   teams_card_payload <blocks>    the message wrapper the Teams Workflows
#                                  template "Send webhook alerts to a channel"
#                                  requires around a card body
#   post_webhook <url> <auth> <payload>
#                                  POSTs the payload; sets webhook_http_code
#                                  (000 when nothing answered) and
#                                  webhook_curl_error (URL redacted)
#
# Formats (ALERT_WEBHOOK_FORMAT):
#   json   {"text":..., "source":..., "host":..., "generated":..., "alerts":[...]}
#          Slack incoming webhooks and generic HTTP receivers. The default.
#   teams  {"type":"message","attachments":[{Adaptive Card}]}. Teams webhooks
#          are made with the Workflows app now (the Office 365 "Incoming
#          Webhook" connector is retired), and its template fails on a body
#          without attachments while still answering 202 Accepted.
# ============================================================================

json_str() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"; s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

webhook_url_target() {
  # Never the path or query (the secret), never user:password@.
  if [[ "$1" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*) ]]; then
    printf '%s://%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]##*@}"
  else
    printf '%s' "<URL without a scheme>"
  fi
}

webhook_url_host() {
  local h="$1"
  [[ "$h" == *://* ]] && h="${h#*://}"
  h="${h%%[/?#]*}"
  h="${h##*@}"
  if [[ "$h" == \[* ]]; then
    h="${h%%]*}]"
  else
    h="${h%%:*}"
  fi
  h="${h%.}"
  printf '%s' "${h,,}"
}

# Teams Workflows webhook URLs: the classic Logic Apps host
# (prod-NN.<region>.logic.azure.com) and the Power Platform one
# (<env>.environment.api.powerplatform.com).
detect_webhook_format() {
  local h
  h="$(webhook_url_host "$1")"
  if [[ "$h" == *.logic.azure.com || "$h" == *.powerplatform.com* ]]; then
    echo teams
  else
    echo json
  fi
}

# The .env reader monitor-status.sh has always used: last KEY= line wins, one
# pair of surrounding quotes is removed. A CR from a file edited on Windows is
# dropped too.
dotenv_val() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" | tail -1 | sed -E 's/\r$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

resolve_webhook_config() {  # <compose-dir>
  local env_file="${1}/.env" raw fmt detected
  webhook_url="${ALERT_WEBHOOK_URL:-}"
  webhook_auth="${ALERT_WEBHOOK_AUTH_HEADER:-}"
  raw="${ALERT_WEBHOOK_FORMAT:-}"
  if [[ -f "$env_file" ]]; then
    if [[ -z "$webhook_url" ]]; then webhook_url="$(dotenv_val "$env_file" ALERT_WEBHOOK_URL)"; fi
    if [[ -z "$webhook_auth" ]]; then webhook_auth="$(dotenv_val "$env_file" ALERT_WEBHOOK_AUTH_HEADER)"; fi
    if [[ -z "$raw" ]]; then raw="$(dotenv_val "$env_file" ALERT_WEBHOOK_FORMAT)"; fi
  fi
  fmt="${raw//[[:space:]]/}"
  fmt="${fmt,,}"
  detected="json"
  if [[ -n "$webhook_url" ]]; then detected="$(detect_webhook_format "$webhook_url")"; fi

  if [[ -n "$fmt" ]]; then
    case "$fmt" in
      json|teams) ;;
      *)
        echo "ERROR: ALERT_WEBHOOK_FORMAT='${raw}' is not supported. Use json (Slack, generic receivers) or teams (Microsoft Teams Workflows)." >&2
        return 1 ;;
    esac
    webhook_format="$fmt"
    webhook_format_why="set by ALERT_WEBHOOK_FORMAT"
    if [[ "$fmt" == json && "$detected" == teams ]]; then
      webhook_format_why+="; NOTE: the URL looks like a Teams Workflows URL, which accepts only ALERT_WEBHOOK_FORMAT=teams"
    fi
  elif [[ "$detected" == teams ]]; then
    webhook_format="teams"
    webhook_format_why="auto-detected: the URL host is a Microsoft Teams Workflows one; set ALERT_WEBHOOK_FORMAT=json to override"
  else
    webhook_format="json"
    webhook_format_why="default"
  fi
  return 0
}

card_text_block() {  # <text> [extra JSON properties, e.g. '"weight":"Bolder"']
  printf '{"type":"TextBlock","text":%s,"wrap":true%s}' "$(json_str "$1")" "${2:+,$2}"
}

card_footer() {  # <generated timestamp>
  card_text_block "Source: padsign-monitor - generated ${1}" '"size":"Small","isSubtle":true,"separator":true'
}

teams_card_payload() {  # <comma-separated card body elements>
  printf '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","contentUrl":null,"content":{"$schema":"http://adaptivecards.io/schemas/adaptive-card.json","type":"AdaptiveCard","version":"1.4","body":[%s]}}]}' "$1"
}

# A double-quoted string in curl's config syntax.
curl_cfg_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/\\r}"; s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# The URL (whose path is the secret), the auth header and the payload reach
# curl as a config on its stdin, never on its command line, which `ps` shows
# to every user on the host.
post_webhook() {  # <url> <auth-header or ""> <payload>
  local url="$1" auth="$2" payload="$3" cfg out rest=""
  cfg="url = $(curl_cfg_str "$url")"$'\n'
  if [[ -n "$auth" ]]; then cfg+="header = $(curl_cfg_str "$auth")"$'\n'; fi
  cfg+="data-binary = $(curl_cfg_str "$payload")"$'\n'
  out="$(printf '%s' "$cfg" | curl -sS -g -o /dev/null -w '\n%{http_code}\n' --max-time 15 --retry 2 \
           -X POST -H 'Content-Type: application/json' -K - 2>&1 || true)"
  out="${out//$'\r'/}"
  webhook_http_code="$(printf '%s\n' "$out" | grep -E '^[0-9]{3}$' | tail -1 || true)"
  [[ -n "$webhook_http_code" ]] || webhook_http_code="000"
  # curl's own error line ("Could not resolve host", "Connection refused",
  # a TLS problem) helps, but must not carry the URL.
  webhook_curl_error="$(printf '%s\n' "$out" | grep -E '^curl: ' | tail -1 || true)"
  if [[ -n "$webhook_curl_error" ]]; then
    webhook_curl_error="${webhook_curl_error//"$url"/<webhook URL>}"
    if [[ "$url" =~ ^[^:/?#]+://[^/?#]*(.+)$ ]]; then rest="${BASH_REMATCH[1]}"; fi
    if [[ -n "$rest" ]]; then webhook_curl_error="${webhook_curl_error//"$rest"/<redacted>}"; fi
  fi
  return 0
}
