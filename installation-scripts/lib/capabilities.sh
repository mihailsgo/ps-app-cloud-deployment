# shellcheck shell=bash
#
# Shared reader for release/capabilities.json.
#
# Sourced by upgrade.sh and toggle-features.sh, which both gate an action on the
# deployed image being new enough. Before this file the minimum tag was a bash
# constant copied into each script (and restated in prose in two documents), so
# the two gates were kept in sync by hand - the comment in toggle-features.sh
# literally read "ported from upgrade.sh's identical gate". The numbers now live
# in the registry and the mechanism lives here, so neither can drift.
#
# Expects "$repo_root" to be set by the sourcing script.

capabilities_json="${capabilities_json:-${repo_root}/release/capabilities.json}"

# Reads one field out of the registry. Uses python3 - already a need_cmd in
# toggle-features.sh, and how validate-config.sh reads JSON - rather than jq,
# which nothing in this repo depends on.
#
#   capability_read <capability> <components|why|min:COMPONENT|unreleased:COMPONENT>
#
# components lists every component the entry constrains: the ones with a min and
# the ones with an unreleased tag.
#
# unreleased:COMPONENT is the newest released tag known NOT to have the
# capability, for one whose code is merged but not yet in any release (the
# registry then has no min for it). See the header comment of
# release/capabilities.json.
#
# Exits 3 on an unreadable registry, 4 on an unknown capability, naming what the
# registry does define in both cases.
capability_read() {
  python3 - "$capabilities_json" "$1" "$2" <<'PY'
import json, sys
path, cap, field = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(open(path))
except Exception as exc:
    sys.stderr.write("ERROR: cannot read capability registry %s: %s\n" % (path, exc))
    sys.exit(3)
entry = data.get("capabilities", {}).get(cap)
if entry is None:
    known = ", ".join(sorted(data.get("capabilities", {}))) or "(none)"
    sys.stderr.write("ERROR: unknown capability '%s'.\n" % cap)
    sys.stderr.write("       %s defines: %s\n" % (path, known))
    sys.exit(4)
if field == "why":
    sys.stdout.write(entry.get("why", "") + "\n")
elif field == "components":
    names = list(entry.get("min", {}))
    names += [n for n in entry.get("unreleased", {}) if n not in names]
    sys.stdout.write("\n".join(names))
elif field.startswith("min:"):
    sys.stdout.write(entry.get("min", {}).get(field[4:], ""))
elif field.startswith("unreleased:"):
    sys.stdout.write(entry.get("unreleased", {}).get(field[11:], ""))
PY
}

# True when <have> is strictly older than <min>, by the same sort -V comparison
# the hardcoded gates used.
#
#   capability_tag_older <have> <min>
capability_tag_older() {
  local have="$1" min="$2" smaller
  [[ "$have" == "$min" ]] && return 1
  smaller="$(printf '%s\n%s\n' "$have" "$min" | sort -V | head -1)"
  [[ "$smaller" == "$have" ]]
}

# Does <tag> of <component> have <capability>?
#
#   capability_tag_has <capability> <component> <tag>
#
# Returns 0 yes, 1 no (older than the minimum, or - for a capability not yet
# in any release - not newer than the newest tag known to lack it), 2 the
# registry says nothing about that component, 3 unreadable registry or unknown
# capability (the reader has already printed why).
capability_tag_has() {
  local cap="$1" component="$2" tag="$3" min lacking rc=0
  min="$(capability_read "$cap" "min:${component}")" || return 3
  if [[ -n "$min" ]]; then
    capability_tag_older "$tag" "$min" && return 1
    return 0
  fi
  lacking="$(capability_read "$cap" "unreleased:${component}")" || rc=$?
  [[ "$rc" == 0 ]] || return 3
  [[ -z "$lacking" ]] && return 2
  # Newer than the newest tag without it: only a release cut after the
  # capability merged can be.
  capability_tag_older "$lacking" "$tag"
}

# Prints a capability's rationale, wrapped and indented for an error block.
#
#   capability_explain <capability>
capability_explain() {
  capability_read "$1" why | fold -s -w 70 | sed -e 's/[[:space:]]*$//' -e 's/^/       /'
}
