#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# Documentation and public-repository hygiene checks:
#
#   - every relative markdown link and #anchor in tracked *.md resolves;
#   - every documentation/<page>.md path named in scripts, compose, the
#     wizard, release files and the agent skill exists;
#   - README.md lists every documentation page, with its title;
#   - both copies of the agent skill are identical;
#   - no tracked file carries a pattern that must never ship in this public
#     repository (private-repo links, personal paths, private keys, ...);
#   - the only tracked keystores are the ones the release ships on purpose.
#
# Usage:
#   ./installation-scripts/tests/test-docs.sh
#
# Read-only. Exit codes: 0 all passed, 1 a check failed, 2 missing dependency.
# ============================================================================

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 2
src_root="$root"
# shellcheck source=lib/watchdog.sh
. "${src_root}/installation-scripts/tests/lib/watchdog.sh"
watchdog_start
# Git Bash rewrites any argument that starts with / (a pattern such as
# /opt/psapp included) into a Windows path, which silently matches nothing.
# No effect on Linux.
export MSYS2_ARG_CONV_EXCL='*'
for c in git python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c is required" >&2; exit 2; }
done

pass=0
failed=0
ok_case()   { pass=$((pass + 1)); printf '  PASS %s\n' "$1"; }
fail_case() { failed=$((failed + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
report() {  # <name> <output of a check that prints one line per problem>
  if [[ -z "$2" ]]; then ok_case "$1"; else fail_case "$1" "$2"; fi
}

echo ""
echo "Markdown links:"
out="$(git ls-files -z '*.md' | python3 -c '
import os, re, sys
files = [f for f in sys.stdin.read().split("\0") if f and os.path.exists(f)]
fence = re.compile(r"```.*?```", re.S)
def slug(h):
    h = re.sub(r"[`*~]", "", h.strip().lower())
    return re.sub(r"[^\w\- ]", "", h).replace(" ", "-")
anchors = {}
for f in files:
    seen, found = {}, set()
    for m in re.finditer(r"^#{1,6}\s+(.*)$", fence.sub("", open(f, encoding="utf-8").read()), re.M):
        b = slug(m.group(1)); n = seen.get(b, 0); seen[b] = n + 1
        found.add(b if n == 0 else "%s-%d" % (b, n))
    anchors[os.path.normpath(f)] = found
for f in files:
    for m in re.finditer(r"\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)", fence.sub("", open(f, encoding="utf-8").read())):
        t = m.group(1)
        if re.match(r"^[a-z][a-z0-9+.-]*:", t):
            continue
        path, _, frag = t.partition("#")
        target = os.path.normpath(os.path.join(os.path.dirname(f), path)) if path else os.path.normpath(f)
        if not os.path.exists(target):
            print("%s: %s (missing)" % (f, t))
        elif frag and target.endswith(".md") and frag not in anchors.get(target, set()):
            print("%s: %s (no such heading)" % (f, t))
')"
report "every relative link and anchor resolves" "$out"

echo ""
echo "Documentation paths named outside documentation/:"
out="$(git grep -hoE 'documentation/[0-9]{2}[a-z0-9-]*\.md' -- \
         installation-scripts deployment-wizard/lib deployment-wizard/routes deployment-wizard/views \
         deployment-wizard/public docker-compose.yml release renovate.json .claude/skills .agents/skills \
         dmss-digital-stamping-service AGENTS.md SECURITY.md 2>/dev/null \
       | sort -u | while read -r p; do [[ -f "$p" ]] || echo "$p"; done)"
report "every documentation/<page>.md they name exists" "$out"

echo ""
echo "README contents list:"
out="$(python3 -c '
import glob, os, re
readme = open("README.md", encoding="utf-8").read()
for f in sorted(glob.glob("documentation/*.md")):
    f = f.replace(os.sep, "/")
    title = open(f, encoding="utf-8").readline().lstrip("# ").strip()
    name = title.split(" ", 1)[1] if re.match(r"^\d+\.", title) and not re.match(r"^\d+\.\d", title) else title
    if "](%s)" % f not in readme:
        print("%s is not linked from README.md" % f)
    elif "[%s](%s)" % (name, f) not in readme:
        print("%s: README.md link text is not its title %r" % (f, name))
')"
report "README.md links every page under its own title" "$out"

echo ""
echo "Agent skill:"
if cmp -s .claude/skills/padsign-deploy/SKILL.md .agents/skills/padsign-deploy/SKILL.md; then
  ok_case ".claude and .agents copies of the padsign-deploy skill are identical"
else
  fail_case ".claude and .agents copies of the padsign-deploy skill differ - edit both"
fi

echo ""
echo "Public-repository hygiene:"
# Patterns that must never ship. This file is excluded so it can name them.
out="$(git grep -nIE \
  -e 'psapp-saas' \
  -e 'github\.com/mihailsgo/(psapp|tl-)' \
  -e '[A-Za-z]:[\\]Users[\\]' -e '/Users/[A-Za-z]' -e 'AppData[\\/]' \
  -e '/opt/psapp' -e '/opt/trustlynx' \
  -e '@gmail\.com' \
  -e '^-----BEGIN ([A-Z]+ )?PRIVATE KEY-----.?$' \
  -- . ':!installation-scripts/tests/test-docs.sh' 2>&1; echo "rc=$?")"
# git grep: 1 = no match (good), 0 = matches, anything else = the search
# itself failed (never read that as "clean").
case "${out##*rc=}" in
  1) out="" ;;
  0) out="$(sed '$d' <<< "$out" | cut -c1-200)" ;;
  *) out="git grep failed: $(sed '$d' <<< "$out")" ;;
esac
report "no private-repo links, personal paths, private keys or retired install paths" "$out"

# A carriage return in a script breaks it on Linux (`set -euo pipefail\r`),
# and one inside a quoted string (tr -d '<CR>') silently changes what it
# does. Checked on the committed content, so a Windows checkout's CRLF
# working tree does not count.
# The pattern is PCRE's \r, not a literal CR: Git for Windows drops a CR
# from its arguments, and an empty pattern matches every file.
out="$(git grep --cached -lIP '\r' -- '*.sh' '*.py' '*.service.example' 2>&1; echo "rc=$?")"
case "${out##*rc=}" in
  1) out="" ;;
  0) out="$(sed '$d' <<< "$out")" ;;
  *) out="git grep failed: $(sed '$d' <<< "$out")" ;;
esac
report "no committed shell/Python file contains a carriage return" "$out"

allowed_keystores="dmss-container-and-signature-services/dmssrootca.p12
dmss-container-and-signature-services/ssl_tsl_truststore.p12
dmss-digital-stamping-service/seal/seal.p12
installation-scripts/assets/dmss-digital-stamping-service/seal/seal.p12"
out="$(git ls-files '*.p12' '*.pfx' '*.jks' '*.key' '*.pem' | grep -vxF "$allowed_keystores")"
report "the only tracked keystores are the labelled demo/public ones" "$out"

echo ""
echo "${pass} passed, ${failed} failed."
[[ "$failed" == 0 ]]
