#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Tests for the image digest gate (lib/digest_gate.py via lib/digests.sh) and
# upgrade.sh's approved-tag refusal (psapp-saas#11).
#
# Usage:
#   ./installation-scripts/tests/test-digest-gate.sh
#
# Works on a throwaway copy of this checkout's tracked files (plus any
# uncommitted edits to them), so it never touches the real docker-compose.yml,
# .env or deployment-evidence.json. Runs every compose-model case twice: via
# `docker compose config` when docker is available, and via the plain-file
# fallback (PADSIGN_DIGEST_GATE_NO_DOCKER=1). Never pulls or starts anything.
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required" >&2; exit 2; }

# The caller's shell must not decide the model under test.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
repo="${work}/repo"
mkdir -p "$repo"
# Tracked files as they are on disk now (edits included, untracked excluded).
(cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
  | (cd "$src_root" && xargs -0 cp --parents -t "$repo" 2>/dev/null) || true
# Windows (for local runs only) resolves python3 paths as C:/...; Linux is a no-op.
if command -v cygpath >/dev/null 2>&1; then repo_native="$(cygpath -m "$repo")"; else repo_native="$repo"; fi

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }

# gate_output -> the digest gate's "<STATUS>\t<message>" lines for $repo.
gate_output() {
  (
    repo_root="$repo_native"
    # shellcheck source=../lib/digests.sh
    . "${repo}/installation-scripts/lib/digests.sh"
    compose_images_prime
    digest_gate_check
  )
}

expect_gate() {  # <case name> <expected FAIL count> [grep pattern that must appear]...
  local name="$1" want_fails="$2" out fails pat
  shift 2
  out="$(gate_output)"
  fails="$(grep -c '^FAIL' <<< "$out" || true)"
  if [[ "$fails" != "$want_fails" ]]; then
    fail_case "$name (expected ${want_fails} FAIL, got ${fails})" "$out"
    return
  fi
  for pat in "$@"; do
    if ! grep -qE -- "$pat" <<< "$out"; then
      fail_case "$name (missing: ${pat})" "$out"
      return
    fi
  done
  ok_case "$name"
}

d1="sha256:$(printf 'a%.0s' {1..64})"
d2="sha256:$(printf 'b%.0s' {1..64})"
overlay_dir="${work}/overlay"
mkdir -p "$overlay_dir"
if command -v cygpath >/dev/null 2>&1; then overlay_native="$(cygpath -m "$overlay_dir")"; else overlay_native="$overlay_dir"; fi
sep=":"; [[ "$overlay_native" == *:* ]] && sep=";"

use_overlay() {  # writes .env COMPOSE_FILE=docker-compose.yml<sep><overlay>
  printf 'COMPOSE_FILE=docker-compose.yml%s%s\n' "$sep" "${overlay_native}/compose.overlay.yml" > "${repo}/.env"
}
no_overlay() { rm -f "${repo}/.env" "${repo}/.overlay-applied.json" "${overlay_dir}/approved-digests.json"; }

run_model_cases() {
  local mode="$1"
  echo ""
  echo "Compose model via ${mode}:"

  no_overlay
  expect_gate "release checkout passes (all profiles covered)" 0 \
    '^OK[[:space:]]dmss-digital-stamping-service: ' '^OK[[:space:]]wizard: '

  cat > "${overlay_dir}/compose.overlay.yml" <<EOF
services:
  cert-renewer:
    image: "redis:7"
EOF
  use_overlay
  expect_gate "overlay adds a tag-only image" 1 'service cert-renewer: pinned by tag only'

  cat > "${overlay_dir}/compose.overlay.yml" <<EOF
services:
  extra:
    image: 'redis:7@${d2}'
EOF
  expect_gate "overlay adds a digest-pinned but unapproved image" 1 'service extra: .*unapproved image'

  cat > "${overlay_dir}/compose.overlay.yml" <<EOF
services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.3.2@${d1}
  wizard:
    image: mihailsgordijenko/padsign-wizard:0.1.1@${d2}
EOF
  expect_gate "overlay replaces a release image (and a profile-gated one)" 2 \
    'keycloak: pinned digest .*unapproved digest' 'wizard: pinned digest .*unapproved digest'

  printf '{"overlay_dir": "%s"}\n' "$overlay_native" > "${repo}/.overlay-applied.json"
  cat > "${overlay_dir}/approved-digests.json" <<EOF
{"images": {
  "keycloak-host": {"repository": "quay.io/keycloak/keycloak", "tag": "26.3.2", "digest": "${d1}", "why": "gate G1 test"},
  "no-why": {"repository": "mihailsgordijenko/padsign-wizard", "tag": "0.1.1", "digest": "${d2}"},
  "g2": {"repository": "mihailsgordijenko/ps-server", "tag": "3.99", "digest": "${d2}", "why": "must be refused"}
}}
EOF
  expect_gate "overlay approvals: reviewed entry accepted, no-why and G2 entries refused" 3 \
    '^OK[[:space:]]keycloak: .*approved for this environment' "entry 'no-why' has no 'why'" \
    "entry 'g2' approves mihailsgordijenko/ps-server" 'wizard: pinned digest'

  no_overlay
  printf 'COMPOSE_FILE=docker-compose.yml%s%s\n' "$sep" "${overlay_native}/missing.yml" > "${repo}/.env"
  expect_gate "COMPOSE_FILE names a missing file" 1 'does not exist'
  no_overlay
}

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  run_model_cases "docker compose config"
else
  echo ""
  echo "(docker compose not available - skipping the docker-backed model cases)"
fi
export PADSIGN_DIGEST_GATE_NO_DOCKER=1
run_model_cases "file fallback"
unset PADSIGN_DIGEST_GATE_NO_DOCKER

# ── upgrade.sh approved-tag gate ────────────────────────────────────────────
echo ""
echo "upgrade.sh approved-tag gate:"
approved() {  # <key> -> approved tag
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["images"][sys.argv[2]]["tag"])' \
    "${repo_native}/release/approved-digests.json" "$1"
}
srv_ok="$(approved ps-server)"; cli_ok="$(approved ps-client)"
before="$(cd "$repo" && sha256sum docker-compose.yml config/config.js)"

upgrade() { (cd "$repo" && bash installation-scripts/upgrade.sh "$@" 2>&1); }

set +e
out="$(upgrade --server-tag "$srv_ok" --client-tag "$cli_ok" --plan-only)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "approved; pinned to its approved digest" <<< "$out"; then ok_case "approved tags: --plan-only exits 0"
else fail_case "approved tags: --plan-only (rc=${rc})" "$out"; fi

for mode in "--plan-only" ""; do
  set +e
  out="$(upgrade --server-tag 99.99 ${mode})"; rc=$?
  set -e
  if [[ $rc -eq 2 ]] && grep -q "^ERROR: Refusing to upgrade .*ps-server:99.99 (approved: ${srv_ok})" <<< "$out"; then
    ok_case "unapproved tag refused, exit 2 (${mode:-real run})"
  else
    fail_case "unapproved tag refused (${mode:-real run}, rc=${rc})" "$out"
  fi
done
after="$(cd "$repo" && sha256sum docker-compose.yml config/config.js)"
if [[ "$before" == "$after" ]] && ! ls "$repo" | grep -qE '\.bak$|^deployment-evidence' && [[ ! -d "${repo}/.rollback-snapshots" ]]; then
  ok_case "a refused run wrote nothing (no edit, backup, snapshot or evidence)"
else
  fail_case "a refused run wrote something" "$(ls -a "$repo")"
fi

set +e
out="$(upgrade --server-tag 99.99 --plan-only --allow-unapproved)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -q "UNAPPROVED OVERRIDE (--allow-unapproved): ps-server:99.99" <<< "$out"; then
  ok_case "--allow-unapproved: --plan-only reports the override"
else
  fail_case "--allow-unapproved --plan-only (rc=${rc})" "$out"
fi

set +e
out="$(upgrade --client-tag 99.99 --plan-only --allow-unapproved --plan-format machine)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && grep -qx "unapproved_override=ps-client:99.99:${cli_ok}" <<< "$out"; then
  ok_case "--allow-unapproved: machine plan carries unapproved_override="
else
  fail_case "--allow-unapproved machine plan (rc=${rc})" "$out"
fi

# ── Order: approved-tag gate, then the cosign pre-flight, then any write ────
# Stub `cosign` (COSIGN_STUB=pass|fail|old) and a stub `docker` that fails
# everything, so no case here can reach a real registry or container, even
# if the order were wrong. Every call is logged.
echo ""
echo "upgrade.sh gate order (stub cosign / docker):"
stubs="${work}/stubs"
mkdir -p "$stubs"
cat > "${stubs}/cosign" <<'EOF'
#!/usr/bin/env bash
echo "cosign $*" >> "${STUB_LOG:?}"
case "$1" in
  version) [[ "${COSIGN_STUB:-pass}" == old ]] && echo '{"gitVersion": "v2.4.1"}' || echo '{"gitVersion": "v3.1.3"}'; exit 0;;
esac
[[ "${COSIGN_STUB:-pass}" == pass ]] && exit 0
echo "Error: no matching signatures: stub" >&2
exit 1
EOF
cat > "${stubs}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG:?}"
exit 1
EOF
chmod +x "${stubs}/cosign" "${stubs}/docker"
export STUB_LOG="${work}/stub-calls.log"

stubbed() {  # <COSIGN_STUB> [upgrade.sh args]...
  local mode="$1"; shift
  : > "$STUB_LOG"
  (cd "$repo" && COSIGN_STUB="$mode" PATH="${stubs}:${PATH}" bash installation-scripts/upgrade.sh "$@" 2>&1)
}
nothing_written() {
  [[ "$before" == "$(cd "$repo" && sha256sum docker-compose.yml config/config.js)" ]] \
    && ! ls "$repo" | grep -qE '\.bak$|^deployment-evidence' && [[ ! -d "${repo}/.rollback-snapshots" ]] \
    && ! grep -q '^docker compose pull' "$STUB_LOG"
}
unset CI PADSIGN_REQUIRE_SIGNATURES

set +e
out="$(stubbed pass --server-tag 99.99)"; rc=$?
set -e
if [[ $rc -eq 2 ]] && ! grep -q '^cosign' "$STUB_LOG"; then ok_case "unapproved tag is refused before cosign is ever called"
else fail_case "approval before signature (rc=${rc})" "$out"$'\n'"$(cat "$STUB_LOG")"; fi

set +e
out="$(stubbed pass --server-tag "$srv_ok" --plan-only)"; rc=$?
set -e
if [[ $rc -eq 0 ]] && ! grep -q '^cosign' "$STUB_LOG"; then ok_case "--plan-only does not call cosign"
else fail_case "--plan-only calls cosign (rc=${rc})" "$(cat "$STUB_LOG")"; fi

set +e
out="$(stubbed fail --server-tag "$srv_ok")"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "image signature does not verify" <<< "$out" && nothing_written; then
  ok_case "signature that does not verify: refused, no snapshot/backup/edit/pull"
else
  fail_case "signature refusal (rc=${rc})" "$out"$'\n'"$(ls -a "$repo")"
fi

set +e
out="$(stubbed fail --server-tag 99.99 --allow-unapproved)"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "WARNING: --allow-unapproved" <<< "$out" && grep -q "does not verify" <<< "$out" && nothing_written; then
  ok_case "--allow-unapproved still needs a verifying signature; nothing written"
else
  fail_case "--allow-unapproved + bad signature (rc=${rc})" "$out"
fi

set +e
out="$(PADSIGN_REQUIRE_SIGNATURES=1 stubbed old --server-tag "$srv_ok")"; rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q "too old" <<< "$out" && nothing_written; then
  ok_case "unusable cosign with PADSIGN_REQUIRE_SIGNATURES=1: refused, nothing written"
else
  fail_case "required signatures without usable cosign (rc=${rc})" "$out"
fi

set +e
out="$(stubbed pass --server-tag "$srv_ok")"; rc=$?
set -e
sig_line="$(grep -n "signature, SBOM and provenance attestations verify" <<< "$out" | head -1 | cut -d: -f1)"
step1_line="$(grep -n "^Step 1/6" <<< "$out" | head -1 | cut -d: -f1)"
if [[ -n "$sig_line" && -n "$step1_line" && "$sig_line" -lt "$step1_line" ]]; then
  ok_case "verified signature: pre-flight passes, then Step 1 (stub docker then fails the pull, rc=${rc})"
else
  fail_case "verified signature path (rc=${rc})" "$out"
fi
# That run wrote a snapshot, backups and evidence into the copy; reset them.
rm -rf "${repo}/.rollback-snapshots" "${repo}"/*.bak "${repo}"/config/*.bak "${repo}"/deployment-evidence.json*
(cd "$src_root" && cp docker-compose.yml "${repo}/docker-compose.yml" && cp config/config.js "${repo}/config/config.js")

# ── deployment-evidence.json record ─────────────────────────────────────────
echo ""
echo "deployment-evidence.json unapproved_override:"
ev_list() {  # -> "image:tag" per recorded override
  python3 -c 'import json,sys; print(" ".join("%s:%s" % (e["image"], e["tag"]) for e in json.load(open(sys.argv[1]))["unapproved_override"]))' \
    "${repo_native}/deployment-evidence.json"
}
write_ev() {  # <script name> [override lines]
  (
    repo_root="$repo_native"
    # shellcheck source=../lib/deployment-evidence.sh
    . "${repo}/installation-scripts/lib/deployment-evidence.sh"
    deployment_evidence_unapproved_override="${2:-}"
    cd "$repo"
    write_deployment_evidence "$1" >/dev/null
  )
}
# Pretend the hotfix landed: compose pins the unapproved client tag.
sed -i -E "s|mihailsgordijenko/ps-client:[0-9.]+(@sha256:[0-9a-f]+)?|mihailsgordijenko/ps-client:99.99|" "${repo}/docker-compose.yml"
write_ev "upgrade.sh" "$(printf 'ps-client\t99.99\t%s' "$cli_ok")"
[[ "$(ev_list)" == "ps-client:99.99" ]] && ok_case "recorded by the --allow-unapproved run" || fail_case "recorded by the run" "$(ev_list)"
write_ev "postdeploy-check.sh"
[[ "$(ev_list)" == "ps-client:99.99" ]] && ok_case "carried forward while the tag is still pinned and unapproved" || fail_case "carried forward" "$(ev_list)"
sed -i -E "s|mihailsgordijenko/ps-client:99.99|mihailsgordijenko/ps-client:${cli_ok}|" "${repo}/docker-compose.yml"
write_ev "postdeploy-check.sh"
[[ -z "$(ev_list)" ]] && ok_case "dropped once the pin moves off the unapproved tag" || fail_case "dropped after re-pin" "$(ev_list)"

echo ""
echo "${pass} passed, ${failed} failed."
[[ "$failed" -eq 0 ]]
