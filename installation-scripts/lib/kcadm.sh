# shellcheck shell=bash
#
# Shared helpers for driving a running Keycloak container's kcadm.sh via
# `docker compose exec`.
#
# Sourced by keycloak-bootstrap.sh, verify-keycloak.sh, and smoke-user.sh.
# Before this file, kc_exec()/kc_csv_last() were duplicated verbatim between
# the first two — the same "hardcoded logic copied into two scripts" pattern
# lib/capabilities.sh's own header describes for its own origin. Every
# function here is self-contained; unlike lib/capabilities.sh, nothing here
# expects the caller to have already set a variable like "$repo_root".

kc_exec() {
  docker compose exec -T keycloak sh -lc "$*"
}

kc_csv_last() {
  local cmd="$1"
  kc_exec "$cmd" | tail -n 1 | tr -d '\r"'
}

# Wait for Keycloak readiness via a TCP check run INSIDE the keycloak
# container itself (docker compose exec), not a curl from wherever the
# calling script happens to execute. Callers run both directly on a bare host
# (traditional CLI use) and inside the deployment-wizard container (which
# talks to keycloak only as a sibling container via the mounted Docker
# socket) — "localhost:8080" only resolves to the right place in the first
# case. `docker compose exec` always reaches the correct container via the
# Docker API regardless of the caller's own network namespace, matching how
# kc_exec() above already works. The keycloak image ships bash (no curl/wget),
# so /dev/tcp is the check, not an HTTP request — found via a real E2E test
# where the wizard ran as an actual container for the first time.
#
# Returns 1 (does not exit the caller) on timeout so the caller decides how
# to fail.
kc_wait_ready() {
  echo "  Waiting for Keycloak to become ready..."
  local i
  for i in $(seq 1 120); do
    if kc_exec "bash -c 'echo > /dev/tcp/localhost/8080'" >/dev/null 2>&1; then
      echo "  Keycloak ready (${i}s)"
      return 0
    fi
    sleep 1
    if [[ "$i" == "120" ]]; then
      echo "ERROR: Keycloak did not become ready within 120s" >&2
      return 1
    fi
  done
}

kc_login() {
  local admin_user="$1" admin_pass="$2"
  kc_exec "/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user '${admin_user}' --password '${admin_pass}'" >/dev/null
}

# True (exit 0) when role <name> already exists in realm <realm>. Full-list-
# plus-exact-match, NOT `kcadm get roles/<name>` (a raw URL path segment) —
# kcadm/Keycloak reject a literal space there ("Illegal character in path"),
# so a multi-word role name (e.g. "Acme Corp") always fails that lookup.
# `-q name=` isn't a supported server-side filter on the roles endpoint
# either (it silently returns everything), so the exact match happens
# client-side via `grep -qxF` instead. Same technique as
# keycloak-bootstrap.sh's ensure_role().
kc_role_exists() {
  local realm="$1" name="$2"
  kc_exec "/opt/keycloak/bin/kcadm.sh get roles -r ${realm} --fields name --format csv | tr -d '\r\"' | grep -qxF '${name}'"
}

# Prints secret material to the controlling terminal only, bypassing stdout
# and stderr entirely. bootstrap.sh captures keycloak-bootstrap.sh's whole
# stdout+stderr into a variable (2>&1) and the deployment wizard streams both
# into a retained live-log buffer for the browser — neither should ever see a
# generated password. /dev/tty is the process's controlling terminal
# regardless of stdout/stderr redirection, so an interactive operator still
# sees it once, while a headless caller (wizard, CI) has no controlling
# terminal and the write silently fails.
#
# Redirection order matters here: 2>/dev/null MUST be set up before > /dev/tty
# is attempted, not after. Bash sets up redirections left-to-right; if
# `> /dev/tty` came first and failed to open (no controlling terminal), bash
# reports that failure on whatever stderr was current at that point — which,
# written in the other order, is still the original unredirected stderr, so
# the "No such device or address" diagnostic would itself leak into any
# captured stream. Verified empirically.
print_secret() {
  printf '%s\n' "$*" 2>/dev/null > /dev/tty
}
