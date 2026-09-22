# shellcheck shell=bash
#
# Writes deployment-evidence.json at the repo root after a successful
# bootstrap.sh / upgrade.sh run: this deployment repo's own git revision and
# a dirty flag (mirroring the "-dirty" convention psapp/scripts/build-image.sh
# already stamps on images - see documentation/39-release-procedure.md - now
# applied to the deployment repo's own checkout), the pinned image tags and,
# best-effort, their OCI revision labels, sha256 checksums of the four files
# configure-host.sh/upgrade.sh mutate per host, and a best-effort read of
# which optional features are currently enabled.
#
# Deliberately records only derived, already-non-secret state - never the raw
# CLI arguments a script was invoked with. --admin-pass / --backend-secret /
# --users must never end up in this file.
#
# Expects "$repo_root" to be set by the sourcing script.

# Writes deployment-evidence.json.
#
#   write_deployment_evidence <script-name>
write_deployment_evidence() {
  local script_name="$1"
  local evidence_file="${repo_root}/deployment-evidence.json"

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
  server_tag="$(grep -oP 'mihailsgordijenko/ps-server:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "")"
  client_tag="$(grep -oP 'mihailsgordijenko/ps-client:\K[0-9.]+' "${repo_root}/docker-compose.yml" 2>/dev/null || echo "")"

  local server_rev="" client_rev=""
  if command -v docker >/dev/null 2>&1; then
    [[ -n "$server_tag" ]] && server_rev="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "mihailsgordijenko/ps-server:${server_tag}" 2>/dev/null || echo "")"
    [[ -n "$client_tag" ]] && client_rev="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "mihailsgordijenko/ps-client:${client_tag}" 2>/dev/null || echo "")"
  fi

  SCRIPT_NAME="$script_name" \
  GIT_REV="$git_rev" GIT_BRANCH="$git_branch" GIT_DIRTY="$git_dirty" \
  SERVER_TAG="$server_tag" CLIENT_TAG="$client_tag" \
  SERVER_REV="$server_rev" CLIENT_REV="$client_rev" \
  CONFIG_JS="${repo_root}/config/config.js" \
  CONSTANTS_JSON="${repo_root}/config/constants.json" \
  NGINX_CONF="${repo_root}/nginx/nginx.conf" \
  COMPOSE_YML="${repo_root}/docker-compose.yml" \
  ENV_FILE="${repo_root}/.env" \
  EVIDENCE_FILE="$evidence_file" \
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

evidence = {
    "schema_version": 1,
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
    "config_checksums": {
        "config/config.js": sha256_of(os.environ["CONFIG_JS"]),
        "config/constants.json": sha256_of(os.environ["CONSTANTS_JSON"]),
        "nginx/nginx.conf": sha256_of(os.environ["NGINX_CONF"]),
        "docker-compose.yml": sha256_of(os.environ["COMPOSE_YML"]),
    },
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
