# shellcheck shell=bash
# ============================================================================
# The visual-PDF signing CA: a per-deployment keystore, never a shared one.
#
# dmss-container-and-signature-services signs visual (tablet) PDF signatures
# with certificates it issues from the CA in
# dmss-container-and-signature-services/dmssrootca.p12 (application.yml:
# pdf.cakeystorepath / cakeystorepassword / caCertAlias). The copy this PUBLIC
# repository ships holds its private key, so anyone can issue certificates
# under it. A deployment must run on its own CA.
#
# Sourced by configure-host.sh (--generate-ca, which bootstrap.sh passes on
# every fresh install) and validate-config.sh. Never prints a password.
#
#   vpca_state <repo_root>
#       Prints one of:
#         shipped     the CA is one this repository has published
#         custom      the deployment's own CA
#         missing     no keystore at the path
#         unreadable  the keystore does not open with the configured password
#
#   vpca_generate <repo_root> <host>
#       When, and only when, vpca_state is "shipped": writes a new RSA-3072
#       CA (10 years) under the alias application.yml names, with a random
#       password, into the keystore in place (owner and mode kept) and sets
#       cakeystorepassword to match. Returns 0 after generating, 1 when the
#       state was not "shipped" (nothing touched), 2 on error.
#
# Rotating only changes the issuer of signatures made from then on. Already
# signed documents keep the certificate chain they were signed with.
# dmss-container-and-signature-services reads the keystore at startup, so
# the caller restarts it (bootstrap.sh starts it after configure-host.sh).
# ============================================================================

# SHA-256 fingerprints of every CA certificate this repository has shipped
# (upper-case hex, colon separated, as `openssl x509 -fingerprint` prints).
# Add a line whenever a release changes the shipped dmssrootca.p12;
# installation-scripts/tests/test-visual-pdf-ca.sh fails until it is listed.
VPCA_SHIPPED_FINGERPRINTS=(
  # CN=TrustLynx Visual PDF CA, shipped up to v1.0.48
  "30:AC:00:C9:70:E7:93:D0:64:D7:CF:78:CA:65:D7:1F:78:63:F9:6F:D7:74:77:F4:26:B6:2C:01:DF:72:AA:3A"
  # CN=PadSign DEMO Visual PDF CA - NOT FOR PRODUCTION
  "BD:FC:DF:CC:C9:3C:B0:5A:45:20:D7:0D:02:F2:4D:B0:14:3C:E6:D6:B6:2D:B9:AE:0D:10:9D:8F:3C:EA:EE:F9"
)

_vpca_yml() { printf '%s/dmss-container-and-signature-services/application.yml' "$1"; }

# _vpca_yml_value <yml> <key>: the value of the first "<key>:" line, unquoted.
_vpca_yml_value() {
  sed -nE "s/^[[:space:]]*$2:[[:space:]]*//p" "$1" | head -n 1 | tr -d '\r' \
    | sed -E "s/[[:space:]]+#.*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# _vpca_keystore <repo_root>: host path of the keystore application.yml names.
# The service mounts ./dmss-container-and-signature-services at /confs.
_vpca_keystore() {
  local path
  path="$(_vpca_yml_value "$(_vpca_yml "$1")" cakeystorepath)"
  printf '%s/dmss-container-and-signature-services/%s' "$1" "${path#/confs/}"
}

# _vpca_fingerprint <p12>: SHA-256 fingerprint of the certificate in the
# keystore, opened with the password in $VPCA_PASS (never argv).
_vpca_fingerprint() {
  openssl pkcs12 -in "$1" -nokeys -passin env:VPCA_PASS 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed -nE 's/^[^=]*=//p' | tr -d '\r'
}

vpca_state() {
  local root="$1" yml ks fp shipped
  yml="$(_vpca_yml "$root")"
  [[ -f "$yml" ]] || { echo missing; return 0; }
  ks="$(_vpca_keystore "$root")"
  [[ -f "$ks" ]] || { echo missing; return 0; }
  fp="$(VPCA_PASS="$(_vpca_yml_value "$yml" cakeystorepassword)" _vpca_fingerprint "$ks")"
  [[ -n "$fp" ]] || { echo unreadable; return 0; }
  for shipped in "${VPCA_SHIPPED_FINGERPRINTS[@]}"; do
    [[ "$fp" == "$shipped" ]] && { echo shipped; return 0; }
  done
  echo custom
}

vpca_generate() {
  local root="$1" host="$2" yml ks alias state tmp pass
  state="$(vpca_state "$root")"
  [[ "$state" == shipped ]] || return 1
  command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required to generate the visual-PDF CA" >&2; return 2; }
  yml="$(_vpca_yml "$root")"
  ks="$(_vpca_keystore "$root")"
  alias="$(_vpca_yml_value "$yml" caCertAlias)"
  [[ -n "$alias" ]] || { echo "ERROR: no caCertAlias in $yml" >&2; return 2; }

  tmp="$(mktemp -d)"
  chmod 700 "$tmp"
  # Letter prefix: an all-digit hex string would be read by YAML as a number.
  pass="vpca-$(openssl rand -hex 24)"
  # Relative file names inside $tmp, and MSYS2_ARG_CONV_EXCL for -subj: Git
  # Bash would otherwise rewrite "/O=..." as a Windows path (no-op on Linux).
  if ! (cd "$tmp" \
        && MSYS2_ARG_CONV_EXCL='*' openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
             -keyout ca.key -out ca.crt \
             -subj "/O=PadSign/CN=PadSign Visual PDF CA (${host})" \
             -addext "basicConstraints=critical,CA:TRUE" \
             -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \
             -addext "subjectKeyIdentifier=hash" \
        && VPCA_PASS="$pass" openssl pkcs12 -export -name "$alias" \
             -inkey ca.key -in ca.crt -out ca.p12 -passout env:VPCA_PASS) >/dev/null 2>&1; then
    rm -rf "$tmp"
    echo "ERROR: openssl could not create the visual-PDF CA keystore" >&2
    return 2
  fi
  # Written into the existing file, not moved over it, so the owner and mode
  # the container reads it with are kept (same reason as secret_hygiene.py).
  cat "$tmp/ca.p12" > "$ks"
  rm -rf "$tmp"
  VPCA_PASS="$pass" perl -i -pe \
    's/^(\s*cakeystorepassword:\s*).*?(\r?)$/$1$ENV{VPCA_PASS}$2/' "$yml"
  return 0
}
