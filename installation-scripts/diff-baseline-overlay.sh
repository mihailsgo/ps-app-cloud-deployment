#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Baseline/overlay drift checker
#
# Diffs a live checkout's per-host-mutated files against a clean baseline and
# splits every difference into two buckets:
#   - EXPECTED OVERLAY: matches a known field configure-host.sh / upgrade.sh
#     document that they rewrite per deployment (hostname, cert paths,
#     backend secret, DEMO_COMPANY_ROLE, DOCUMENT_ROUTING, STAMP_MODE, image
#     tags, the signed-output mount, Keycloak admin creds, the local-eseal
#     service block).
#   - UNEXPECTED DRIFT: anything else — a hand edit that isn't one of those,
#     which is exactly what issue #7 is about being unable to tell apart from
#     a clean checkout today.
#
# This is a reporting tool, not a fixer: it never writes to either side.
#
# Usage:
#   ./installation-scripts/diff-baseline-overlay.sh --baseline <git-ref-or-path> [--live <path>]
#
# --baseline is tried first as a git ref inside --live's repo (git show
# <ref>:<path>), then as a plain directory. This covers both realistic uses:
# a host with git history ("git fetch && diff-baseline-overlay.sh --baseline
# origin/main") and a host that only has a fresh checkout to compare against.
#
# Known limitation (stated here rather than silently overreaching): the
# allow-list below is a second, purpose-built encoding of the same knowledge
# configure-host.sh and upgrade.sh already carry (each with its own copy of
# some of it — see installation-scripts/lib/dir-permissions.sh's header for
# the same duplication problem on the permissions side). If one of those
# scripts starts rewriting a new field, this list needs a matching update or
# that field will show up as drift even when it's an expected overlay value.
# Unifying all of these behind one shared pattern source is real follow-up
# work, not done here.
# ============================================================================

baseline=""
live=""

usage() {
  cat <<'EOF'
Usage:
  ./installation-scripts/diff-baseline-overlay.sh --baseline <git-ref-or-path> [--live <path>]

  --baseline   A git ref (tag/branch/commit) in --live's repo, or a path to a
               clean checkout directory, to compare against.
  --live       Path to the checkout to check for drift. Defaults to this
               script's own repo root.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) baseline="${2:-}"; shift 2;;
    --live) live="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "$baseline" ]]; then
  echo "ERROR: --baseline is required" >&2
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
live="${live:-$repo_root}"
live="$(cd "$live" && pwd)"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Missing dependency: $1" >&2
    exit 1
  fi
}
need_cmd git
need_cmd python3

tracked_files=(
  "nginx/nginx.conf"
  "config/constants.json"
  "config/config.js"
  "docker-compose.yml"
)

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

baseline_is_git_ref=false
if git -C "$live" rev-parse --verify --quiet "${baseline}^{commit}" >/dev/null 2>&1; then
  baseline_is_git_ref=true
elif [[ ! -d "$baseline" ]]; then
  echo "ERROR: --baseline '${baseline}' is neither a git ref resolvable in ${live} nor a directory" >&2
  exit 2
fi

missing_baseline=()
pairs=()
for f in "${tracked_files[@]}"; do
  live_path="${live}/${f}"
  if [[ ! -f "$live_path" ]]; then
    echo "  (skipping ${f}: not present in live checkout)" >&2
    continue
  fi

  base_tmp="${workdir}/$(echo "$f" | tr '/' '_').baseline"
  if [[ "$baseline_is_git_ref" == true ]]; then
    if ! git -C "$live" show "${baseline}:${f}" > "$base_tmp" 2>/dev/null; then
      missing_baseline+=("$f")
      continue
    fi
  else
    base_path="${baseline}/${f}"
    if [[ ! -f "$base_path" ]]; then
      missing_baseline+=("$f")
      continue
    fi
    cp "$base_path" "$base_tmp"
  fi
  pairs+=("${f}|${base_tmp}|${live_path}")
done

if [[ "${#missing_baseline[@]}" -gt 0 ]]; then
  echo "  (baseline has no version of: ${missing_baseline[*]} — reported as N/A below)" >&2
fi

if [[ "${#pairs[@]}" -eq 0 ]]; then
  echo "No comparable files found." >&2
  exit 1
fi

python3 - "${pairs[@]}" <<'PY'
import difflib
import json
import re
import sys

# One allow-list per tracked file. Each entry is a regex tested against a
# changed/added/removed line (its text, with the leading diff +/- stripped).
# A changed line is "expected overlay" if it matches any pattern for its file.
LINE_ALLOWLISTS = {
    "nginx/nginx.conf": [
        r"^\s*server_name\s+",
        r"^\s*ssl_certificate\s+",
        r"^\s*ssl_certificate_key\s+",
        r"location\s*/\s*\{",
        r"return\s+301",
        r"^\s*\}\s*$",
        r"^\s*\{\s*$",
    ],
    "config/config.js": [
        r"https://[^/\"']+/auth",
        r"https://[^/\"']+/archive/api/",
        r"https://[^/\"']+/container/api/",
        r"'https://[^']+'",
        r'"secret"\s*:\s*"',
        r"DEMO_COMPANY_ROLE\s*:\s*\"",
        r"STAMP_MODE\s*:\s*\"",
    ],
    "docker-compose.yml": [
        r"image:\s*[\"']?mihailsgordijenko/ps-(server|client):",
        r"signed-output:/signed-output",
        r"-\s*KEYCLOAK_ADMIN=",
        r"-\s*KEYCLOAK_ADMIN_PASSWORD=",
        r"-\s*SPRING_SECURITY_USER_NAME=",
        r"-\s*SPRING_SECURITY_USER_PASSWORD=",
    ],
}

# Markers that, if present anywhere in a hunk's added/removed lines, mean the
# whole hunk is a known wholesale block insertion (DOCUMENT_ROUTING/STAMP_LOCAL
# blocks in config.js, the local-eseal service in docker-compose.yml) rather
# than something line-diffable field by field.
HUNK_BLOCK_MARKERS = {
    "config/config.js": ["DOCUMENT_ROUTING", "STAMP_LOCAL"],
    "docker-compose.yml": ["dmss-digital-stamping-service"],
}

# constants.json is real JSON: diffed key-by-key instead of line-by-line.
JSON_ALLOWED_KEYS = {
    "config/constants.json": {
        "KEYCLOAK_URL",
        "KEYCLOAK_REDIRECT_URI",
        "KEYCLOAK_POST_LOGOUT_REDIRECT_URI",
        "PS_DOWNLOAD_API",
        "PDF_TEST_PATH",
        "DEMO_MODE",
    }
}


def classify_json(label, baseline_text, live_text):
    allowed = JSON_ALLOWED_KEYS[label]
    try:
        base = json.loads(baseline_text)
        live = json.loads(live_text)
    except Exception as exc:
        return None, [f"could not parse as JSON: {exc}"]
    drift = []
    for key in sorted(set(base) | set(live)):
        if base.get(key) == live.get(key):
            continue
        if key in allowed:
            continue
        drift.append(f"key '{key}': {base.get(key)!r} -> {live.get(key)!r}")
    return None, drift


def classify_lines(label, baseline_text, live_text):
    patterns = [re.compile(p) for p in LINE_ALLOWLISTS.get(label, [])]
    markers = HUNK_BLOCK_MARKERS.get(label, [])
    base_lines = baseline_text.splitlines()
    live_lines = live_text.splitlines()
    sm = difflib.SequenceMatcher(a=base_lines, b=live_lines, autojunk=False)
    drift = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        changed = base_lines[i1:i2] + live_lines[j1:j2]
        if any(m in line for line in changed for m in markers):
            continue  # whole hunk is a known block insertion/removal
        for line in changed:
            if not any(p.search(line) for p in patterns):
                drift.append(line)
    return None, drift


def main(argv):
    exit_code = 0
    for arg in argv[1:]:
        label, base_path, live_path = arg.split("|", 2)
        with open(base_path, "r", encoding="utf-8", errors="replace") as fh:
            baseline_text = fh.read()
        with open(live_path, "r", encoding="utf-8", errors="replace") as fh:
            live_text = fh.read()

        print(f"== {label} ==")
        if baseline_text == live_text:
            print("  OK   identical to baseline")
            continue

        if label in JSON_ALLOWED_KEYS:
            _, drift = classify_json(label, baseline_text, live_text)
        else:
            _, drift = classify_lines(label, baseline_text, live_text)

        if drift and drift[0].startswith("could not parse"):
            print(f"  WARN {drift[0]} — falling back to line diff")
            _, drift = classify_lines(label, baseline_text, live_text)

        if not drift:
            print("  OK   only expected overlay values differ")
        else:
            exit_code = 1
            print(f"  FAIL {len(drift)} unexpected drift line(s):")
            for line in drift:
                print(f"    DRIFT: {line}")

    return exit_code


sys.exit(main(sys.argv))
PY
