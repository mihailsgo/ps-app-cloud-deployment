#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Tests for three gaps found when the demo host's EC2 instance was stopped
# and started (psapp-saas#7, #12):
#
#   - host boot/cron hooks: overlay.sh capture and verify list the systemd
#     units, cron entries, rc.local and init scripts that name the old
#     checkout or run docker compose (an enabled padsign.service still
#     pointing at the old directory brought the OLD stack back at the first
#     reboot after the cut-over). Runs against a fake host root
#     (PADSIGN_HOST_SCAN_ROOT), never the real /etc;
#   - start-up windows: every DMSS JVM's health-check window covers the
#     measured cold-boot start, and the scripts' health waits are not
#     shorter than any service's window;
#   - nginx: /api/ waits longer than ps-server's worst case, so ps-server's
#     own answer reaches the browser instead of nginx's 504 page;
#   - the boot unit shipped in installation-scripts/assets/.
#
# Usage:
#   ./installation-scripts/tests/test-boot-and-timeouts.sh
#
# Works on throwaway copies of this checkout's tracked files (edits
# included). `docker` is a stub: `compose config` / `version` go to the real
# docker when there is one, `run` fakes the image uid:gid and the in-image
# read probe, everything else fails. Nothing is pulled or started. The
# symlink and unreadable-directory cases need Linux (Git Bash has neither).
#
# Exit codes: 0 all passed, 1 a case failed, 2 missing dependency.
# ============================================================================

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for c in python3 git; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR PADSIGN_DIGEST_GATE_NO_DOCKER PADSIGN_HOST_SCAN_ROOT

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
linux=false; [[ "$(uname -s)" == Linux ]] && linux=true
real_docker=""
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  real_docker="$(command -v docker)"
fi

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() {  # <name> <command...>: PASS if the command succeeds
  local name="$1"; shift
  if "$@"; then ok_case "$name"; else fail_case "$name"; fi
}
has()     { grep -qF -- "$2" <<< "$1"; }            # <text> <fixed string>
has_re()  { grep -qE -- "$2" <<< "$1"; }            # <text> <ERE>
lacks()   { ! grep -qF -- "$2" <<< "$1"; }

native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

copy_tree() {  # <dest>: tracked files as they are on disk now
  mkdir -p "$1"
  (cd "$src_root" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$src_root" && xargs -0 cp --parents -t "$1" 2>/dev/null) || true
}

# ── start-up windows, nginx timeout, boot unit (static checks) ─────────────
echo "Start-up windows and timeouts:"
windows="$(python3 - "$(native "${src_root}/docker-compose.yml")" <<'PY'
import re, sys
# Minimal reader for this repo's compose layout: services at 2 spaces,
# healthcheck keys at 6. Prints "<service> <start_period> <window>" where
# window = start_period + retries x (interval + timeout), in seconds.
def secs(v):
    m = re.fullmatch(r"(\d+)(s|m)?", v.strip().strip("'\""))
    return int(m.group(1)) * (60 if m.group(2) == "m" else 1)
svc, hc, vals = None, False, {}
def flush():
    if svc and {"interval", "timeout", "retries", "start_period"} <= vals.keys():
        w = vals["start_period"] + vals["retries"] * (vals["interval"] + vals["timeout"])
        print(svc, vals["start_period"], w)
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.split(" #", 1)[0].rstrip()
    m = re.match(r"^  ([a-z0-9-]+):$", line)
    if m:
        flush(); svc, hc, vals = m.group(1), False, {}
        continue
    if re.match(r"^    healthcheck:$", line):
        hc = True; continue
    if re.match(r"^    [a-z_]+:", line):
        hc = False
    m = re.match(r"^      (interval|timeout|retries|start_period):\s*(\S+)$", line)
    if hc and m:
        vals[m.group(1)] = int(m.group(2)) if m.group(1) == "retries" else secs(m.group(2))
flush()
PY
)"
check "every long-running service has a parsable health-check window" \
  bash -c '[[ "$(wc -l <<< "$1")" -ge 8 ]]' _ "$windows"
dmss_short="$(awk '$1 ~ /^dmss-/ && $2 < 300 {print $1}' <<< "$windows")"
check "every DMSS JVM: start_period >= 300s (demo cold boot: 213 s to UP; old window 160 s)" test -z "$dmss_short"
max_window="$(awk '$1 != "wizard" && $3 > m {m = $3} END {print m}' <<< "$windows")"
default_of() { sed -nE 's/^health_timeout=([0-9]+)$/\1/p' "${src_root}/installation-scripts/$1"; }
for s in upgrade.sh rollback.sh; do
  check "${s} --health-timeout default ($(default_of "$s")s) >= the longest health-check window (${max_window}s)" \
    test "$(default_of "$s")" -ge "$max_window"
done
bs="$(sed -nE 's/.*wait_for_healthy ([0-9]+) .*/\1/p' "${src_root}/installation-scripts/bootstrap.sh" | head -1)"
check "bootstrap.sh health wait (${bs}s) >= the longest health-check window (${max_window}s)" test "$bs" -ge "$max_window"

api_timeout="$(tr -d '\r' < "${src_root}/nginx/nginx.conf" | awk '
  /location \/api\/ \{/ { on = 1 } on && /^[[:space:]]*proxy_read_timeout/ { gsub(/[^0-9]/, "", $2); print $2; exit } on && /^    \}/ { on = 0 }')"
# ps-server 3.32 defaults: stamp 3 x 30 s + 1.5 s back-off = 91.5 s,
# registerPDF 30 + 3 x 15 + 1.8 + 20.5 = 97.3 s (derivation in nginx.conf).
check "nginx /api/ proxy_read_timeout (${api_timeout:-unset}s) > ps-server's worst case (97.3 s)" \
  bash -c '[[ -n "$1" && "$1" -gt 98 ]]' _ "$api_timeout"

unit="${src_root}/installation-scripts/assets/padsign.service.example"
u="$(grep -vE '^\s*#' "$unit" 2>/dev/null | tr -d '\r')"
check "boot unit: WorkingDirectory is the padsign-current symlink" has "$u" "WorkingDirectory=/opt/trustlynx/padsign-current"
check "boot unit: no -f/--file (it would ignore the overlay's COMPOSE_FILE)" bash -c '! grep -qE "docker compose.*(\s-f|--file)" <<< "$1"' _ "$u"
check "boot unit: never 'down' (it removes the containers)" bash -c '! grep -qE "docker compose[^\"]*\bdown\b" <<< "$1"' _ "$u"
check "boot unit: ExecStop is 'docker compose stop'" has "$u" "ExecStop=/usr/bin/docker compose stop"
check "boot unit: ExecStart retries 'docker compose up -d'" has_re "$u" 'ExecStart=.*for i in 1 2 3 4 5; do /usr/bin/docker compose up -d && exit 0;.*sleep 30'
check "boot unit: TimeoutStartSec=0, Type=oneshot, RemainAfterExit=yes, enabled by multi-user.target" \
  bash -c 'for l in TimeoutStartSec=0 Type=oneshot RemainAfterExit=yes WantedBy=multi-user.target; do grep -qx "$l" <<< "$1" || exit 1; done' _ "$u"

# ── docker stub ─────────────────────────────────────────────────────────────
bin="${work}/bin"
mkdir -p "$bin"
export STUB_LOG="${work}/docker-argv.log" REAL_DOCKER="$real_docker" STUB_IDS="$(id -u):$(id -g)"
cat > "${bin}/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$1" in
  compose)
    for a in "$@"; do
      if [[ "$a" == config || "$a" == version ]]; then
        [[ -n "${REAL_DOCKER:-}" ]] && exec "$REAL_DOCKER" "$@"
        exit 1
      fi
    done
    exit 1 ;;
  run)
    if [[ "$*" == *padsign-probe* ]]; then echo READABLE; exit 0; fi
    if [[ "$*" == *'id -u'* ]]; then echo "$STUB_IDS"; exit 0; fi
    exit 1 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "${bin}/docker"
# `crontab` must never be reached with a scan root set; a stub proves it.
printf '#!/bin/sh\necho CRONTAB-STUB-REACHED\n' > "${bin}/crontab"
chmod +x "${bin}/crontab"
export PATH="${bin}:${PATH}"

# ── a release, an old host checkout, a fake host root ──────────────────────
g() { git -c user.email=test@example.invalid -c user.name=test -c init.defaultBranch=main "$@"; }
rel="${work}/release"
copy_tree "$rel"
(cd "$rel" && g init -q && g add -A && g commit -qm release) >/dev/null
old="${work}/old"
g clone -q "$rel" "$old"
perl -i -pe 's/(DEMO_COMPANY_ROLE:\s*")[^"]*/${1}HostCo/' "$old/config/config.js" 2>/dev/null || true
mkdir -p "$old/signed-output" "$old/docs"
new="${work}/new"
g clone -q "$rel" "$new"
O="$(native "$old")"; N="$(native "$new")"
current="${work}/padsign-current"

hr="${work}/hostroot"
mkdir -p "$hr/etc/systemd/system/multi-user.target.wants" "$hr/etc/cron.d" "$hr/etc/cron.daily" \
         "$hr/var/spool/cron/crontabs" "$hr/etc/init.d"
# The demo host's unit, as found on 2026-09-26.
cat > "$hr/etc/systemd/system/padsign.service" <<EOF
[Unit]
Description=PadSign
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${O}
ExecStartPre=/usr/bin/docker compose -f ${O}/docker-compose.yml down
ExecStart=/usr/bin/docker compose -f ${O}/docker-compose.yml up -d
ExecStop=/usr/bin/docker compose -f ${O}/docker-compose.yml down

[Install]
WantedBy=multi-user.target
EOF
cp "$hr/etc/systemd/system/padsign.service" "$hr/etc/systemd/system/multi-user.target.wants/padsign.service"
cat > "$hr/etc/systemd/system/padsign-cleanup.service" <<EOF
[Service]
Type=oneshot
ExecStart=/bin/sh -c "cd ${O} && docker compose down -v --remove-orphans"
EOF
printf '[Service]\nExecStart=/usr/bin/true\n' > "$hr/etc/systemd/system/unrelated.service"
printf '[Service]\n# WorkingDirectory=%s\nExecStart=/usr/bin/true\n' "$O" > "$hr/etc/systemd/system/commented.service"
printf '[Service]\nWorkingDirectory=%s-sibling\nExecStart=/usr/bin/true\n' "$O" > "$hr/etc/systemd/system/sibling.service"
cat > "$hr/etc/cron.d/padsign-monitor" <<EOF
SHELL=/bin/bash
*/5 * * * * root cd ${O} && ALERT_WEBHOOK_URL=https://hooks.example.invalid/services/T0/B0/SEKRETPATH ./installation-scripts/monitor-status.sh --alert
0 4 * * * root cd ${O} && KEYCLOAK_ADMIN_PASSWORD=HUNTER2PW ./installation-scripts/verify-keycloak.sh --host x --admin-pass HUNTER3PW
EOF
printf '#!/bin/sh\ntar czf /var/backups/signed.tgz -C %s/signed-output .\n' "$O" > "$hr/etc/cron.daily/padsign-backup"
printf '#!/bin/sh -e\ndocker-compose -p other-stack up -d\nexit 0\n' > "$hr/etc/rc.local"
printf '@reboot sleep 60 && cd %s && docker compose up -d\n' "$O" > "$hr/var/spool/cron/crontabs/deploy"
printf '17 * * * * root cd / && run-parts --report /etc/cron.hourly\n' > "$hr/etc/crontab"
export PADSIGN_HOST_SCAN_ROOT="$(native "$hr")"
tree_state() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs sha256sum); }
hr_before="$(tree_state "$hr")"

# ── capture ─────────────────────────────────────────────────────────────────
echo ""
echo "overlay.sh capture: host boot/cron hooks"
ovl="${work}/overlay"
out="$(cd "$new" && bash installation-scripts/overlay.sh capture --baseline "$N" --from "$O" --out "$(native "$ovl")" 2>&1)"; rc=$?
check "capture exits 0 (hooks are WARNs, not failures)" test "$rc" = 0
check "WARN: the enabled padsign.service references the old checkout" \
  has_re "$out" "WARN /etc/systemd/system/padsign.service \(systemd unit, enabled \(multi-user.target.wants\)\): references the old checkout"
check "... it says what to do (42.4 C4)" has "$out" "repoint it at the new checkout or disable it in the cut-over window (42.4 C4)"
check "WARN: padsign.service passes -f (ignores the overlay's COMPOSE_FILE)" \
  has "$out" "WARN /etc/systemd/system/padsign.service: passes -f/--file to docker compose"
check "... and its lines are listed" has "$out" "line 10: ExecStartPre=/usr/bin/docker compose -f ${O}/docker-compose.yml down"
check "WARN: a cron.d job that cd's into the old checkout" \
  has_re "$out" "WARN /etc/cron.d/padsign-monitor \(cron.d entry\): references the old checkout"
check "WARN: root-only user crontab (@reboot) read from the spool" \
  has_re "$out" "WARN /var/spool/cron/crontabs/deploy \(crontab of deploy\): references the old checkout"
check "WARN: a not-enabled unit with down -v" \
  bash -c 'grep -qE "WARN /etc/systemd/system/padsign-cleanup.service \(systemd unit, not enabled\): references" <<< "$1" && grep -qF "runs \`docker compose down\` with -v/--volumes" <<< "$1"' _ "$out"
check "WARN: rc.local runs docker compose for no known checkout" \
  has "$out" "WARN /etc/rc.local (rc.local): runs docker compose, but does not name"
check "not reported: a unit that does not name the checkout, a commented-out line, a sibling directory" \
  bash -c '! grep -qE "unrelated.service|commented.service|sibling.service" <<< "$1"' _ "$out"
check "not reported: /etc/crontab without a match" lacks "$out" "/etc/crontab ("
check "the webhook URL's secret path is not printed" lacks "$out" "SEKRETPATH"
check "an inline KEYCLOAK_ADMIN_PASSWORD= and an --admin-pass value are not printed" \
  bash -c '! grep -qE "HUNTER2PW|HUNTER3PW" <<< "$1"' _ "$out"
check "... the webhook value is shown as <redacted>" has "$out" "ALERT_WEBHOOK_URL=<redacted>"
check "crontab -l is never run with a scan root" lacks "$out" "CRONTAB-STUB-REACHED"
check "points at the rebuild checklist (hooks are not in the overlay)" has "$out" "on a rebuilt host, re-create the ones you keep"
if [[ -n "$real_docker" ]]; then
  check "a backup job for the signed documents (storage stays in the old tree) is not flagged" lacks "$out" "padsign-backup"
fi
dev="$(cat "$ovl/DEVIATIONS.md" 2>/dev/null)"
check "DEVIATIONS.md: new section" has "$dev" "## Host boot/cron hooks that reference the old checkout or run docker compose"
check "DEVIATIONS.md: padsign.service entry, enabled, compose commands (not the docker-compose.yml path), -f" \
  has_re "$dev" '^- `/etc/systemd/system/padsign.service` \(systemd unit, enabled \(multi-user.target.wants\)\): \*\*references the old checkout\*\* .*; runs `docker compose down`, `up`; passes `-f`'
check "DEVIATIONS.md: the user crontab entry" has "$dev" '- `/var/spool/cron/crontabs/deploy` (crontab of deploy)'
check "DEVIATIONS.md and MANIFEST.json: no webhook secret, no password" \
  bash -c '! grep -qE "SEKRETPATH|HUNTER2PW|HUNTER3PW" "$1/DEVIATIONS.md" "$1/MANIFEST.json"' _ "$ovl"
hooks="$(python3 -c 'import json,sys; print(" ".join(sorted(h["path"] for h in json.load(open(sys.argv[1]))["host_hooks"]["hooks"])))' "$(native "$ovl/MANIFEST.json")" 2>&1)"
want="/etc/cron.d/padsign-monitor /etc/rc.local /etc/systemd/system/padsign-cleanup.service /etc/systemd/system/padsign.service /var/spool/cron/crontabs/deploy"
[[ -z "$real_docker" ]] && want="/etc/cron.d/padsign-monitor /etc/cron.daily/padsign-backup /etc/rc.local /etc/systemd/system/padsign-cleanup.service /etc/systemd/system/padsign.service /var/spool/cron/crontabs/deploy"
check "MANIFEST.json host_hooks lists exactly the matching hooks" test "$hooks" = "$want"
check "capture changed nothing under the host root" test "$hr_before" = "$(tree_state "$hr")"

# ── verify, before and after repointing ────────────────────────────────────
echo ""
echo "overlay.sh verify: host boot/cron hooks"
(cd "$new" && bash installation-scripts/overlay.sh apply --overlay "$(native "$ovl")" >/dev/null 2>&1) || true
section() { awk '/^== Host boot and cron hooks/ { on = 1; next } /^== / { on = 0 } on' <<< "$1"; }
out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" --live "$O" 2>&1)"
sec="$(section "$out")"
check "verify --live: the section is printed" has "$out" "== Host boot and cron hooks"
check "verify --live: WARN padsign.service references the old checkout" \
  has_re "$sec" "WARN /etc/systemd/system/padsign.service .*references the old checkout"
out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" 2>&1)"
sec="$(section "$out")"
check "verify without --live (C5/C6): still flags hooks naming the directory the overlay was captured from" \
  has_re "$sec" "WARN /var/spool/cron/crontabs/deploy .*references the old checkout"

# Repoint, as 42.4 C4 does: the release's boot unit over the old one, the
# cron job through the symlink, the rest removed.
if $linux; then
  ln -s "$old" "$current"
  sed "s#/opt/trustlynx/padsign-current#${current}#" "$unit" > "$hr/etc/systemd/system/padsign.service"
  out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" 2>&1)"
  check "the new unit while padsign-current still points at the old checkout: WARN, via the symlink" \
    has_re "$(section "$out")" "WARN /etc/systemd/system/padsign.service .*references the old checkout ${old} \(via ${current}\)"
  ln -sfn "$new" "$current"
  cur="$current"
else
  cur="$N"
  sed "s#/opt/trustlynx/padsign-current#${cur}#" "$unit" > "$hr/etc/systemd/system/padsign.service"
fi
cp "$hr/etc/systemd/system/padsign.service" "$hr/etc/systemd/system/multi-user.target.wants/padsign.service"
sed -i "s#cd ${O}#cd ${cur}#" "$hr/etc/cron.d/padsign-monitor"
rm -f "$hr/var/spool/cron/crontabs/deploy" "$hr/etc/systemd/system/padsign-cleanup.service" "$hr/etc/rc.local"
# Without docker, capture could not read the storage mounts, so the backup job
# for the documents (which stay in the old tree) is flagged too: drop it.
[[ -z "$real_docker" ]] && rm -f "$hr/etc/cron.daily/padsign-backup"
out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" --live "$O" 2>&1)"
sec="$(section "$out")"
check "after repointing: OK, the boot unit runs docker compose for this checkout" \
  has "$sec" "OK   /etc/systemd/system/padsign.service (systemd unit, enabled (multi-user.target.wants)): runs docker compose for this checkout"
check "after repointing: the cron job references this checkout" has "$sec" "OK   /etc/cron.d/padsign-monitor (cron.d entry): references this checkout"
check "after repointing: no hook references the old checkout" lacks "$sec" "references the old checkout"
check "after repointing: no -f warning for the release's unit" lacks "$sec" "passes -f/--file"

if $linux && [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$hr/var/spool/cron/crontabs"
  out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" 2>&1)"
  check "an unreadable crontab spool is named, not a traceback" \
    bash -c 'grep -qF "not scanned: /var/spool/cron/crontabs/ (not readable as" <<< "$1" && ! grep -q Traceback <<< "$1"' _ "$out"
  chmod 755 "$hr/var/spool/cron/crontabs"
fi

export PADSIGN_HOST_SCAN_ROOT="$(native "${work}/empty-root")"
mkdir -p "${work}/empty-root"
out="$(cd "$new" && bash installation-scripts/overlay.sh verify --overlay "$(native "$ovl")" 2>&1)"
check "a host with none of these locations: OK, nothing found" \
  has "$(section "$out")" "OK   no systemd unit, cron entry, rc.local or init script names"

echo ""
echo "================================"
echo "${pass} passed, ${failed} failed"
[[ "$failed" == 0 ]]
