# shellcheck shell=bash
#
# Writes deployment-evidence.json at the repo root after a successful
# bootstrap.sh / upgrade.sh / postdeploy-check.sh run: this deployment repo's
# own git revision and a dirty flag, the pinned image tags and, best-effort,
# their OCI revision labels, the actual running image digests (independent of
# whether docker-compose.yml pins by digest yet), sha256 checksums of the
# four files configure-host.sh/upgrade.sh mutate per host, per-service
# container restart counts and their delta since the previous evidence
# snapshot (surfaces restart-looping between two runs), and a best-effort
# read of which optional features are currently enabled.
#
# Deliberately records only derived, already-non-secret state - never the raw
# CLI arguments a script was invoked with. --admin-pass / --backend-secret /
# --users must never end up in this file.
#
# Expects "$repo_root" to be set by the sourcing script.

# shellcheck source=digests.sh
. "${repo_root}/installation-scripts/lib/digests.sh"

# List of always-on compose services whose restart count / digest this
# records. Kept in one place so it stays in sync with docker-compose.yml.
DEPLOYMENT_EVIDENCE_SERVICES=(
  keycloak
  dmss-archive-services
  dmss-container-and-signature-services
  dmss-archive-services-fallback
  ps-server
  nginx
  ps-client
)

# Writes deployment-evidence.json.
#
#   write_deployment_evidence <script-name>
write_deployment_evidence() {
  local script_name="$1"
  local evidence_file="${repo_root}/deployment-evidence.json"
  local previous_evidence_file="${evidence_file}.previous"

  # Preserve the previous snapshot (if any) so restart deltas can be computed,
  # without ever overwriting a "-1 generation older" snapshot mid-run.
  if [[ -f "$evidence_file" ]]; then
    cp -f "$evidence_file" "$previous_evidence_file"
  fi

  local git_rev git_branch git_dirty
  git_rev="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo "")"
  git_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  git_dirty=false
  # --untracked-files=no: signed-output/, docs/, *.bak and similar host-side
  # state are expected to exist and are not "drift" of the tracked baseline.
  if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    git_dirty=true
  fi

  local server_tag client_tag
  # sed -nE, not grep -oP: PCRE (-P) isn't available in every grep this can
  # run under (notably BusyBox/Alpine grep, and the MSYS grep this was first
  # tested under) - upgrade.sh's own current_tag() hit exactly this and
  # switched to sed -nE for the same reason (see its comment).
  server_tag="$(sed -nE 's|.*mihailsgordijenko/ps-server:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1)"
  client_tag="$(sed -nE 's|.*mihailsgordijenko/ps-client:([0-9]+\.[0-9]+(\.[0-9]+)?).*|\1|p' "${repo_root}/docker-compose.yml" 2>/dev/null | head -1)"

  local server_rev="" client_rev=""
  # Per-service running container digest and restart count. The digest is
  # the registry digest of the image the container runs (digest_running in
  # lib/digests.sh) - the same value docker-compose.yml pins and
  # release/approved-digests.json approves, so this file can be compared
  # against them directly. Not `docker inspect {{.Image}}`, which is the
  # local image ID and, on a classic image store, a config digest that
  # matches nothing in either file.
  local running_digests_json="{}" restarts_json="{}"
  if command -v docker >/dev/null 2>&1; then
    [[ -n "$server_tag" ]] && server_rev="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "mihailsgordijenko/ps-server:${server_tag}" 2>/dev/null || echo "")"
    [[ -n "$client_tag" ]] && client_rev="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "mihailsgordijenko/ps-client:${client_tag}" 2>/dev/null || echo "")"

    local svc cid digest restarts digest_parts=() restart_parts=()
    for svc in "${DEPLOYMENT_EVIDENCE_SERVICES[@]}"; do
      # Resolve via the COMPOSE service name to the real container id -
      # never assume the container is literally named after the service.
      # keycloak has no container_name: override in docker-compose.yml, so
      # `docker inspect keycloak` finds nothing on any real deployment;
      # `docker compose ps -q` is what actually knows the mapping.
      cid="$(docker compose ps -q "$svc" 2>/dev/null || echo "")"
      digest=""; restarts=""
      if [[ -n "$cid" ]]; then
        digest="$(digest_running "$cid")"
        restarts="$(docker inspect --format '{{.RestartCount}}' "$cid" 2>/dev/null || echo "")"
      fi
      digest_parts+=("\"${svc}\": $( [[ -n "$digest" ]] && printf '"%s"' "$digest" || printf 'null' )")
      restart_parts+=("\"${svc}\": $( [[ -n "$restarts" ]] && printf '%s' "$restarts" || printf 'null' )")
    done
    running_digests_json="{ $(IFS=,; echo "${digest_parts[*]}") }"
    restarts_json="{ $(IFS=,; echo "${restart_parts[*]}") }"
  fi

  SCRIPT_NAME="$script_name" \
  GIT_REV="$git_rev" GIT_BRANCH="$git_branch" GIT_DIRTY="$git_dirty" \
  SERVER_TAG="$server_tag" CLIENT_TAG="$client_tag" \
  SERVER_REV="$server_rev" CLIENT_REV="$client_rev" \
  IMAGE_DIGESTS_JSON="$running_digests_json" \
  RESTART_COUNTS_JSON="$restarts_json" \
  CONFIG_JS="${repo_root}/config/config.js" \
  CONSTANTS_JSON="${repo_root}/config/constants.json" \
  NGINX_CONF="${repo_root}/nginx/nginx.conf" \
  COMPOSE_YML="${repo_root}/docker-compose.yml" \
  ENV_FILE="${repo_root}/.env" \
  EVIDENCE_FILE="$evidence_file" \
  PREVIOUS_EVIDENCE_FILE="$previous_evidence_file" \
  python3 <<'PY'
import hashlib
import json
import os
import re
import datetime


def sha256_of(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return None


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def bool_env(name):
    return os.environ.get(name, "false") == "true"


config_js_text = read_text(os.environ["CONFIG_JS"])
constants_text = read_text(os.environ["CONSTANTS_JSON"])
env_text = read_text(os.environ["ENV_FILE"])

# Best-effort: the first "enabled:" line inside the DOCUMENT_ROUTING block.
routing_enabled = False
m = re.search(r"DOCUMENT_ROUTING\s*:\s*\{\s*enabled\s*:\s*(true|false)", config_js_text)
if m:
    routing_enabled = m.group(1) == "true"

demo_enabled = False
try:
    demo_enabled = json.loads(constants_text).get("DEMO_MODE") == "ENABLE"
except (json.JSONDecodeError, AttributeError):
    pass

local_eseal_enabled = bool(re.search(r"COMPOSE_PROFILES=.*local-eseal", env_text))

try:
    image_digests = json.loads(os.environ.get("IMAGE_DIGESTS_JSON") or "{}")
except json.JSONDecodeError:
    image_digests = {}

try:
    restart_counts = json.loads(os.environ.get("RESTART_COUNTS_JSON") or "{}")
except json.JSONDecodeError:
    restart_counts = {}

previous_restart_counts = {}
prev_path = os.environ["PREVIOUS_EVIDENCE_FILE"]
if os.path.isfile(prev_path):
    try:
        with open(prev_path, "r", encoding="utf-8") as fh:
            previous_restart_counts = (json.load(fh) or {}).get("restart_counts", {}) or {}
    except (OSError, json.JSONDecodeError):
        previous_restart_counts = {}

restart_deltas = {}
for svc, count in restart_counts.items():
    prev = previous_restart_counts.get(svc)
    if isinstance(count, int) and isinstance(prev, int):
        restart_deltas[svc] = count - prev
    else:
        # No comparable previous snapshot yet - not "0 restarts since last
        # time", genuinely unknown.
        restart_deltas[svc] = None

evidence = {
    "schema_version": 2,
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "script": os.environ["SCRIPT_NAME"],
    "deployment_repo": {
        "revision": os.environ.get("GIT_REV") or None,
        "branch": os.environ.get("GIT_BRANCH") or None,
        "dirty": bool_env("GIT_DIRTY"),
    },
    "image_tags": {
        "ps-server": os.environ.get("SERVER_TAG") or None,
        "ps-client": os.environ.get("CLIENT_TAG") or None,
    },
    "image_revisions": {
        "ps-server": os.environ.get("SERVER_REV") or None,
        "ps-client": os.environ.get("CLIENT_REV") or None,
    },
    "image_digests": image_digests,
    "config_checksums": {
        "config/config.js": sha256_of(os.environ["CONFIG_JS"]),
        "config/constants.json": sha256_of(os.environ["CONSTANTS_JSON"]),
        "nginx/nginx.conf": sha256_of(os.environ["NGINX_CONF"]),
        "docker-compose.yml": sha256_of(os.environ["COMPOSE_YML"]),
    },
    "restart_counts": restart_counts,
    "restart_deltas": restart_deltas,
    "enabled_features": {
        "document_routing": routing_enabled,
        "demo_mode": demo_enabled,
        "local_eseal": local_eseal_enabled,
    },
}

path = os.environ["EVIDENCE_FILE"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(evidence, fh, indent=2)
    fh.write("\n")
print(f"  Wrote {path}")
PY
}
