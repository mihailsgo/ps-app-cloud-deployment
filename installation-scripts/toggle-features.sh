#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Toggle Features — flip document routing / demo mode / local
# e-sealing on an ALREADY-LIVE stack, any combination in one restart
# (deployment-wizard Settings feature, see documentation/37-*).
#
# Usage:
#   ./installation-scripts/toggle-features.sh \
#     [--enable-routing|--disable-routing] \
#     [--enable-demo|--disable-demo] \
#     [--enable-local-eseal|--disable-local-eseal] \
#     [--host <current, optional — defaults to a live read of nginx.conf>]
#
# What it does:
#   1) Calls configure-host.sh with whichever flags were passed (this also
#      doubles as first-time provisioning for local e-sealing if it was
#      never enabled before — configure-host.sh's --enable-local-eseal path
#      already handles that idempotently, nothing new needed here)
#   2) Restarts only what each change actually needs: demo mode needs NO
#      restart at all (constants.json is served statically); routing and
#      local e-sealing both need ps-server restarted (config.js is
#      require()-cached); enabling local e-sealing also starts/recreates
#      dmss-digital-stamping-service + dmss-container-and-signature-services
#      (their compose config may have just changed); disabling it stops
#      dmss-digital-stamping-service so "off" is actually off, not just
#      profile-gated-but-still-running from an earlier session
#   3) Verifies the resulting live state of every feature that was touched
# ============================================================================

host=""
routing_action=""   # "enable" | "disable" | ""
demo_action=""
eseal_action=""

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/toggle-features.sh \
    [--enable-routing|--disable-routing] \
    [--enable-demo|--disable-demo] \
    [--enable-local-eseal|--disable-local-eseal] \
    [--host <current hostname>]

At least one --enable-*/--disable-* flag is required. --host is optional —
if omitted, it's read live from nginx/nginx.conf's server_name (the same
hostname configure-host.sh's other rewrites will then be a no-op against,
since only the requested feature flags change).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --enable-routing) routing_action="enable"; shift 1;;
    --disable-routing) routing_action="disable"; shift 1;;
    --enable-demo) demo_action="enable"; shift 1;;
    --disable-demo) demo_action="disable"; shift 1;;
    --enable-local-eseal) eseal_action="enable"; shift 1;;
    --disable-local-eseal) eseal_action="disable"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$routing_action" && -z "$demo_action" && -z "$eseal_action" ]]; then
  echo "ERROR: Provide at least one of --enable-routing/--disable-routing, --enable-demo/--disable-demo, --enable-local-eseal/--disable-local-eseal" >&2
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="${repo_root}/installation-scripts"
config_js="${repo_root}/config/config.js"
constants_json="${repo_root}/config/constants.json"
nginx_conf="${repo_root}/nginx/nginx.conf"
compose_yml="${repo_root}/docker-compose.yml"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}
need_cmd docker
need_cmd sed
need_cmd perl
need_cmd python3

if [[ -z "$host" ]]; then
  host="$(sed -nE 's/^\s*server_name\s+([^ ;]+);.*/\1/p' "$nginx_conf" 2>/dev/null | head -1)"
fi
if [[ -z "$host" ]]; then
  echo "ERROR: Could not determine the current hostname from nginx/nginx.conf; pass --host explicitly." >&2
  exit 1
fi

# ── Pre-flight: local-eseal needs a ps-server image that contains the
#    STAMP_MODE dispatch (ported from upgrade.sh's identical gate) — refuse
#    rather than produce a silent no-op where STAMP_MODE=local lands in
#    config.js but ps-server ignores it.
LOCAL_ESEAL_MIN_SERVER_TAG="3.26"
if [[ "$eseal_action" == "enable" ]]; then
  current_server="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "$compose_yml" 2>/dev/null | head -1)"
  if [[ -z "$current_server" ]]; then
    echo "ERROR: Cannot determine the ps-server image tag from docker-compose.yml." >&2
    exit 2
  fi
  smaller="$(printf '%s\n%s\n' "$current_server" "$LOCAL_ESEAL_MIN_SERVER_TAG" | sort -V | head -1)"
  if [[ "$current_server" != "$LOCAL_ESEAL_MIN_SERVER_TAG" && "$smaller" == "$current_server" ]]; then
    echo "ERROR: Enabling local e-sealing requires mihailsgordijenko/ps-server:${LOCAL_ESEAL_MIN_SERVER_TAG} or newer." >&2
    echo "       The current ps-server tag is :${current_server}, which predates the STAMP_MODE dispatch." >&2
    echo "       Upgrade ps-server first (Dashboard -> Upgrade), then retry this toggle." >&2
    exit 2
  fi
fi

echo "========================================"
echo "PadSign Toggle Features"
[[ -n "$routing_action" ]] && echo "  Document routing: -> ${routing_action}d"
[[ -n "$demo_action" ]] && echo "  Demo mode:        -> ${demo_action}d"
[[ -n "$eseal_action" ]] && echo "  Local e-sealing:  -> ${eseal_action}d"
echo "========================================"
echo ""

# ── Step 1: Apply the requested flags ──
echo "Step 1/3: Configuring feature flags for '${host}'..."
configure_args=(--host "${host}")
case "$routing_action" in
  enable) configure_args+=(--enable-routing);;
  disable) configure_args+=(--disable-routing);;
esac
case "$demo_action" in
  enable) configure_args+=(--enable-demo);;
  disable) configure_args+=(--disable-demo);;
esac
case "$eseal_action" in
  enable) configure_args+=(--enable-local-eseal);;
  disable) configure_args+=(--disable-local-eseal);;
esac
"${scripts_dir}/configure-host.sh" "${configure_args[@]}"

# ── Step 2: Restart only what's needed ──
echo "Step 2/3: Applying changes..."
cd "${repo_root}"
restart_at="$(date +%s)"

if [[ "$eseal_action" == "enable" ]]; then
  echo "  Starting/updating local e-sealing services..."
  docker compose up -d dmss-container-and-signature-services dmss-digital-stamping-service
elif [[ "$eseal_action" == "disable" ]]; then
  echo "  Stopping dmss-digital-stamping-service..."
  docker compose stop dmss-digital-stamping-service 2>/dev/null || true
fi

if [[ -n "$routing_action" || -n "$eseal_action" ]]; then
  docker compose restart ps-server
  # Poll rather than a single fixed sleep — a one-shot check after a flat
  # `sleep 3` was observed to false-positive-WARN under load (the restart
  # itself succeeded; the app just hadn't printed its startup banner yet).
  ps_server_ok="false"
  for i in $(seq 1 15); do
    if docker compose logs --since "$restart_at" ps-server 2>/dev/null | grep -q "PadSign Server listening"; then
      ps_server_ok="true"
      break
    fi
    sleep 1
  done
  if [[ "$ps_server_ok" == "true" ]]; then
    echo "  ps-server: OK"
  else
    echo "  WARNING: ps-server may not have restarted correctly. Check: docker compose logs ps-server" >&2
  fi
else
  echo "  ps-server: OK (no restart needed - demo mode is served statically)"
fi

# ── Step 3: Verify resulting live state ──
echo "Step 3/3: Verifying..."
if [[ -n "$routing_action" ]]; then
  routing_now="$(perl -ne 'if (/DOCUMENT_ROUTING/) { $in=1 } if ($in && /^\s*enabled:\s*(true|false)/) { print $1; exit }' "$config_js")"
  expected="$([[ "$routing_action" == "enable" ]] && echo true || echo false)"
  if [[ "$routing_now" == "$expected" ]]; then
    echo "  Document routing: OK (enabled=${routing_now})"
  else
    echo "  WARNING: Document routing enabled=${routing_now:-unknown}, expected ${expected}" >&2
  fi
fi

if [[ -n "$demo_action" ]]; then
  # `|| true` matters here: grep exits non-zero when the field is simply
  # absent (a real, reachable case, not a script bug) — under
  # set -euo pipefail that would silently abort the whole run right at
  # this readback line instead of falling through to the "unknown" WARNING
  # below. Found live: the same class of bug that made a successful
  # renew-cert.sh run report as a hard failure.
  demo_now="$(grep -oE '"DEMO_MODE"[[:space:]]*:[[:space:]]*"[A-Z]+"' "$constants_json" | grep -oE '"[A-Z]+"$' | tr -d '"' || true)"
  expected="$([[ "$demo_action" == "enable" ]] && echo ENABLE || echo DISABLE)"
  if [[ "$demo_now" == "$expected" ]]; then
    echo "  Demo mode: OK (${demo_now})"
  else
    echo "  WARNING: Demo mode is ${demo_now:-unknown}, expected ${expected}" >&2
  fi
fi

if [[ -n "$eseal_action" ]]; then
  eseal_now="$(grep -oE 'STAMP_MODE:[[:space:]]*"[a-z]+"' "$config_js" | grep -oE '"[a-z]+"$' | tr -d '"' || true)"
  expected="$([[ "$eseal_action" == "enable" ]] && echo local || echo external)"
  if [[ "$eseal_now" == "$expected" ]]; then
    echo "  Local e-sealing: OK (STAMP_MODE=${eseal_now})"
  else
    echo "  WARNING: STAMP_MODE is ${eseal_now:-unknown}, expected ${expected}" >&2
  fi
fi

echo ""
echo "========================================"
echo "Feature toggle complete!"
echo "========================================"
