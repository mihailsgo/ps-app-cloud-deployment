#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign DMSS Boot + Seal Smoke Test — boots the pinned
# dmss-container-and-signature-services and dmss-digital-stamping-service
# images against this repo's own DMSS config, in a throwaway compose project,
# and performs several consecutive real local e-seals.
#
# Usage:
#   ./installation-scripts/dmss-seal-smoke.sh
#   ./installation-scripts/dmss-seal-smoke.sh --cs-image trustlynx/container-signature-service:<tag>
#
# Why this exists: a DMSS image bump can pass every file-level check
# (validate-config.sh, check-digest-drift.sh) and still be unusable with
# this repo's config. Two real cases, both found only by booting and sealing:
#   - container-signature 24.3.3.9 does not start at all without spring.mail.*
#     (no JavaMailSender bean), which also blocks every service that
#     depends on it being healthy.
#   - from somewhere after 24.3.0.34 until at least 24.3.3.9, container-signature
#     writes the resolved signature level back into the shared signing
#     profile, so the B_BES `LocalDemo` profile seals once and then turns
#     into PAdES-BASELINE-LT, which needs a TSA. The first seal after a
#     restart succeeds, every later one fails. A single-seal check misses
#     this, which is why the default here is 3 consecutive seals per profile.
# See documentation/39-release-procedure.md ("Keeping digests current").
#
# Isolation: its own compose project name (padsign-seal-smoke-<pid>), no
# container_name, no host port bindings at all (seals are sent from inside
# the container-signature container), and a temporary copy of the config
# directories. It never touches the default project, any other running
# stack, or any file in this repository. Everything it creates is removed on
# exit unless --keep is given.
#
# Exit codes: 0 all checks passed, 1 a check failed, 2 usage/dependency error.
# ============================================================================

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/dmss-seal-smoke.sh [options]

Options:
  --cs-image <ref>      container-signature image to test
                        (default: what docker-compose.yml pins)
  --stamp-image <ref>   digital-stamping image to test
                        (default: what docker-compose.yml pins)
  --profile <name>      signing profile to seal with; repeatable
                        (default: LocalDemo)
  --seals <n>           consecutive seals per profile (default: 3, minimum 2)
  --boot-timeout <sec>  how long to wait for container-signature to report
                        UP (default: 300)
  --keep                leave the project and its temp directory in place
                        for inspection (prints how to remove them)
  -h, --help            show this help

Checks:
  1. container-signature starts and /actuator/health reports UP
  2. every seal returns HTTP 200 with a signed PDF (has /ByteRange)
  3. the signature level container-signature logs for each seal does not
     change between seals (skipped if that image doesn't log it)

Needs docker (compose v2) and python3. Pulls the images if they aren't
present. Needs outbound network access, as a real deployment does
(container-signature downloads trust lists at startup).
EOF
}

cs_image=""
stamp_image=""
profiles=()
seals=3
boot_timeout=300
keep=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cs-image) cs_image="${2:-}"; shift 2;;
    --stamp-image) stamp_image="${2:-}"; shift 2;;
    --profile) profiles+=("${2:-}"); shift 2;;
    --seals) seals="${2:-}"; shift 2;;
    --boot-timeout) boot_timeout="${2:-}"; shift 2;;
    --keep) keep=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if ! [[ "$seals" =~ ^[0-9]+$ ]] || (( seals < 2 )); then
  echo "ERROR: --seals must be a whole number >= 2 (one seal cannot catch a" >&2
  echo "       profile that changes after its first use)." >&2
  exit 2
fi
if ! [[ "$boot_timeout" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --boot-timeout must be a whole number of seconds." >&2
  exit 2
fi
(( ${#profiles[@]} )) || profiles=(LocalDemo)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 2
  fi
}
need_cmd docker
need_cmd python3
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose v2 is required." >&2
  exit 2
fi

# shellcheck source=lib/digests.sh
. "${scripts_dir}/lib/digests.sh"

# Full pinned reference (repository:tag@sha256:...) from docker-compose.yml.
pinned_ref() {
  local repository="$1" pin
  pin="$(digest_from_compose "$repository" | tr -d '\r')"
  [[ -n "$pin" ]] && echo "${repository}:${pin}"
}
[[ -n "$cs_image" ]] || cs_image="$(pinned_ref trustlynx/container-signature-service || true)"
[[ -n "$stamp_image" ]] || stamp_image="$(pinned_ref trustlynx/digital-stamping-service || true)"
if [[ -z "$cs_image" || -z "$stamp_image" ]]; then
  echo "ERROR: could not read the container-signature / digital-stamping image from" >&2
  echo "       docker-compose.yml. Pass --cs-image and --stamp-image explicitly." >&2
  exit 2
fi

csig_src="${repo_root}/dmss-container-and-signature-services"
stamp_src="${repo_root}/dmss-digital-stamping-service"
[[ -f "${stamp_src}/seal/seal.p12" ]] || stamp_src="${repo_root}/installation-scripts/assets/dmss-digital-stamping-service"
for f in "${csig_src}/application.yml" "${csig_src}/documentsigningprofiles.json" \
         "${stamp_src}/application.yml" "${stamp_src}/seal/seal.p12"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing ${f}" >&2
    exit 2
  fi
done

project="padsign-seal-smoke-$$"
work="$(mktemp -d "${TMPDIR:-/tmp}/padsign-seal-smoke.XXXXXX")"
compose=(docker compose -p "$project" -f "${work}/compose.yml")

cleanup() {
  if $keep; then
    echo ""
    echo "Kept for inspection (--keep):"
    echo "  project: ${project}    temp dir: ${work}"
    echo "  remove:  docker compose -p ${project} -f ${work}/compose.yml down -v --remove-orphans && rm -rf ${work}"
    return
  fi
  "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# ---- stage a private copy of the config ----
cp -R "$csig_src" "${work}/dmss-container-and-signature-services"
cp -R "$stamp_src" "${work}/dmss-digital-stamping-service"
mkdir -p "${work}/smoke"
# container-signature writes the sealed PDFs here as its own non-root user
# (uid 999 in the 24.x images), not as whoever runs this script. Throwaway
# directory, removed on exit.
chmod 1777 "${work}/smoke"
# Same in-network stamping URL upgrade.sh/configure-host.sh write for
# --enable-local-eseal. Only this copy is edited.
sed -i.orig 's#^\(  baseUrl: \)http://host.docker.internal:8084/api#\1http://dmss-digital-stamping-service:8084/api#' \
  "${work}/dmss-container-and-signature-services/application.yml"
rm -f "${work}/dmss-container-and-signature-services/application.yml.orig"

# Test input: a small valid one-page PDF, written with correct xref offsets.
python3 - "${work}/smoke/input.pdf" <<'PY'
import sys
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
    None,
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
stream = b"BT /F1 18 Tf 72 770 Td (PadSign DMSS seal smoke test) Tj ET"
objs[3] = b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream"
out = bytearray(b"%PDF-1.7\n")
offsets = []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for off in offsets:
    out += b"%010d 00000 n \n" % off
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1], "wb").write(out)
PY

# Service names match docker-compose.yml's, so the in-network stamping URL is
# the real one; container names are left to compose (project-prefixed), and
# nothing is published to the host.
cat > "${work}/compose.yml" <<EOF
services:
  dmss-container-and-signature-services:
    image: '${cs_image}'
    volumes:
      - './dmss-container-and-signature-services:/confs'
      - './smoke:/smoke'
    environment:
      - SPRING_CONFIG_LOCATION=/confs/
      - SPRING_SECURITY_USER_NAME=user
      - SPRING_SECURITY_USER_PASSWORD=changeit
  dmss-digital-stamping-service:
    image: '${stamp_image}'
    environment:
      - SPRING_CONFIG_ADDITIONAL_LOCATION=file:/conf/
    volumes:
      - './dmss-digital-stamping-service:/conf:ro'
      - './dmss-digital-stamping-service/seal:/seal:ro'
EOF

failures=0
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; failures=$((failures + 1)); }
skip() { echo "  SKIP $*"; }
cs_logs() { "${compose[@]}" logs --no-color --no-log-prefix dmss-container-and-signature-services 2>&1; }
# Runs a command inside container-signature. The relative -f plus
# MSYS_NO_PATHCONV only matter under Git Bash (a dev/test convenience),
# which would otherwise rewrite in-container paths like /smoke/... into
# Windows paths; on Linux both are no-ops.
cs_exec() {
  (cd "$work" && MSYS_NO_PATHCONV=1 docker compose -p "$project" -f compose.yml \
    exec -T dmss-container-and-signature-services "$@")
}

echo "========================================"
echo "PadSign DMSS Boot + Seal Smoke Test"
echo "  container-signature: ${cs_image}"
echo "  digital-stamping:    ${stamp_image}"
echo "  profiles:            ${profiles[*]} (${seals} consecutive seals each)"
echo "  compose project:     ${project}"
echo "========================================"
echo ""

echo "== 1. Boot =="
if ! "${compose[@]}" up -d --quiet-pull >"${work}/up.log" 2>&1; then
  cat "${work}/up.log" >&2
  bad "docker compose up failed"
  exit 1
fi

state=""
health=""
deadline=$(( $(date +%s) + boot_timeout ))
while (( $(date +%s) < deadline )); do
  cid="$("${compose[@]}" ps -a -q dmss-container-and-signature-services 2>/dev/null || true)"
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
  if [[ "$state" == "exited" || "$state" == "dead" ]]; then
    break
  fi
  health="$(cs_exec curl -s -m 5 http://localhost:8092/actuator/health 2>/dev/null || true)"
  [[ "$health" == *'"status":"UP"'* ]] && break
  sleep 5
done

if [[ "$health" == *'"status":"UP"'* ]]; then
  ok "container-signature started, actuator health UP"
else
  if [[ "$state" == "exited" || "$state" == "dead" ]]; then
    bad "container-signature exited during startup (state: ${state})"
  else
    bad "container-signature did not report UP within ${boot_timeout}s (last health: ${health:-no response})"
  fi
  # Spring Boot's own failure summary, when there is one.
  cs_logs | tr -d '\r' | grep -a -A6 -E 'APPLICATION FAILED TO START|required a bean' | head -20 | sed 's/^/       /' || true
  echo ""
  echo "FAILED: ${failures} check(s)."
  exit 1
fi
echo ""

echo "== 2. Consecutive seals =="
for profile in "${profiles[@]}"; do
  for n in $(seq 1 "$seals"); do
    out="/smoke/out-${profile}-${n}.pdf"
    code="$(cs_exec curl -s -m 120 -u user:changeit -o "$out" -w '%{http_code}' \
      -F 'file=@/smoke/input.pdf;type=application/pdf' \
      "http://localhost:8092/api/eseal/document/profile/${profile}" 2>/dev/null || true)"
    host_out="${work}/smoke/out-${profile}-${n}.pdf"
    if [[ "$code" == "200" ]] && head -c 5 "$host_out" 2>/dev/null | grep -q '%PDF' \
       && grep -aq '/ByteRange' "$host_out"; then
      ok "${profile} seal ${n}/${seals}: HTTP 200, signed PDF ($(wc -c <"$host_out" | tr -d ' ') bytes)"
    elif [[ ! -f "$host_out" ]]; then
      bad "${profile} seal ${n}/${seals}: HTTP ${code:-none}, but no response body was written to ${out}"
    else
      detail="$(head -c 300 "$host_out" 2>/dev/null | tr -d '\0\r' | tr '\n' ' ' || true)"
      bad "${profile} seal ${n}/${seals}: HTTP ${code:-none} ${detail}"
    fi
  done
done
echo ""

echo "== 3. Signature level stable across seals =="
# container-signature logs "Signature level from request: <level>" once per
# seal (DEBUG, which this repo's application.yml enables). If a later seal
# logs a different level than the first, the image is rewriting the shared
# profile. This names the cause even if a reachable TSA made the upgraded
# level succeed.
levels="$(cs_logs | tr -d '\r' | grep -a -oE 'Signature level from request: [A-Za-z0-9_-]+' | awk '{print $NF}' || true)"
if [[ -z "$levels" ]]; then
  skip "this image does not log 'Signature level from request' - relying on check 2"
elif (( ${#profiles[@]} > 1 )); then
  # Levels are logged per request in order; check each profile's run of seals.
  i=0
  stable=true
  mapfile -t lv <<<"$levels"
  for profile in "${profiles[@]}"; do
    first="${lv[$i]:-}"
    for (( k = 0; k < seals; k++ )); do
      [[ "${lv[$((i + k))]:-}" == "$first" ]] || stable=false
    done
    echo "       ${profile}: $(printf '%s ' "${lv[@]:$i:$seals}")"
    i=$((i + seals))
  done
  $stable && ok "each profile kept the same signature level" || bad "a profile's signature level changed between seals"
else
  echo "       ${profiles[0]}: $(echo "$levels" | tr '\n' ' ')"
  if [[ "$(echo "$levels" | sort -u | wc -l | tr -d ' ')" == "1" ]]; then
    ok "signature level unchanged across ${seals} seals"
  else
    bad "signature level changed between seals (the image rewrites the shared profile)"
  fi
fi
tsa_errors="$(cs_logs | tr -d '\r' | grep -a -c 'Error getting timestamp' || true)"
if [[ "${tsa_errors:-0}" != "0" ]]; then
  echo "       container-signature logged ${tsa_errors} 'Error getting timestamp' line(s):"
  cs_logs | tr -d '\r' | grep -a 'Error getting timestamp' | head -3 | cut -c1-220 | sed 's/^/         /'
fi
echo ""

if (( failures )); then
  echo "FAILED: ${failures} check(s)."
  exit 1
fi
echo "PASSED: ${cs_image} boots and seals ${seals}x per profile with this repo's config."
