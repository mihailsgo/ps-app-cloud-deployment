#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Served-Certificate Verifier — what nginx ACTUALLY serves, over the wire
#
# Usage:
#   ./installation-scripts/verify-served-cert.sh                 # derives everything
#   ./installation-scripts/verify-served-cert.sh --host padsign.client.com
#   ./installation-scripts/verify-served-cert.sh --quiet         # for cron
#
# Exit codes:
#   0  No FAILs (WARNs are allowed)
#   1  One or more checks FAILED
#   2  Argument parse error, or the hostname could not be derived
#
# Why this exists, and why validate-certs.sh cannot replace it:
#
# nginx reads its ssl_certificate files ONLY at startup and on reload. So there
# are three states that are easy to conflate and are NOT the same thing:
#
#   1. ACME renewal succeeded
#   2. the renewed file is on disk at nginx/certs/<host>.crt
#   3. nginx is actually serving it
#
# States 1 and 2 can be green for months while 3 is stale. That is not
# hypothetical: a renewal hook that copied the new certificate into place but
# whose reload step silently failed left nginx serving a months-old certificate
# until it expired, taking TLS down completely. Every file-based check —
# including validate-certs.sh in full — passed for the entire outage, because
# the file was never the problem.
#
# The only thing that can catch this is a real TLS handshake, fingerprint-
# compared against the file on disk. That is what this script does.
#
# validate-certs.sh is the file-level, pre-deploy validator and is run against
# certificates that have not been deployed yet (uploads, hostname changes),
# where a served-vs-disk difference is expected and correct. This script is the
# post-deploy, running-system counterpart — hence verify-* rather than
# validate-*, matching verify-keycloak.sh.
# ============================================================================

host=""
disk_crt=""
disk_key=""
connect=""
connect_public="false"
warn_days=30
fail_days=7
retries=3
retry_delay=2
conn_timeout=10
quiet="false"
host_source="--host"
crt_source="--cert-crt"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/verify-served-cert.sh \
    [--host <fqdn>] [--cert-crt <path>] \
    [--connect <host[:port]> | --connect-public] \
    [--warn-days N] [--fail-days N] \
    [--retries N] [--retry-delay S] [--timeout S] [--quiet]

Checks:
  1. the on-disk certificate is readable and parses
  2. the on-disk certificate is not expired / not expiring imminently
  3. the nginx service is running (diagnostic only, never fails the run)
  4. a TLS handshake against the endpoint succeeds (retried)
  5. the SERVED certificate matches the ON-DISK certificate  <-- the key check
  6. the SERVED certificate is not expired / not expiring imminently
  7. the SERVED certificate matches the hostname
  8. the SERVED chain is as deep as the on-disk file (catches a missing
     intermediate that was appended to the file but never reloaded)

--host and --cert-crt default to values derived from nginx/nginx.conf.
--connect defaults to localhost:443, or nginx:443 when running in a container.
--connect-public targets <host>:443 instead — only valid when nginx itself
terminates TLS (not behind a CDN or load balancer that re-terminates).
--quiet prints nothing unless a check FAILS, which is the right mode for cron.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --cert-crt) disk_crt="${2:-}"; shift 2;;
    --connect) connect="${2:-}"; shift 2;;
    --connect-public) connect_public="true"; shift 1;;
    --warn-days) warn_days="${2:-}"; shift 2;;
    --fail-days) fail_days="${2:-}"; shift 2;;
    --retries) retries="${2:-}"; shift 2;;
    --retry-delay) retry_delay="${2:-}"; shift 2;;
    --timeout) conn_timeout="${2:-}"; shift 2;;
    --quiet) quiet="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: Missing dependency: openssl" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nginx_conf="${repo_root}/nginx/nginx.conf"

# --- Derive host / cert path from nginx.conf when not given explicitly ------
# configure-host.sh rewrites both directives in place, so nginx.conf is the
# authoritative statement of what this deployment is meant to be serving.
if [[ -z "$host" ]]; then
  host="$(awk '/^[[:space:]]*server_name[[:space:]]/ {gsub(/;/,"",$2); print $2; exit}' "$nginx_conf" 2>/dev/null || true)"
  host_source="derived from nginx/nginx.conf"
fi
if [[ -z "$host" ]]; then
  echo "ERROR: could not derive the hostname from ${nginx_conf} — pass --host explicitly" >&2
  exit 2
fi

if [[ -z "$disk_crt" ]]; then
  in_conf="$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ {gsub(/;/,"",$2); print $2; exit}' "$nginx_conf" 2>/dev/null || true)"
  case "$in_conf" in
    /etc/nginx/certs/*) disk_crt="${repo_root}/nginx/certs/${in_conf#/etc/nginx/certs/}" ;;
    *)                  disk_crt="${repo_root}/nginx/certs/${host}.crt" ;;
  esac
  crt_source="derived from nginx/nginx.conf"
fi
# Only ever used to name the key in a remediation hint; never read.
disk_key="${disk_crt%.crt}.key"

# --- Resolve the connect target ---------------------------------------------
# Inside a container (the wizard runs these scripts in its own container),
# localhost:443 is not nginx — the compose service name is. Deliberately no
# fallback between the two: falling back would let a dead host port look
# healthy.
if [[ "$connect_public" == "true" ]]; then
  connect="${host}:443"
  conn_source="--connect-public"
elif [[ -n "$connect" ]]; then
  conn_source="--connect"
elif [[ -f /.dockerenv ]]; then
  connect="nginx:443"
  conn_source="in-container default (compose service name)"
else
  connect="localhost:443"
  conn_source="default"
fi
[[ "$connect" == *:* ]] || connect="${connect}:443"

# --- Output buffering for --quiet -------------------------------------------
# Buffer everything, then replay only if a check FAILed. One exit path, so the
# buffer can never be silently dropped.
buf="$(mktemp)"
hs_out="$(mktemp)"
served_pem="$(mktemp)"
cleanup() { rm -f "$buf" "$hs_out" "$served_pem"; }
trap cleanup EXIT
if [[ "$quiet" == "true" ]]; then
  exec 3>&1 1>"$buf"
fi
finish() {
  local code="$1"
  if [[ "$quiet" == "true" ]]; then
    exec 1>&3
    [[ "$code" -ne 0 ]] && cat "$buf"
  fi
  exit "$code"
}

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  WARN %s\n' "$*"; }

fingerprint_of() { openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'; }
enddate_of()     { openssl x509 -in "$1" -noout -enddate 2>/dev/null | sed 's/^notAfter=//'; }

echo "PadSign Served-Certificate Verifier"
echo "  Host:     ${host}  (${host_source})"
echo "  On disk:  ${disk_crt}  (${crt_source})"
echo "  Endpoint: ${connect}  (${conn_source})"
echo "================================================"

# --- 1-2. On-disk certificate ------------------------------------------------
echo ""
echo "Disk checks:"
if [[ -r "$disk_crt" ]]; then
  ok "on-disk certificate readable"
else
  bad "on-disk certificate not readable: ${disk_crt}"
  echo ""
  echo "================================================"
  echo "Served-certificate check FAILED. Resolve issues above."
  finish 1
fi

disk_fp="$(fingerprint_of "$disk_crt")"
disk_end="$(enddate_of "$disk_crt")"
disk_blocks="$(grep -c '^-----BEGIN CERTIFICATE-----' "$disk_crt" 2>/dev/null || true)"
if [[ -z "$disk_fp" ]]; then
  bad "on-disk certificate does not parse as X.509 — run validate-certs.sh for detail"
  echo ""
  echo "================================================"
  echo "Served-certificate check FAILED. Resolve issues above."
  finish 1
fi
ok "on-disk certificate parses (SHA-256 ${disk_fp:0:23}..., ${disk_blocks} PEM block(s))"

# Threshold decisions use -checkend only, never date arithmetic, so this can
# never disagree with validate-certs.sh. Dates are used only to enrich text.
if ! openssl x509 -in "$disk_crt" -checkend 0 -noout >/dev/null 2>&1; then
  bad "the on-disk certificate is EXPIRED (notAfter: ${disk_end}) — renewal itself is failing, not just the reload"
elif ! openssl x509 -in "$disk_crt" -checkend "$((fail_days * 86400))" -noout >/dev/null 2>&1; then
  bad "the on-disk certificate expires within ${fail_days} days (notAfter: ${disk_end}) — renewal itself may be failing"
elif ! openssl x509 -in "$disk_crt" -checkend "$((warn_days * 86400))" -noout >/dev/null 2>&1; then
  warn "the on-disk certificate expires within ${warn_days} days (notAfter: ${disk_end})"
else
  ok "on-disk certificate is not expiring soon (notAfter: ${disk_end})"
fi

# --- 3. nginx service state (diagnostic only) --------------------------------
# Scoped via `docker compose ps`, not a global container-name match: a
# customized deployment's nginx container may not literally be named "nginx".
echo ""
echo "nginx service checks:"
if command -v docker >/dev/null 2>&1; then
  nginx_state="$( (cd "$repo_root" && docker compose ps nginx --format '{{.State}}' 2>/dev/null) || true )"
  if echo "$nginx_state" | grep -qi running; then
    ok "nginx service is running"
  elif [[ -z "$nginx_state" ]]; then
    warn "nginx service state not determined (docker reachable but no compose service matched)"
  else
    warn "nginx service is not running (state: ${nginx_state}) — the handshake below will explain the impact"
  fi
else
  warn "nginx service state not checked — docker not available to this user"
fi

# --- 4. Handshake, with retries ----------------------------------------------
# `|| true` is mandatory, not cosmetic: this is a real network handshake and
# openssl's own exit code under `set -o pipefail` must never abort the script.
# Success is judged by the CONTENT of the response, never by an exit code.
echo ""
echo "Served-certificate checks:"
attempt=0
got_handshake="false"
while [[ "$attempt" -lt "$retries" ]]; do
  attempt=$((attempt + 1))
  if command -v timeout >/dev/null 2>&1; then
    : | timeout "$conn_timeout" openssl s_client -connect "$connect" -servername "$host" >"$hs_out" 2>/dev/null || true
  else
    : | openssl s_client -connect "$connect" -servername "$host" >"$hs_out" 2>/dev/null || true
  fi
  if grep -q 'BEGIN CERTIFICATE' "$hs_out"; then
    got_handshake="true"
    break
  fi
  [[ "$attempt" -lt "$retries" ]] && sleep "$retry_delay"
done

if [[ "$got_handshake" != "true" ]]; then
  bad "no TLS handshake on ${connect} after ${retries} attempt(s) — nginx is not answering TLS there"
  echo ""
  echo "================================================"
  echo "Served-certificate check FAILED. Resolve issues above."
  finish 1
fi
if [[ "$attempt" -gt 1 ]]; then
  ok "TLS handshake to ${connect} succeeded"
  warn "handshake succeeded only on attempt ${attempt} of ${retries} — transient network or nginx instability"
else
  ok "TLS handshake to ${connect} succeeded"
fi

openssl x509 -in "$hs_out" -outform pem >"$served_pem" 2>/dev/null || true
served_fp="$(fingerprint_of "$served_pem")"
served_end="$(enddate_of "$served_pem")"
if [[ -z "$served_fp" ]]; then
  bad "the served certificate could not be parsed from the handshake response"
  echo ""
  echo "================================================"
  echo "Served-certificate check FAILED. Resolve issues above."
  finish 1
fi

# --- 5. THE KEY CHECK: served vs on-disk -------------------------------------
# The remediation text below deliberately contains NO blank lines: the wizard's
# parseHelperCheckOutput() flushes the current check on any blank line and drops
# everything after it, which would silently swallow the reload command.
if [[ "$served_fp" == "$disk_fp" ]]; then
  ok "the certificate nginx is serving matches the one on disk (SHA-256 ${served_fp:0:23}...)"
else
  bad "the certificate nginx is SERVING does not match the certificate on disk — nginx has not reloaded since the file changed.
       Served:  SHA-256 ${served_fp} (notAfter ${served_end})
       On disk: SHA-256 ${disk_fp} (notAfter ${disk_end}) — ${disk_crt}
       nginx reads its certificate files only at startup and on reload, so a renewal that copied a new file into place without reloading nginx leaves the OLD certificate live until it expires, while every file-based check keeps passing.
       Fix — run on the HOST, from the project root (NOT inside an ACME/certbot container):
           docker compose kill -s HUP nginx
       Then re-run this script: the two fingerprints above must become identical.
       If they do NOT change, nginx rejected the new files and kept its old configuration — check 'docker compose logs nginx', then run './installation-scripts/validate-certs.sh --host ${host} --cert-crt ${disk_crt} --cert-key ${disk_key}'.
       If your renewal hook performs the reload inside an ACME client container, that container needs both the docker CLI and /var/run/docker.sock, or the hook must run on the host — otherwise it fails with 'docker: not found'. Never end a reload hook with '|| true': that is what turns this into a silent multi-week outage instead of a loud failure."
fi

# --- 6. Served expiry ---------------------------------------------------------
if ! openssl x509 -in "$served_pem" -checkend 0 -noout >/dev/null 2>&1; then
  bad "the certificate nginx is SERVING is EXPIRED (notAfter: ${served_end}) — TLS is broken for every strict client right now"
elif ! openssl x509 -in "$served_pem" -checkend "$((fail_days * 86400))" -noout >/dev/null 2>&1; then
  bad "the certificate nginx is SERVING expires within ${fail_days} days (notAfter: ${served_end})"
elif ! openssl x509 -in "$served_pem" -checkend "$((warn_days * 86400))" -noout >/dev/null 2>&1; then
  warn "the served certificate expires within ${warn_days} days (notAfter: ${served_end})"
else
  ok "served certificate is not expiring soon (notAfter: ${served_end})"
fi

# --- 7. Served hostname -------------------------------------------------------
if openssl x509 -in "$served_pem" -noout -checkhost "$host" >/dev/null 2>&1; then
  ok "the served certificate is valid for ${host}"
else
  bad "the served certificate is NOT valid for ${host} — nginx is presenting a certificate for a different name, which also happens when a hostname change was applied without reloading nginx"
fi

# --- 8. Served chain depth vs on-disk block count ----------------------------
# Second, independent drift signal. If an operator appended a missing
# intermediate to the file and never reloaded, the LEAF fingerprint is
# unchanged, so check 5 cannot see it — but the served chain is still short.
# Count the chain listing s_client prints, not BEGIN CERTIFICATE markers: the
# leaf appears twice in that output and would over-count by one.
served_chain="$(grep -cE '^ *[0-9]+ s:' "$hs_out" 2>/dev/null || true)"
if [[ -z "$served_chain" || "$served_chain" -eq 0 ]]; then
  warn "served chain depth could not be determined"
elif [[ "$served_chain" -eq "$disk_blocks" ]]; then
  ok "served chain depth matches the on-disk file (${served_chain} certificate(s))"
elif [[ "$served_chain" -lt "$disk_blocks" ]]; then
  if [[ "$conn_source" == "--connect" || "$conn_source" == "--connect-public" ]]; then
    warn "served chain is shorter than the on-disk file (${served_chain} vs ${disk_blocks}) — expected if something in front of nginx re-terminates TLS"
  else
    bad "the served chain is SHORTER than the on-disk file (${served_chain} vs ${disk_blocks}) — intermediates were added to the file but nginx has not reloaded. Reload with 'docker compose kill -s HUP nginx' from the project root."
  fi
else
  warn "served chain is longer than the on-disk file (${served_chain} vs ${disk_blocks})"
fi

# --- Summary -------------------------------------------------------------------
echo ""
echo "================================================"
if [[ "$fail" -eq 0 ]]; then
  echo "All served-certificate checks passed."
  finish 0
else
  echo "Served-certificate check FAILED. Resolve issues above."
  finish 1
fi
