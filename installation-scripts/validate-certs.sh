#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign TLS Certificate Validator — pre-flight checks before nginx sees it
#
# Usage:
#   ./installation-scripts/validate-certs.sh \
#     --host padsign.client.com \
#     --cert-crt path/to/cert.crt \
#     --cert-key path/to/cert.key \
#     [--allow-self-signed]
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks FAILED (deploy must not continue)
#   2  Argument parse error
#
# Why this exists: nginx serves the .crt file as-is via a single
# ssl_certificate directive. A leaf-only file (no intermediates) breaks
# Keycloak's backchannel TLS validation even when browsers might appear
# to tolerate it. This validator catches that and other cert issues
# BEFORE any container starts.
#
# Scope: this script is FILE-LEVEL ONLY. It says nothing about what nginx is
# actually serving — nginx reads its certificate files only at startup and on
# reload, so a renewed file on disk can sit unserved indefinitely while every
# check here passes. For the over-the-wire check, use
# installation-scripts/verify-served-cert.sh (see documentation/11-02).
# ============================================================================

host=""
cert_crt=""
cert_key=""
allow_self_signed="false"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/validate-certs.sh \
    --host <fqdn> \
    --cert-crt <path> \
    --cert-key <path> \
    [--allow-self-signed]

Checks:
  1. cert/key files are readable
  2. cert is a valid PEM X.509, key is a valid PEM private key
  3. key is not encrypted (nginx cannot start non-interactively)
  4. cert and key are the same keypair (SHA-256 of pubkey)
  5. cert is not expired (warns when expiring within 30 days)
  6. <fqdn> matches the cert CN or a Subject Alternative Name entry
  7. cert chain verifies — distinguishes "leaf-only file" from
     "chain doesn't validate against system trust store"

--allow-self-signed skips ONLY the chain-verify step (#7).

These are file-level checks. To verify what nginx is actually SERVING over
the wire, use ./installation-scripts/verify-served-cert.sh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --cert-crt) cert_crt="${2:-}"; shift 2;;
    --cert-key) cert_key="${2:-}"; shift 2;;
    --allow-self-signed) allow_self_signed="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

missing=()
[[ -z "$host" ]] && missing+=("--host")
[[ -z "$cert_crt" ]] && missing+=("--cert-crt")
[[ -z "$cert_key" ]] && missing+=("--cert-key")
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required arguments: ${missing[*]}" >&2
  usage
  exit 2
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "ERROR: Missing dependency: openssl" >&2
  exit 1
fi

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  WARN %s\n' "$*"; }

echo "PadSign TLS Certificate Validator"
echo "  Host:     ${host}"
echo "  Cert:     ${cert_crt}"
echo "  Key:      ${cert_key}"
[[ "$allow_self_signed" == "true" ]] && echo "  Mode:     --allow-self-signed (chain check skipped)"
echo "================================================"

# --- 1. Files readable ---
echo ""
echo "File checks:"
if [[ -r "$cert_crt" ]]; then
  ok "cert file readable"
else
  bad "cert file not readable: $cert_crt"
fi
if [[ -r "$cert_key" ]]; then
  ok "key file readable"
else
  bad "key file not readable: $cert_key"
fi

# Bail early if files unreadable — later checks would emit confusing openssl errors.
if [[ "$fail" -ne 0 ]]; then
  echo ""
  echo "================================================"
  echo "Cert validation FAILED. Fix file access before re-running."
  exit 1
fi

# --- 2. PEM format ---
echo ""
echo "Format checks:"
if openssl x509 -in "$cert_crt" -noout -subject >/dev/null 2>&1; then
  ok "cert file is a valid PEM X.509 certificate"
else
  bad "$cert_crt is not a valid PEM X.509 certificate (expected '-----BEGIN CERTIFICATE-----')"
fi
if openssl pkey -in "$cert_key" -noout >/dev/null 2>&1; then
  ok "key file is a valid PEM private key"
else
  # pkey fails on encrypted keys too, but the next check gives a clearer message
  if grep -q "ENCRYPTED" "$cert_key" 2>/dev/null; then
    ok "key file is a PEM private key (encrypted — see next check)"
  else
    bad "$cert_key is not a valid PEM private key (expected '-----BEGIN PRIVATE KEY-----' or similar)"
  fi
fi

# --- 3. Key not encrypted ---
if grep -q "ENCRYPTED" "$cert_key" 2>/dev/null; then
  bad "private key is encrypted — nginx cannot start non-interactively. Decrypt: openssl pkey -in <encrypted.key> -out ${cert_key}"
else
  ok "private key is not encrypted"
fi

# Bail early if format invalid — later openssl invocations would cascade-fail.
if [[ "$fail" -ne 0 ]]; then
  echo ""
  echo "================================================"
  echo "Cert validation FAILED. Fix file format before re-running."
  exit 1
fi

# --- 4. Cert/key pubkey match ---
echo ""
echo "Identity checks:"
crt_fp="$(openssl x509 -in "$cert_crt" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
key_fp="$(openssl pkey -in "$cert_key" -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
if [[ -n "$crt_fp" && -n "$key_fp" && "$crt_fp" == "$key_fp" ]]; then
  ok "cert and key are the same keypair"
else
  bad "cert and key do NOT belong to the same keypair — nginx will refuse to start. Verify --cert-crt and --cert-key point to files generated together."
fi

# --- 5. Expiry ---
not_after="$(openssl x509 -in "$cert_crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
if openssl x509 -in "$cert_crt" -checkend 0 -noout >/dev/null 2>&1; then
  if openssl x509 -in "$cert_crt" -checkend 2592000 -noout >/dev/null 2>&1; then
    ok "cert is not expired (notAfter: ${not_after})"
  else
    ok "cert is not expired (notAfter: ${not_after})"
    warn "cert expires within 30 days — plan renewal"
  fi
else
  bad "cert is EXPIRED (notAfter: ${not_after})"
fi

# --- 6. Hostname matches CN or SAN ---
# Hostname check: literal match against CN and SAN DNS entries, including
# wildcard SAN entries (*.example.com matches one DNS label).
host_match="false"

cn="$(openssl x509 -in "$cert_crt" -noout -subject 2>/dev/null | sed -n 's/.*CN[ ]*=[ ]*\([^,\/]*\).*/\1/p' | tr -d '[:space:]')"
san_raw="$(openssl x509 -in "$cert_crt" -noout -ext subjectAltName 2>/dev/null || true)"
# Extract DNS:* entries
san_dns=()
while IFS= read -r line; do
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && san_dns+=("$entry")
  done < <(echo "$line" | grep -oE 'DNS:[^,[:space:]]+' | sed 's/^DNS://')
done <<< "$san_raw"

match_host() {
  local pattern="$1"
  local target="$2"
  # Exact (case-insensitive) match — DNS labels are case-insensitive
  if [[ "${pattern,,}" == "${target,,}" ]]; then
    return 0
  fi
  # Wildcard match: *.example.com matches foo.example.com (exactly one extra label)
  if [[ "$pattern" == \*.* ]]; then
    local pattern_suffix="${pattern#*.}"
    local target_first_label="${target%%.*}"
    local target_rest="${target#*.}"
    # target must have at least one dot (target_first_label != target)
    # and target_rest (everything after first dot) must equal the pattern's suffix
    if [[ "$target_first_label" != "$target" && "${target_rest,,}" == "${pattern_suffix,,}" ]]; then
      return 0
    fi
  fi
  return 1
}

if [[ -n "$cn" ]] && match_host "$cn" "$host"; then
  host_match="true"
fi
if [[ "$host_match" != "true" ]]; then
  for entry in "${san_dns[@]}"; do
    if match_host "$entry" "$host"; then
      host_match="true"
      break
    fi
  done
fi

if [[ "$host_match" == "true" ]]; then
  ok "hostname '${host}' matches cert CN/SAN"
else
  cn_show="${cn:-<none>}"
  if [[ ${#san_dns[@]} -gt 0 ]]; then
    san_show="$(IFS=, ; echo "${san_dns[*]}")"
  else
    san_show="<none>"
  fi
  bad "hostname '${host}' is NOT present in cert Subject CN or subjectAltName. CN: ${cn_show}; SAN DNS: ${san_show}. Browsers and Keycloak backchannel calls will reject this cert."
fi

# --- 7. Chain verification ---
echo ""
echo "Chain checks:"
block_count="$(grep -c '^-----BEGIN CERTIFICATE-----' "$cert_crt" || true)"
ok "cert file contains ${block_count} PEM certificate block(s)"

if [[ "$allow_self_signed" == "true" ]]; then
  warn "chain verification skipped (--allow-self-signed)"
elif [[ "$block_count" -eq 1 ]]; then
  # Case (a): single block. Treat as fullchain ONLY if it's a self-signed root.
  if openssl verify -CAfile "$cert_crt" "$cert_crt" >/dev/null 2>&1; then
    ok "cert is self-signed root (single block verifies against itself) — unusual but valid for some private CAs"
  else
    bad "$cert_crt contains only the leaf certificate (1 PEM block) and is not a self-signed root.
       nginx will serve it as-is, but clients — including Keycloak's own backchannel JWKS fetch —
       will fail TLS verification and login will break.

       Fix: build a fullchain file by concatenating leaf + intermediates in chain order,
       then re-run bootstrap:

           cat leaf.crt intermediate.crt [root.crt] > fullchain.crt
           --cert-crt fullchain.crt

       Let's Encrypt: use /etc/letsencrypt/live/<host>/fullchain.pem.
       Development bypass: --allow-self-signed (skips chain check only)."
  fi
else
  # Case (b): multi-block file. Use blocks 2..N as untrusted intermediates,
  # rely on /etc/ssl/certs for trust root. Capture stderr for diagnostics.
  intermediates_file="$(mktemp)"
  trap 'rm -f "$intermediates_file"' EXIT
  awk '/-----BEGIN CERTIFICATE-----/{n++} n>=2' "$cert_crt" > "$intermediates_file"

  verify_out="$(openssl verify -untrusted "$intermediates_file" "$cert_crt" 2>&1 || true)"
  if echo "$verify_out" | grep -q ": OK$"; then
    ok "cert chain verifies against the system trust store"
  else
    bad "cert chain does NOT verify against the system trust store.
       Intermediates may be in the wrong order, or the issuing CA is a private CA
       not present in /etc/ssl/certs. Install the root into the system trust store
       (e.g. update-ca-certificates) or pass --allow-self-signed for development.
       openssl output: ${verify_out}"
  fi
fi

# --- Summary ---
echo ""
echo "================================================"
if [[ "$fail" -eq 0 ]]; then
  echo "All cert checks passed."
  exit 0
else
  echo "Cert validation FAILED. Resolve issues above before deploying."
  exit 1
fi
