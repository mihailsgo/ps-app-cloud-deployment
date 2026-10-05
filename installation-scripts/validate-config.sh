#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# PadSign Config Validator — checks syntax and consistency of all config files
#
# Usage:
#   ./installation-scripts/validate-config.sh [--host example.com]
# ============================================================================

host=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    -h|--help) echo "Usage: $0 [--host example.com]"; exit 0;;
    *) shift;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compose-hostname.sh
. "${repo_root}/installation-scripts/lib/compose-hostname.sh"
# shellcheck source=lib/capabilities.sh
. "${repo_root}/installation-scripts/lib/capabilities.sh"

fail=0
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
warn() { printf '  WARN %s\n' "$*"; }
# Not a pass or a failure: something this run cannot look at (an overlay's
# storage the caller cannot read, a named volume). The wizard shows it as INFO.
info() { printf '  INFO %s\n' "$*"; }

# The EFFECTIVE compose model: run from the project directory without -f, so
# .env's COMPOSE_FILE (an environment overlay, see installation-scripts/
# overlay.sh), COMPOSE_PROFILES and COMPOSE_PROJECT_NAME apply exactly as they
# do for `docker compose up`. `-f docker-compose.yml` would silently skip an
# overlay file - including any port it publishes, which is precisely what the
# port-binding check below exists to catch.
compose_config() {
  (cd "$repo_root" && docker compose config "$@")
}

echo "PadSign Configuration Validator"
echo "================================"

# --- File existence ---
echo ""
echo "File checks:"
for f in config/config.js config/constants.json nginx/nginx.conf docker-compose.yml; do
  if [[ -f "${repo_root}/${f}" ]]; then
    ok "$f exists"
  else
    bad "$f missing"
  fi
done
# config.js is mode 640 with the ps-server image's group once configure-host.sh
# has restricted it (lib/dir-permissions.sh); another user cannot read it, and
# every check below that does would report nonsense.
if [[ -f "${repo_root}/config/config.js" && ! -r "${repo_root}/config/config.js" ]]; then
  warn "config/config.js is not readable by $(id -un 2>/dev/null || id -u) - run this as root or as a member of its group ($(stat -c '%G, gid %g' "${repo_root}/config/config.js" 2>/dev/null || echo '?')); the checks below that read it are unreliable"
fi

# --- JSON syntax ---
echo ""
echo "Syntax checks:"
if python3 -m json.tool "${repo_root}/config/constants.json" > /dev/null 2>&1; then
  ok "constants.json is valid JSON"
else
  bad "constants.json is invalid JSON"
fi

if compose_config > /dev/null 2>&1; then
  ok "docker-compose.yml is valid"
else
  bad "docker-compose.yml has errors"
fi

# --- DOCUMENT_ROUTING ---
echo ""
echo "Feature checks:"
if grep -q 'DOCUMENT_ROUTING' "${repo_root}/config/config.js"; then
  ok "DOCUMENT_ROUTING present in config.js"
else
  bad "DOCUMENT_ROUTING missing from config.js"
fi

# Where the signed-document stores actually are: what the effective compose
# model mounts at ps-server's /signed-output and the fallback archive's /docs
# (lib/dir-permissions.sh storage_mount, which reads `docker compose config
# --format json` like the port-binding check below). Normally the in-tree
# ./signed-output and ./docs, but an environment overlay (overlay.sh) or a
# docker-compose.override.yml can mount them from an absolute path elsewhere,
# or from a named volume, instead.
# shellcheck source=lib/dir-permissions.sh
. "${repo_root}/installation-scripts/lib/dir-permissions.sh"
store_mounts="$(effective_mounts)"
signed_output_mount "$store_mounts"
signed_output_how="$storage_how"; signed_output_dir="$storage_path"
docs_mount "$store_mounts"
docs_how="$storage_how"; docs_dir="$storage_path"

case "$signed_output_how" in
  bind|volume) ok "signed-output volume mount in docker-compose.yml" ;;
  none)        bad "signed-output volume mount missing from docker-compose.yml (the effective compose model has no /signed-output mount for ps-server)" ;;
  *)  # the model could not be read: look in the file itself
    if grep -q 'signed-output:/signed-output' "${repo_root}/docker-compose.yml"; then
      ok "signed-output volume mount in docker-compose.yml"
    else
      bad "signed-output volume mount missing from docker-compose.yml"
    fi ;;
esac
if [[ "$signed_output_how" == bind && "$signed_output_dir" != "${repo_root}/signed-output" ]]; then
  ok "signed-output is mounted from ${signed_output_dir} (environment overlay)"
fi
if [[ "$docs_how" == bind && "$docs_dir" != "${repo_root}/docs" ]]; then
  ok "docs is mounted from ${docs_dir} (environment overlay)"
fi

# Ownership checks (below) need the same image-uid resolution the scripts
# that create these directories use (lib/dir-permissions.sh, sourced above).

# Reports whether <dir>'s tree is owned by the uid <repository>'s pinned image
# runs as. Skipped (not failed) when that can't be determined, e.g. no docker.
#
# upgrade.sh (lib/dir-permissions.sh) only creates/re-owns the in-tree
# ./signed-output and ./docs, so it is only offered as the fix for those - an
# environment-overlay mount elsewhere has to be fixed at its real path.
in_tree_store() {  # <dir>
  [[ "$1" == "${repo_root}/signed-output" || "$1" == "${repo_root}/docs" ]]
}

check_tree_owner() {  # <dir> <repository> <label>
  local ref ids uid foreign fix
  ref="$(pinned_image_ref "$2")"
  if ! ids="$(image_runtime_ids "$ref")"; then
    ok "$3 ownership not checked (could not resolve which uid ${ref:-$2} runs as)"
    return
  fi
  uid="${ids%%:*}"
  if [[ "$uid" == 0 ]]; then
    ok "$3 ownership: ${ref} runs as root"
  elif ! foreign="$(first_foreign_path "$1" "$uid" "$ref")"; then
    bad "$3 could not be inspected (as this user or via ${ref}); it must be owned by ${ids}"
  elif [[ -n "$foreign" ]]; then
    if in_tree_store "$1"; then
      fix="re-run upgrade.sh (it re-owns the tree), or sudo chown -R ${ids} $1"
    else
      fix="sudo chown -R ${ids} $1 (an environment-overlay mount: upgrade.sh does not re-own it)"
    fi
    bad "$3: ${foreign#"${repo_root}/"} is not owned by ${uid}, the user ${ref} runs as, so that container cannot write there. Fix: ${fix}"
  else
    ok "$3 owned by ${ids} (the user ${ref} runs as)"
  fi
}

world_writable() {
  # Matches if "other" has the write bit set, portable across GNU/BSD find.
  find "$1" -maxdepth 0 -perm -002 2>/dev/null | grep -q .
}

# Says why a store that is not a directory this run can see was not checked.
# Sets store_skipped=true for the states that are not failures: a named
# volume, a path this process cannot read, a path the wizard container does
# not mount. A missing or non-directory path is the caller's to report.
store_skipped=false
store_unchecked() {  # <label> <how> <path>, after store_probe <path>
  store_skipped=false
  if [[ "$2" == volume ]]; then
    store_skipped=true
    info "$1 is a named Docker volume: there is no host directory to check (see 'docker system df -v')"
    return 0
  fi
  case "$store_state" in
    denied)
      store_skipped=true
      info "$1 at $3 cannot be inspected: permission denied for $(id -un 2>/dev/null || echo 'this user'). Ownership and mode were not checked; run validate-config.sh as a user that can read it (for example with sudo)" ;;
    outside)
      store_skipped=true
      info "$1 is mounted from $3, outside what the wizard can read (it sees the deployment directory only). Ownership and mode were not checked; run validate-config.sh on the host to check it" ;;
  esac
}

signed_output_dir_check() {
  store_probe "${signed_output_dir}"
  store_unchecked "signed-output" "$signed_output_how" "${signed_output_dir}"
  [[ "$store_skipped" == true ]] && return 0
  if [[ "$store_state" == dir ]]; then
    ok "signed-output directory exists"
    if world_writable "${signed_output_dir}"; then
      bad "signed-output directory is world-writable ($(stat -c '%a' "${signed_output_dir}" 2>/dev/null || stat -f '%Lp' "${signed_output_dir}" 2>/dev/null)). ps-server does not need this (it owns the tree, or runs as root); fix: chmod 750 ${signed_output_dir}"
    else
      ok "signed-output directory is not world-writable"
    fi
    check_tree_owner "${signed_output_dir}" "$ps_server_image_repo" "signed-output directory"
  elif [[ "$store_state" == notdir ]]; then
    bad "signed-output ${signed_output_dir} exists but is not a directory"
  elif in_tree_store "${signed_output_dir}"; then
    bad "signed-output directory missing (re-run upgrade.sh, which creates it owned by the ps-server image's user, mode 750)"
  else
    bad "signed-output directory ${signed_output_dir} (environment-overlay mount) is missing - restore or re-point the mount; upgrade.sh does not create it"
  fi
}

docs_dir_check() {
  store_probe "${docs_dir}"
  store_unchecked "docs" "$docs_how" "${docs_dir}"
  [[ "$store_skipped" == true ]] && return 0
  if [[ "$store_state" == dir ]]; then
    check_tree_owner "${docs_dir}" "$dmss_fallback_image_repo" "docs directory"
    if world_writable "${docs_dir}"; then
      bad "docs directory is world-writable ($(stat -c '%a' "${docs_dir}" 2>/dev/null || stat -f '%Lp' "${docs_dir}" 2>/dev/null)). Fix: chmod 770 ${docs_dir}$(in_tree_store "${docs_dir}" && echo ' (re-running upgrade.sh does this)') - see installation-scripts/lib/dir-permissions.sh"
    else
      ok "docs directory is not world-writable"
    fi
  elif [[ "$store_state" == notdir ]]; then
    bad "docs ${docs_dir} exists but is not a directory"
  elif in_tree_store "${docs_dir}"; then
    bad "docs directory missing (create with: mkdir -p docs — then see installation-scripts/lib/dir-permissions.sh for the correct group/mode)"
  else
    bad "docs directory ${docs_dir} (environment-overlay mount) is missing - restore or re-point the mount"
  fi
}

signed_output_dir_check
docs_dir_check

# --- Secret hygiene ---
# Nothing here prints a secret value - only field names and file modes.
echo ""
echo "Secret hygiene:"
config_js="${repo_root}/config/config.js"

# ps-server's apiProtect logs the raw Authorization header, the bearer token
# and its decoded payload when this flag is on (psapp server/app.js). A token
# in `docker logs` is a replayable credential until it expires.
if grep -Eq '^[[:space:]]*API_PROTECT_LOGS_ENABLED[[:space:]]*:[[:space:]]*true' "$config_js"; then
  bad "API_PROTECT_LOGS_ENABLED is true in config/config.js - ps-server then writes raw bearer tokens and token payloads to its log. Set it to false and restart ps-server."
else
  ok "API_PROTECT_LOGS_ENABLED is off (no bearer tokens in ps-server logs)"
fi

# Values shipped in this PUBLIC repository are known to everyone. Which
# values those are is defined once, in lib/secret_hygiene.py (by sha256, not
# by comparing with git HEAD: a host that committed its own config.js would
# otherwise have its real values reported as the shipped ones). bootstrap.sh
# generates the two that are ours to choose (configure-host.sh
# --generate-secrets); the stamping credentials come from the provider.
overlay_host=""; [[ -f "${repo_root}/.overlay-applied.json" ]] && overlay_host=1
shipped_report="$(PADSIGN_HOST_HINT="$host" PADSIGN_OVERLAY_HOST="$overlay_host" python3 "${repo_root}/installation-scripts/lib/secret_hygiene.py" shipped "$config_js" 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$shipped_report" ]]; then
  warn "could not compare config.js credentials with the values shipped in the repository (config/config.js unreadable?)"
fi
while IFS=$'\t' read -r gate_status gate_message; do
  case "$gate_status" in
    OK)   ok "$gate_message";;
    WARN) warn "$gate_message";;
  esac
done <<< "$shipped_report"

# The visual-PDF signing CA: the copies this public repository ships have a
# public private key, so anyone could issue certificates under them.
# shellcheck source=lib/visual-pdf-ca.sh
source "${repo_root}/installation-scripts/lib/visual-pdf-ca.sh"
case "$(vpca_state "$repo_root")" in
  shipped)
    warn "the visual-PDF signing CA (dmss-container-and-signature-services/dmssrootca.p12) is the one shipped in the public repository - its private key is public. Fix: ./installation-scripts/configure-host.sh --host ${host} --generate-ca, then docker compose restart dmss-container-and-signature-services" ;;
  custom)
    ok "the visual-PDF signing CA is this deployment's own" ;;
  unreadable)
    bad "dmss-container-and-signature-services/dmssrootca.p12 does not open with cakeystorepassword from its application.yml - visual PDF signing will fail" ;;
  missing)
    bad "the visual-PDF signing CA keystore named by cakeystorepath in dmss-container-and-signature-services/application.yml is missing" ;;
esac

# The archive's JWT secret ships in this public repository. JWT checking is
# off by default; turned on with the shipped secret, anyone can forge tokens.
archive_yml="${repo_root}/dmss-archive-services/application.yml"
if [[ -f "$archive_yml" ]] && awk '/^  jwt:/{on=1; next} on && /^  [^ ]/{on=0} on && /^[[:space:]]+enabled:[[:space:]]*true/{f=1} END{exit !f}' "$archive_yml"; then
  archive_jwt="$(awk '/^  jwt:/{on=1; next} on && /^  [^ ]/{on=0} on && /^[[:space:]]+secret:/{sub(/^[[:space:]]+secret:[[:space:]]*/, ""); gsub(/["\r]/, ""); print; exit}' "$archive_yml")"
  if [[ "$(printf '%s' "$archive_jwt" | openssl dgst -sha256 -r 2>/dev/null | cut -d' ' -f1)" == "2e3843c62bc8fc34f64834d70eef5fa5786bd110a668999a042c598541895433" ]]; then
    bad "dmss-archive-services has JWT checking enabled with the secret shipped in the public repository - anyone can forge tokens. Set authentication.jwt.secret in dmss-archive-services/application.yml to your own value"
  else
    ok "dmss-archive-services JWT checking uses a secret of this deployment's own"
  fi
fi

# Keycloak's bootstrap admin password is read only on Keycloak's first boot
# against an empty volume (documentation/08-03-admin-password-and-break-glass.md). A real value in the TRACKED
# docker-compose.yml still leaks: into `git diff`, into the stash objects of
# a stash/pull/pop upgrade, and to every local user (the file is 644). The
# release reads it from .env (KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD) instead.
admin_state="$(python3 "${repo_root}/installation-scripts/lib/secret_hygiene.py" admin-password "${repo_root}/docker-compose.yml" "${repo_root}/.env" 2>/dev/null | tr -d '\r' || true)"
admin_var="$(awk '{print $2}' <<< "$admin_state")"
case "$admin_state" in
  inline)
    warn "docker-compose.yml, a tracked file, carries the Keycloak admin password inline (value not shown) - it shows in git diff, in git stash objects and to every local user. Move it to .env: documentation/07-06-environment-variables.md" ;;
  inline-default)
    warn "docker-compose.yml still carries KEYCLOAK_ADMIN_PASSWORD=admin (used only on Keycloak's first boot against an empty volume - see documentation/08-03-admin-password-and-break-glass.md)" ;;
  "placeholder "*" default")
    warn "Keycloak's first-boot admin password falls back to the demo default admin: ${admin_var} is not set in .env (used only on Keycloak's first boot against an empty volume - see documentation/08-03-admin-password-and-break-glass.md; bootstrap.sh sets it)" ;;
  "placeholder "*" empty")
    warn "Keycloak's first-boot admin password is empty: ${admin_var} is not set in .env (see documentation/07-06-environment-variables.md)" ;;
  "placeholder "*" set")
    ok "Keycloak's first-boot admin password is read from ${admin_var} (.env), not stored in the tracked docker-compose.yml" ;;
  absent)
    ok "docker-compose.yml sets no Keycloak bootstrap admin password" ;;
  *)
    warn "could not tell how docker-compose.yml sets the Keycloak admin password" ;;
esac

# config/config.js: kept from other users, but readable by ps-server. The
# advice depends on the uid:gid the pinned image runs as - `chmod o-rwx`
# alone crash-loops ps-server 3.30+ (uid 1000) on a root-owned file. Same
# check overlay.sh verify runs, and the model configure-host.sh applies
# (lib/dir-permissions.sh).
while IFS=$'\t' read -r gate_status gate_message; do
  case "$gate_status" in
    OK)   ok "$gate_message";;
    WARN) warn "$gate_message";;
    FAIL) bad "$gate_message";;
  esac
done < <(config_js_access_report | tr -d '\r')

file_mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
world_readable() { find "$1" -maxdepth 0 -perm -004 2>/dev/null | grep -q .; }
if [[ -f "${repo_root}/.env" ]]; then
  if world_readable "${repo_root}/.env"; then
    warn ".env is world-readable (mode $(file_mode_of "${repo_root}/.env")) and can hold credentials (the Keycloak first-boot admin password, ALERT_WEBHOOK_URL) - chmod 600 .env (only docker compose reads it, as the user who runs it; no container does)"
  else
    ok ".env is not world-readable"
  fi
fi
for f in "${repo_root}"/nginx/certs/*.key; do
  [[ -f "$f" ]] || continue
  if world_readable "$f"; then
    bad "nginx/certs/$(basename "$f") is world-readable (mode $(file_mode_of "$f")) - chmod 600 it"
  else
    ok "nginx/certs/$(basename "$f") is not world-readable"
  fi
done

# --- Nginx redirect ---
if grep -q 'return 301.*portal' "${repo_root}/nginx/nginx.conf"; then
  ok "nginx root→/portal/ redirect configured"
else
  bad "nginx root→/portal/ redirect missing"
fi

# --- Port bindings ---
# Internal services must never bind to a non-loopback host interface — nginx is
# the only intended public ingress. A service is allowed to publish on all
# interfaces only if it's on this allow-list (documented exception); everything
# else, including any future service someone adds here, must be loopback-only
# or have no host port mapping at all.
echo ""
echo "Port bindings:"
declare -A PORT_ALLOWLIST_NONLOOPBACK=(
  [nginx]="public HTTPS/HTTP ingress — the only intended entrypoint"
  [wizard]="opt-in, profile-gated deployment UI; own HTTPS+token controls, see documentation/03-03-how-the-wizard-works.md"
)

port_config_json="$(compose_config --format json 2>/dev/null || echo "")"
if [[ -z "$port_config_json" ]]; then
  bad "could not render docker-compose.yml via 'docker compose config --format json' to check port bindings"
else
  port_report="$(python3 -c "
import json, sys
data = json.load(sys.stdin)
for name, svc in sorted((data.get('services') or {}).items()):
    for p in (svc.get('ports') or []):
        host_ip = p.get('host_ip') or ''
        published = p.get('published') or ''
        target = p.get('target', '')
        loopback = host_ip in ('127.0.0.1', '::1')
        print(f'{name}\t{host_ip}\t{published}\t{target}\t{1 if loopback else 0}')
" <<< "$port_config_json" 2>/dev/null | tr -d '\r')"

  if [[ -z "$port_report" ]]; then
    ok "no services publish a host port"
  else
    while IFS=$'\t' read -r svc host_ip published target loopback; do
      [[ -z "$svc" ]] && continue
      if [[ "$loopback" == "1" ]]; then
        ok "${svc}: host port ${published} bound to ${host_ip} (loopback-only)"
      elif [[ "$svc" == wizard ]]; then
        # Allowed (WIZARD_BIND_ADDRESS in .env), but it holds the Docker
        # socket and Docker's published ports bypass host firewalls.
        warn "wizard: host port ${published} bound to ${host_ip:-all interfaces} (WIZARD_BIND_ADDRESS) - it holds the Docker socket, and Docker-published ports bypass host firewalls such as ufw. Keep it on 127.0.0.1 and use an SSH tunnel unless this network is trusted (documentation/03-01-starting-the-wizard.md)"
      elif [[ -n "${PORT_ALLOWLIST_NONLOOPBACK[$svc]:-}" ]]; then
        ok "${svc}: host port ${published} bound to all interfaces (allow-listed: ${PORT_ALLOWLIST_NONLOOPBACK[$svc]})"
      else
        bad "${svc}: host port ${published} (-> ${target}) bound to ${host_ip:-all interfaces (0.0.0.0/::)} — internal services must be loopback-only or unpublished unless added to the allow-list in this script with a documented reason"
      fi
    done <<< "$port_report"
  fi
fi

# --- Hostname consistency (if --host provided) ---
if [[ -n "$host" ]]; then
  echo ""
  echo "Hostname consistency (${host}):"

  if grep -q "server_name ${host}" "${repo_root}/nginx/nginx.conf"; then
    ok "nginx server_name matches"
  else
    bad "nginx server_name does not match '${host}'"
  fi

  # The three Keycloak URLs of constants.json are either set to this host or
  # left out: a ps-client that reads no hard-coded host (the
  # client-origin-defaults capability in release/capabilities.json) then uses
  # the origin of the page, which is the same address. Both shapes are
  # accepted; a missing key on a client without that default is not, because
  # it starts Keycloak with undefined URLs.
  client_tag="$(sed -nE 's|.*mihailsgordijenko/ps-client:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1 || true)"
  host_lc="${host,,}"
  keycloak_keys="$(python3 - "${repo_root}/config/constants.json" "$host_lc" <<'PY' 2>/dev/null | tr -d '\r' || true
import json, sys
path, host = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
expected = {
    "KEYCLOAK_URL": f"https://{host}/auth",
    "KEYCLOAK_REDIRECT_URI": f"https://{host}/portal/",
    "KEYCLOAK_POST_LOGOUT_REDIRECT_URI": f"https://{host}/portal/",
}
for key, want in expected.items():
    have = data.get(key)
    state = "absent" if key not in data else ("match" if have == want else "mismatch")
    print(f"{key}\t{state}\t{want}\t{have if have is not None else ''}")
PY
)"
  absent_keys=()
  while IFS=$'\t' read -r kc_key kc_state kc_want kc_have; do
    [[ -z "$kc_key" ]] && continue
    case "$kc_state" in
      match) ok "constants.json ${kc_key} matches" ;;
      absent) absent_keys+=("$kc_key") ;;
      mismatch)
        if [[ "$kc_key" == KEYCLOAK_URL ]]; then
          bad "constants.json KEYCLOAK_URL does not match '${kc_want}'"
        else
          warn "constants.json ${kc_key} is '${kc_have}', not '${kc_want}' - Keycloak sends users there after login or logout"
        fi ;;
    esac
  done <<< "$keycloak_keys"
  if [[ ${#absent_keys[@]} -gt 0 ]]; then
    kc_have_rc=0
    capability_tag_has client-origin-defaults ps-client "${client_tag:-0}" 2>/dev/null || kc_have_rc=$?
    case "$kc_have_rc" in
      0) ok "constants.json leaves out ${absent_keys[*]}: ps-client ${client_tag} uses this page's origin (https://${host_lc}/...)" ;;
      1) bad "constants.json has no ${absent_keys[*]}, and ps-client ${client_tag} has no default for it - login breaks. Add the key(s) (documentation/07-03-client-constants-json.md) or run a ps-client with the client-origin-defaults capability (release/capabilities.json)" ;;
      *) warn "constants.json has no ${absent_keys[*]} and this check could not tell whether ps-client ${client_tag:-?} defaults them (release/capabilities.json, client-origin-defaults)" ;;
    esac
  fi

  if grep -q "https://${host}/auth" "${repo_root}/config/config.js"; then
    ok "config.js auth-server-url matches"
  else
    bad "config.js auth-server-url does not match 'https://${host}/auth'"
  fi

  # KC_HOSTNAME is Keycloak's fixed frontend hostname — it decides the token
  # issuer and the login form's action URL. Any other host here sends
  # browsers to that host at login. Same readers
  # configure-host.sh and upgrade.sh's compose-hostname migration use.
  kc_hostname="$(compose_kc_hostname "${repo_root}/docker-compose.yml")"
  if [[ -z "$kc_hostname" ]]; then
    warn "docker-compose.yml keycloak service sets no KC_HOSTNAME — Keycloak derives its issuer from each request's forwarded Host header"
  elif [[ "$(kc_hostname_host "$kc_hostname")" == "${host,,}" ]]; then
    ok "docker-compose.yml KC_HOSTNAME matches"
  else
    bad "docker-compose.yml KC_HOSTNAME is '${kc_hostname}', not '${host}' — Keycloak issues tokens for, and sends logins to, that host. Fix: ./installation-scripts/configure-host.sh --host ${host} (or upgrade.sh's compose-hostname migration), then docker compose up -d keycloak"
  fi

  # The alias only matters inside the Docker network (ps-server's own calls
  # to https://<host>/...); with it stale, those go via public DNS instead.
  nginx_aliases="$(compose_nginx_aliases "${repo_root}/docker-compose.yml" | paste -sd, -)"
  if [[ -z "$nginx_aliases" ]]; then
    : # no alias list: nothing to be stale
  elif nginx_alias_needs_update "${repo_root}/docker-compose.yml" "$host"; then
    warn "docker-compose.yml nginx network alias (${nginx_aliases}) does not include '${host}' — containers reach https://${host}/ via public DNS instead of directly. Fix: ./installation-scripts/configure-host.sh --host ${host}, then docker compose up -d nginx"
  else
    ok "docker-compose.yml nginx network alias matches"
  fi
fi

# --- DMSS service addresses ---
# ps-server reaches the archive and container-signature services at five
# addresses (lib/dmss_urls.py). Both forms are accepted, and they may be mixed:
# the in-network one (http://dmss-archive-services:8090/api/..., what the
# release ships) and the public one (https://<host>/archive/api/..., through
# nginx, what hosts installed earlier keep until they run
# `upgrade.sh --use-internal-dmss-urls`). What is checked is that each key
# names the right service, that a public address names this host, and what
# each form implies for the nginx routes and for webhook payloads.
echo ""
echo "DMSS service addresses (config/config.js):"
dmss_status="$(python3 "${repo_root}/installation-scripts/lib/dmss_urls.py" status "${repo_root}/config/config.js" 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$dmss_status" ]]; then
  warn "could not read the DMSS addresses from config/config.js"
else
  served_host="${host,,}"
  [[ -z "$served_host" ]] && served_host="$(nginx_server_name "${repo_root}/nginx/nginx.conf" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z' || true)"
  addr_host() {  # https://Host:443/path -> host
    local v="${1#*://}"; v="${v%%/*}"; v="${v%%:*}"; printf '%s' "${v,,}"
  }
  n_internal=0 n_public=0 n_other=0
  pub_state=missing pub_value=""
  while IFS=$'\t' read -r key state value expects target; do
    [[ -z "$key" ]] && continue
    if [[ "$key" == ARCHIVE_PUBLIC_BASE_URL ]]; then pub_state="$state"; pub_value="$value"; continue; fi
    case "$state" in
      internal|public)
        if [[ "$target" != "$expects" ]]; then
          bad "config.js ${key} is '${value}', the ${target} service's address, but this key needs the ${expects} service's"
        elif [[ "$state" == internal ]]; then
          n_internal=$((n_internal + 1))
        elif [[ -n "$served_host" && "$(addr_host "$value")" != "$served_host" ]]; then
          bad "config.js ${key} names $(addr_host "$value"), not '${served_host}' - ps-server calls that host. Fix: ./installation-scripts/configure-host.sh --host ${served_host}, or ./installation-scripts/upgrade.sh --use-internal-dmss-urls"
        else
          n_public=$((n_public + 1))
        fi ;;
      other) n_other=$((n_other + 1)); warn "config.js ${key} is not the in-network or the public DMSS address (value not checked); ps-server uses it as written" ;;
      missing) warn "config.js ${key} is not set" ;;
    esac
  done <<< "$dmss_status"

  if [[ "$n_internal" -gt 0 && "$n_public" -eq 0 && "$n_other" -eq 0 ]]; then
    ok "ps-server reaches the DMSS services by their in-network addresses: nginx's /archive/api/ and /container/api/ can be closed without breaking it (documentation/06-01-route-protection.md)"
  elif [[ "$n_public" -gt 0 && "$n_internal" -eq 0 ]]; then
    ok "ps-server reaches the DMSS services through nginx at https://${served_host:-<host>}/: /archive/api/ and /container/api/ must stay reachable from the Docker network. To use the in-network addresses instead: ./installation-scripts/upgrade.sh --use-internal-dmss-urls (documentation/07-04-server-config-js.md)"
  elif [[ "$n_public" -gt 0 && "$n_internal" -gt 0 ]]; then
    warn "${n_internal} DMSS address(es) are in-network and ${n_public} go through nginx: that works, but closing /archive/api/ or /container/api/ at nginx breaks the ${n_public} that do. ./installation-scripts/upgrade.sh --use-internal-dmss-urls (or --use-public-dmss-urls) makes them uniform"
  fi

  # Webhook payloads carry archiveUrl: ARCHIVE_PUBLIC_BASE_URL if set, else
  # ARCHIVE_API_BASE_URL - which, in-network, a receiver cannot open.
  webhook_on=false
  if perl -0777 -ne 'exit(/type:\s*["\x27]webhook["\x27]\s*,\s*enabled:\s*true/ ? 0 : 1)' "${repo_root}/config/config.js" 2>/dev/null; then
    webhook_on=true
  fi
  if [[ "$pub_state" == public && -n "$served_host" && "$(addr_host "$pub_value")" != "$served_host" ]]; then
    warn "config.js ARCHIVE_PUBLIC_BASE_URL names $(addr_host "$pub_value"), not '${served_host}' - webhook receivers are sent there for the signed PDF. Fix: ./installation-scripts/configure-host.sh --host ${served_host}"
  fi
  if [[ "$n_internal" -gt 0 && "$webhook_on" == true ]]; then
    if [[ "$pub_state" == missing ]]; then
      warn "a webhook strategy is enabled and the DMSS addresses are in-network, but config.js has no ARCHIVE_PUBLIC_BASE_URL: webhook payloads carry an in-network archiveUrl that receivers cannot open. Set it to https://${served_host:-<host>}/archive/api/"
    else
      server_tag_now="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1 || true)"
      dmss_cap_rc=0
      capability_tag_has dmss-internal-urls ps-server "${server_tag_now:-0}" 2>/dev/null || dmss_cap_rc=$?
      if [[ "$dmss_cap_rc" == 1 ]]; then
        warn "ps-server ${server_tag_now} ignores ARCHIVE_PUBLIC_BASE_URL (capability dmss-internal-urls in release/capabilities.json), so the enabled webhook sends the in-network archiveUrl. Upgrade ps-server, or use --use-public-dmss-urls"
      fi
    fi
  fi
fi

# --- Image tag consistency ---
echo ""
echo "Image tags:"
server_tag="$(grep -oP 'mihailsgordijenko/ps-server:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "not found")"
client_tag="$(grep -oP 'mihailsgordijenko/ps-client:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "not found")"
ok "ps-server: ${server_tag}"
ok "ps-client: ${client_tag}"

# Check that the tags match the release this checkout ships: the ps-server /
# ps-client tag release/approved-digests.json approves (the file
# documentation/14-03-release-snapshot.md describes). A pin rollback.sh
# restored and verified (.rollback-applied.json) differs from the release on
# purpose: a WARN here, and the digest gate below decides whether that pin
# was ever approved.
# shellcheck source=lib/rollback-snapshot.sh
. "${repo_root}/installation-scripts/lib/rollback-snapshot.sh"
snapshot_tag_mismatch() {  # <component> <release snapshot tag> <docker-compose tag>
  local pin_digest
  pin_digest="$(compose_pin "$1" | cut -d' ' -f2)"
  if rollback_marker_covers "$1" "$3" "$pin_digest"; then
    warn "Release snapshot $1 ($2) != docker-compose ($3): rollback.sh restored $3 - see Image digest pinning below"
  else
    bad "Release snapshot $1 ($2) != docker-compose ($3)"
  fi
}
release_tag() {  # <component>: the tag release/approved-digests.json approves, or nothing
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["images"].get(sys.argv[2], {}).get("tag", ""))' \
    "${repo_root}/release/approved-digests.json" "$1" 2>/dev/null | tr -d '\r'
}
snap_server="$(release_tag ps-server)"
if [[ -n "$snap_server" && "$snap_server" != "$server_tag" ]]; then
  snapshot_tag_mismatch ps-server "$snap_server" "$server_tag"
fi
snap_client="$(release_tag ps-client)"
if [[ -n "$snap_client" && "$snap_client" != "$client_tag" ]]; then
  snapshot_tag_mismatch ps-client "$snap_client" "$client_tag"
fi

# --- Image digest pinning ---
# Every image of the EFFECTIVE compose model - docker-compose.yml plus any
# COMPOSE_FILE overlay, every profile enabled - must be pinned by immutable
# sha256 digest, and that digest must be approved: by
# release/approved-digests.json, or on an overlay host by the overlay's own
# approved-digests.json (documentation/09-11-start-at-boot-backups-and-customized-hosts.md). A tag-only pin, an unreviewed
# digest and an image nobody approved all fail here. The checks live in
# lib/digest_gate.py so check-digest-drift.sh applies the identical rules.
# See documentation/14-06-image-approval-and-digest-pinning.md.
echo ""
echo "Image digest pinning:"
# shellcheck source=lib/digests.sh
. "${repo_root}/installation-scripts/lib/digests.sh"

if [[ ! -f "$digests_json" ]]; then
  bad "release/approved-digests.json missing — no image digests can be verified"
elif ! compose_images_prime; then
  bad "could not read the effective compose model - no image digests can be verified"
else
  while IFS=$'\t' read -r gate_status gate_message; do
    case "$gate_status" in
      OK)   ok "$gate_message";;
      WARN) warn "$gate_message";;
      FAIL) bad "$gate_message";;
      INFO) printf '  %s
' "$gate_message";;
    esac
  done < <(digest_gate_check)
fi

# --- Image signatures (cosign) ---
# ps-server / ps-client are signed by psapp's CI with the key whose public
# half is release/cosign.pub. Checked by the pinned digest, i.e. exactly what
# Docker pulls. Reads the registry; see lib/signatures.sh for what each
# outcome means. No cosign on the host is a warning (a FAIL under CI=true or
# PADSIGN_REQUIRE_SIGNATURES=1); a signature that does not verify always fails.
echo ""
echo "Image signatures (cosign):"
# shellcheck source=lib/signatures.sh
. "${repo_root}/installation-scripts/lib/signatures.sh"
for image_key in "${signed_image_keys[@]}"; do
  repository="mihailsgordijenko/${image_key}"
  pinned="$(digest_from_compose "$repository")"
  if [[ "$pinned" != *"@sha256:"* ]]; then
    # Already a FAIL under "Image digest pinning"; there is no immutable
    # reference to check a signature against.
    warn "${image_key}: not digest-pinned, signature not checked"
    continue
  fi
  pinned_digest="${pinned#*@}"
  signature_check "$repository" "${repository}@${pinned_digest}" "$pinned_digest"
  case "$sig_status" in
    verified) ok "${image_key} (${pinned%@*}): ${sig_message}" ;;
    exempt) warn "${image_key} (${pinned%@*}): ${sig_message}" ;;
    unavailable)
      if signatures_required; then bad "${image_key}: ${sig_message}"; else warn "${image_key}: ${sig_message}"; fi ;;
    *) bad "${image_key} (${pinned%@*}): ${sig_message}" ;;
  esac
done

# --- Running container checks (if Docker is available) ---
if docker ps > /dev/null 2>&1; then
  echo ""
  echo "Container checks:"
  running_server="$(docker ps --filter name=ps-server --format '{{.Image}}' 2>/dev/null || echo "")"
  running_client="$(docker ps --filter name=ps-client --format '{{.Image}}' 2>/dev/null || echo "")"

  if [[ -n "$running_server" ]]; then
    if echo "$running_server" | grep -q "$server_tag"; then
      ok "ps-server running correct tag (${server_tag})"
    else
      bad "ps-server running ${running_server}, expected ${server_tag}"
    fi
  else
    bad "ps-server not running"
  fi

  if [[ -n "$running_client" ]]; then
    if echo "$running_client" | grep -q "$client_tag"; then
      ok "ps-client running correct tag (${client_tag})"
    else
      bad "ps-client running ${running_client}, expected ${client_tag}"
    fi
  else
    bad "ps-client not running"
  fi
fi

# --- Summary ---
echo ""
echo "================================"
if [[ "$fail" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
else
  echo "Some checks FAILED. Review above."
  exit 1
fi
