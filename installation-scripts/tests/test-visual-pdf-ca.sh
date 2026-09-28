#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for the per-deployment visual-PDF signing CA (lib/visual-pdf-ca.sh):
#
#   - the dmssrootca.p12 this checkout ships is recognised as a shipped CA
#     (its fingerprint is listed in VPCA_SHIPPED_FINGERPRINTS);
#   - vpca_generate replaces it once, under the alias application.yml names,
#     keeps the keystore's mode, rewrites only cakeystorepassword, and never
#     prints the password; a second run touches nothing;
#   - configure-host.sh --generate-ca and validate-config.sh report it.
#
# Usage:
#   ./installation-scripts/tests/test-visual-pdf-ca.sh
#
# Works on throwaway copies of the tracked files, never the real config.
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in openssl perl git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}

# shellcheck source=../lib/visual-pdf-ca.sh
source "${src_root}/installation-scripts/lib/visual-pdf-ca.sh"

copy_csig() {  # <dest>: the container-signature config as tracked
  mkdir -p "$1/dmss-container-and-signature-services"
  (cd "$src_root" && git show HEAD:dmss-container-and-signature-services/application.yml) \
    > "$1/dmss-container-and-signature-services/application.yml" 2>/dev/null \
    || cp "$src_root/dmss-container-and-signature-services/application.yml" "$1/dmss-container-and-signature-services/"
  cp "$src_root/dmss-container-and-signature-services/dmssrootca.p12" "$1/dmss-container-and-signature-services/"
}
yml_pass() { _vpca_yml_value "$1/dmss-container-and-signature-services/application.yml" cakeystorepassword; }
cert_of() {  # <root>: subject and friendlyName of the keystore's certificate
  VPCA_PASS="$(yml_pass "$1")" openssl pkcs12 -in "$1/dmss-container-and-signature-services/dmssrootca.p12" \
    -nokeys -passin env:VPCA_PASS 2>/dev/null | grep -E 'friendlyName|subject'
}

echo ""
echo "Shipped keystore:"
r="${work}/shipped"
copy_csig "$r"
check "the checkout's dmssrootca.p12 is a listed shipped CA" test "$(vpca_state "$r")" = shipped
check "it carries the alias application.yml names (caCertAlias)" \
  grep -q "friendlyName: $(_vpca_yml_value "$r/dmss-container-and-signature-services/application.yml" caCertAlias)" <<< "$(cert_of "$r")"
check "it is labelled as a demo CA" grep -q 'CN *= *PadSign DEMO Visual PDF CA - NOT FOR PRODUCTION' <<< "$(cert_of "$r")"

echo ""
echo "vpca_generate:"
r="${work}/gen"
copy_csig "$r"
chmod 640 "$r/dmss-container-and-signature-services/dmssrootca.p12"
before_pass="$(yml_pass "$r")"
out="$(vpca_generate "$r" padsign.test.local 2>&1)"; rc=$?
check "generates (rc 0)" test "$rc" = 0
check "prints nothing" test -z "$out"
check "state is now custom" test "$(vpca_state "$r")" = custom
new_pass="$(yml_pass "$r")"
check "cakeystorepassword changed to a random, letter-prefixed value" \
  bash -c '[[ "$1" != "$2" && "$1" =~ ^vpca-[0-9a-f]{48}$ ]]' _ "$new_pass" "$before_pass"
check "the new CA names the host and keeps the alias" \
  bash -c 'grep -q "friendlyName: digital mind root ca" <<< "$1" && grep -q "padsign.test.local" <<< "$1"' _ "$(cert_of "$r")"
check "the new certificate is a CA" \
  bash -c 'VPCA_PASS="$1" openssl pkcs12 -in "$2" -nokeys -passin env:VPCA_PASS 2>/dev/null | openssl x509 -noout -ext basicConstraints 2>/dev/null | grep -q "CA:TRUE"' \
  _ "$new_pass" "$r/dmss-container-and-signature-services/dmssrootca.p12"
check "the keystore holds a private key" \
  bash -c 'VPCA_PASS="$1" openssl pkcs12 -in "$2" -info -nocerts -nokeys -passin env:VPCA_PASS 2>&1 | grep -q "Shrouded Keybag"' \
  _ "$new_pass" "$r/dmss-container-and-signature-services/dmssrootca.p12"
check "application.yml is unchanged apart from cakeystorepassword" \
  bash -c 'diff <(grep -v cakeystorepassword "$1") <(grep -v cakeystorepassword "$2") >/dev/null' _ \
  "$src_root/dmss-container-and-signature-services/application.yml" "$r/dmss-container-and-signature-services/application.yml"
if $linux; then
  check "keystore mode kept (640)" test "$(stat -c '%a' "$r/dmss-container-and-signature-services/dmssrootca.p12")" = 640
fi
vpca_generate "$r" padsign.test.local >/dev/null 2>&1; rc=$?
check "a second run touches nothing (rc 1, same password)" bash -c '[[ "$1" == 1 && "$2" == "$3" ]]' _ "$rc" "$(yml_pass "$r")" "$new_pass"

echo ""
echo "Other states:"
r="${work}/bad"
copy_csig "$r"
perl -i -pe 's/^(\s*cakeystorepassword:\s*).*/${1}wrong-password/' "$r/dmss-container-and-signature-services/application.yml"
check "wrong password: unreadable" test "$(vpca_state "$r")" = unreadable
vpca_generate "$r" x >/dev/null 2>&1; rc=$?
check "unreadable keystore is never replaced (rc 1)" test "$rc" = 1
rm "$r/dmss-container-and-signature-services/dmssrootca.p12"
check "no keystore: missing" test "$(vpca_state "$r")" = missing

echo ""
echo "configure-host.sh / validate-config.sh wording:"
check "configure-host.sh reports the generation" \
  grep -q "Generated this deployment's visual-PDF signing CA" "$src_root/installation-scripts/configure-host.sh"
check "bootstrap.sh passes --generate-ca" grep -q -- '--generate-ca' "$src_root/installation-scripts/bootstrap.sh"
check "validate-config.sh warns on a shipped CA with the fix" \
  grep -q 'is the one shipped in the public repository - its private key is public. Fix: ./installation-scripts/configure-host.sh --host ${host} --generate-ca' \
  "$src_root/installation-scripts/validate-config.sh"

echo ""
echo "Result: ${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
