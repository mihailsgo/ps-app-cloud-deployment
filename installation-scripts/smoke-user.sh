#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Smoke-test user — least-privilege create/delete of a disposable,
# single-purpose Keycloak login.
#
# Unlike keycloak-bootstrap.sh's fixed 'test' account (recreated destructively
# on every bootstrap run, shared across anyone using that deployment), this
# mints a uniquely-named user on demand, assigns it exactly one already-
# existing company role, and deletes it again — without touching the realm,
# clients, roles, or the 'test' account, and without restarting Keycloak.
# ============================================================================

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/kcadm.sh
. "${scripts_dir}/lib/kcadm.sh"

smoke_user_prefix="smoke-"

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/smoke-user.sh create --host example.com --company-role "Acme"
                                    [--realm padsign]
                                    [--admin-user admin] [--admin-pass secret]

  ./installation-scripts/smoke-user.sh delete --host example.com --username smoke-a1b2c3d4
                                    [--realm padsign]
                                    [--admin-user admin] [--admin-pass secret]
                                    [--force]

create:
  Generates a unique "smoke-<random>" username and a random password, assigns
  it ONLY the given --company-role (never padsign-admin), and prints the
  username once to stdout and the password once to the controlling terminal
  (never to a stream a caller could capture or retain — see print_secret in
  lib/kcadm.sh). Requires the realm and the company role to already exist
  (run keycloak-bootstrap.sh first) — this script never creates either.

delete:
  Removes the given --username. Refuses usernames that don't start with
  "smoke-" unless --force is given, to guard against deleting the wrong
  account through this tool. Deleting a username that doesn't exist is
  treated as success (idempotent). Never restarts Keycloak.
EOF
}

subcommand="${1:-}"
[[ $# -gt 0 ]] && shift

host=""
company_role=""
realm="padsign"
admin_user="${KEYCLOAK_ADMIN:-admin}"
admin_pass="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
username=""
force="false"

case "$subcommand" in
  create|delete) ;;
  -h|--help) usage; exit 0;;
  "") echo "ERROR: Missing subcommand (create|delete)." >&2; usage; exit 2;;
  *) echo "ERROR: Unknown subcommand: ${subcommand}" >&2; usage; exit 2;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) host="${2:-}"; shift 2;;
    --company-role) company_role="${2:-}"; shift 2;;
    --realm) realm="${2:-}"; shift 2;;
    --admin-user) admin_user="${2:-}"; shift 2;;
    --admin-pass) admin_pass="${2:-}"; shift 2;;
    --username) username="${2:-}"; shift 2;;
    --force) force="true"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "ERROR: Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$host" ]]; then
  echo "ERROR: Missing --host." >&2
  exit 2
fi

if [[ "$admin_pass" == "admin" ]]; then
  echo "WARNING: Using default admin password 'admin' is insecure. Consider --admin-pass with a strong password (or set KEYCLOAK_ADMIN_PASSWORD)." >&2
fi

docker compose up -d keycloak >/dev/null
kc_wait_ready || exit 1
kc_login "${admin_user}" "${admin_pass}"

if ! kc_exec "/opt/keycloak/bin/kcadm.sh get realms/${realm} >/dev/null 2>&1"; then
  echo "ERROR: realm '${realm}' does not exist. Run keycloak-bootstrap.sh first." >&2
  exit 1
fi

# Looks up a user's id by username. Prints nothing and returns 1 if not
# found. kcadm's CSV output returns just the header row ("id") for a
# zero-result query, not empty output, since `tail -n 1` on a header-only
# CSV grabs the header itself — every existence check in this repo's other
# Keycloak scripts guards on both "non-empty" AND "!= id" for exactly this
# reason (see keycloak-bootstrap.sh's test-user recreate block).
find_user_id() {
  local uname="$1" uid
  uid="$(kc_csv_last "/opt/keycloak/bin/kcadm.sh get users -r ${realm} -q username=${uname} --fields id --format csv")"
  if [[ -z "$uid" || "$uid" == "id" ]]; then
    return 1
  fi
  printf '%s\n' "$uid"
}

case "$subcommand" in
  create)
    if [[ -z "$company_role" ]]; then
      echo "ERROR: Missing --company-role." >&2
      exit 2
    fi
    if [[ "$company_role" == "padsign-admin" ]]; then
      echo "ERROR: Refusing to create a smoke-test user with the 'padsign-admin' role. This tool only assigns the configured company role." >&2
      exit 2
    fi
    if ! kc_role_exists "${realm}" "${company_role}"; then
      echo "ERROR: role '${company_role}' does not exist in realm '${realm}'. Run keycloak-bootstrap.sh first." >&2
      exit 1
    fi

    smoke_user="${smoke_user_prefix}$(head -c 32 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)"
    smoke_pass="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    smoke_email="${smoke_user}@$(printf '%s' "${company_role}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-').padsign"

    kc_exec "/opt/keycloak/bin/kcadm.sh create users -r ${realm} -s username=${smoke_user} -s enabled=true -s email='${smoke_email}'" >/dev/null
    smoke_uid="$(find_user_id "${smoke_user}")" || {
      echo "ERROR: created user '${smoke_user}' but could not look it back up." >&2
      exit 1
    }
    kc_exec "/opt/keycloak/bin/kcadm.sh set-password -r ${realm} --userid ${smoke_uid} --new-password '${smoke_pass}' --temporary=false" >/dev/null
    kc_exec "/opt/keycloak/bin/kcadm.sh add-roles -r ${realm} --uusername ${smoke_user} --rolename '${company_role}'" >/dev/null

    echo "Smoke-test user created."
    echo "  Realm:    ${realm}"
    echo "  Username: ${smoke_user}"
    echo "  Role:     ${company_role}"
    if print_secret "  Password (shown once, not logged): ${smoke_pass}"; then
      :
    else
      echo "  Password: not shown (no interactive terminal attached to this run)."
      echo "  This user's password cannot be recovered later — delete it (smoke-user.sh delete --username ${smoke_user}) and re-run interactively."
    fi
    echo
    echo "Delete when done: ./installation-scripts/smoke-user.sh delete --host ${host} --realm ${realm} --username ${smoke_user}"
    ;;

  delete)
    if [[ -z "$username" ]]; then
      echo "ERROR: Missing --username." >&2
      exit 2
    fi
    if [[ "$username" != "${smoke_user_prefix}"* && "$force" != "true" ]]; then
      echo "ERROR: '${username}' doesn't look like a smoke-test user (expected prefix '${smoke_user_prefix}')." >&2
      echo "       Pass --force if you really mean to delete this user through this tool." >&2
      exit 2
    fi

    if smoke_uid="$(find_user_id "${username}")"; then
      kc_exec "/opt/keycloak/bin/kcadm.sh delete users/${smoke_uid} -r ${realm}" >/dev/null
      echo "Deleted user '${username}' from realm '${realm}'."
    else
      echo "User '${username}' not found in realm '${realm}' (already deleted?)."
    fi
    ;;
esac
