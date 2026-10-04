#!/usr/bin/env python3
"""The addresses ps-server uses to reach the DMSS services, in config/config.js.

ps-server builds every archive / container-signature call from five keys. Each
can hold the in-network address (the Docker service name, what the release
ships) or the public one (https://<host>/archive/api/..., through nginx, what
releases up to ps-server 3.34 shipped). The code only concatenates them, so
either works, and any one can differ from the others.

This module reads those keys and rewrites them in place, preserving every
other byte of the file (comments, quoting, trailing commas, line endings):

  status <config.js>                    one line per key:
                                        KEY<TAB>state<TAB>value<TAB>expects<TAB>points-at
                                        (expects/points-at: archive | container;
                                        points-at is empty for other/missing)
  plan   <config.js> internal|public    what apply would change, without writing
  apply  <config.js> internal|public    the same, written to the file

  states: internal | public | other (a value this tool leaves alone, e.g.
  a hand-made address or a JS expression) | missing

Direction `internal` also adds ARCHIVE_PUBLIC_BASE_URL (the public archive
address webhook receivers are given as archiveUrl) when the file has none,
preceded by a comment carrying MARKER. Direction `public` writes the public
form back, taking the host from an existing ARCHIVE_PUBLIC_BASE_URL or, failing
that, --host, and removes only an ARCHIVE_PUBLIC_BASE_URL that carries MARKER.
Both directions are idempotent: a key already in the requested form is not
touched, so a second run changes nothing.

plan / apply print one line per change:
  KEY<TAB>set<TAB>old<TAB>new      a key rewritten
  ARCHIVE_PUBLIC_BASE_URL<TAB>add<TAB><TAB>value
  ARCHIVE_PUBLIC_BASE_URL<TAB>remove<TAB>value<TAB>
Exit 0 on success (even with no change lines), 2 on bad usage, 3 when the
requested direction cannot be carried out (message on stderr).
"""
import re
import sys

MARKER = "added by upgrade.sh --use-internal-dmss-urls"

ARCHIVE_INTERNAL = "http://dmss-archive-services:8090/api/"
CONTAINER_INTERNAL = "http://dmss-container-and-signature-services:8092/api/"

KEYS = (
    "ARCHIVE_API_BASE_URL",
    "CREATE_DOCUMENT_API_URL",
    "DOCUMENT_DOWNLOAD_API_URL",
    "VISUAL_SIGNATURE_API_TEMPLATE",
    "FORM_FILL_API_URL",
)
PUBLIC_KEY = "ARCHIVE_PUBLIC_BASE_URL"

# Which service each key belongs to.
SERVICE_OF = {
    "ARCHIVE_API_BASE_URL": "archive",
    "CREATE_DOCUMENT_API_URL": "archive",
    "DOCUMENT_DOWNLOAD_API_URL": "archive",
    "VISUAL_SIGNATURE_API_TEMPLATE": "container",
    "FORM_FILL_API_URL": "container",
    PUBLIC_KEY: "archive",
}

PUBLIC_RE = re.compile(r"^https?://([^/\s]+)/(archive|container)/api/(.*)$")


def key_re(key):
    # indentation + optional-quoted key + colon, then a quoted literal and the
    # rest of the line (comma, comment, CR) untouched.
    return re.compile(
        r"^(?P<pre>[ \t]*(?P<q>[\"']?)" + re.escape(key) + r"(?P=q)[ \t]*:[ \t]*)"
        r"(?P<d>[\"'])(?P<val>[^\"'\r\n]*)(?P=d)(?P<post>[^\n]*)$",
        re.M,
    )


def key_present_re(key):
    return re.compile(r"^[ \t]*[\"']?" + re.escape(key) + r"[\"']?[ \t]*:", re.M)


def classify(value):
    """internal | public | other, for a string literal's value."""
    if value.startswith(ARCHIVE_INTERNAL) or value.startswith(CONTAINER_INTERNAL):
        return "internal"
    if PUBLIC_RE.match(value):
        return "public"
    return "other"


def read_keys(text):
    """{key: (state, value)} for the five keys and ARCHIVE_PUBLIC_BASE_URL."""
    out = {}
    for key in KEYS + (PUBLIC_KEY,):
        m = key_re(key).search(text)
        if m:
            out[key] = (classify(m.group("val")), m.group("val"))
        elif key_present_re(key).search(text):
            out[key] = ("other", "")
        else:
            out[key] = ("missing", "")
    return out


def points_at(value):
    """archive | container, for an internal or public value; '' otherwise."""
    if value.startswith(ARCHIVE_INTERNAL):
        return "archive"
    if value.startswith(CONTAINER_INTERNAL):
        return "container"
    m = PUBLIC_RE.match(value)
    return m.group(2) if m else ""


def to_internal(value):
    m = PUBLIC_RE.match(value)
    if not m:
        return None
    base = ARCHIVE_INTERNAL if m.group(2) == "archive" else CONTAINER_INTERNAL
    return base + m.group(3)


def to_public(value, public_origin):
    """public_origin: 'https://host' (no trailing slash)."""
    if value.startswith(ARCHIVE_INTERNAL):
        return public_origin + "/archive/api/" + value[len(ARCHIVE_INTERNAL):]
    if value.startswith(CONTAINER_INTERNAL):
        return public_origin + "/container/api/" + value[len(CONTAINER_INTERNAL):]
    return None


def public_origin_of(keys):
    """'https://host' taken from the first public archive/container value."""
    for key in KEYS:
        state, value = keys[key]
        if state == "public":
            m = PUBLIC_RE.match(value)
            return value[: value.index("/" + m.group(2) + "/api/")]
    return None


def newline_of(text):
    return "\r\n" if "\r\n" in text else "\n"


def compute(text, direction, host):
    """Returns (new_text, changes). changes: list of (key, action, old, new)."""
    keys = read_keys(text)
    nl = newline_of(text)
    changes = []
    new = text

    if direction == "internal":
        # Remember the public archive address before it is rewritten.
        public_origin = public_origin_of(keys)
        for key in KEYS:
            state, value = keys[key]
            if state != "public":
                continue
            replacement = to_internal(value)
            m = key_re(key).search(new)
            new = new[: m.start("val")] + replacement + new[m.end("val"):]
            changes.append((key, "set", value, replacement))
        if keys[PUBLIC_KEY][0] == "missing" and public_origin and changes:
            # Insert before ARCHIVE_API_BASE_URL (the key it describes), else
            # before the first rewritten key.
            anchor_key = "ARCHIVE_API_BASE_URL" if keys["ARCHIVE_API_BASE_URL"][0] != "missing" else changes[0][0]
            m = key_re(anchor_key).search(new)
            indent = re.match(r"[ \t]*", m.group("pre")).group(0)
            value = public_origin + "/archive/api/"
            block = (
                f"{indent}// Public address of the archive: the archiveUrl in webhook payloads.{nl}"
                f"{indent}// {MARKER}; --use-public-dmss-urls removes it.{nl}"
                f'{indent}{PUBLIC_KEY}: "{value}",{nl}'
            )
            new = new[: m.start()] + block + new[m.start():]
            changes.append((PUBLIC_KEY, "add", "", value))

    elif direction == "public":
        pub_state, pub_value = keys[PUBLIC_KEY]
        origin = None
        if pub_state == "public":
            m = PUBLIC_RE.match(pub_value)
            if m and m.group(2) == "archive":
                origin = pub_value[: pub_value.index("/archive/api/")]
        if origin is None and host:
            origin = "https://" + host
        wanted = [k for k in KEYS if keys[k][0] == "internal"]
        if wanted and origin is None:
            raise SystemExit_(3, "cannot tell which public hostname to write: no ARCHIVE_PUBLIC_BASE_URL in "
                                 "config.js and no --host (nginx/nginx.conf names no single server_name)")
        for key in wanted:
            value = keys[key][1]
            replacement = to_public(value, origin)
            m = key_re(key).search(new)
            new = new[: m.start("val")] + replacement + new[m.end("val"):]
            changes.append((key, "set", value, replacement))
        # Remove the key only when this tool added it: its marker comment is
        # the line just above (with the one-line description above that).
        lines = new.splitlines(keepends=True)
        for i, line in enumerate(lines):
            m = key_re(PUBLIC_KEY).match(line.rstrip("\r\n"))
            if not m:
                continue
            if i > 0 and MARKER in lines[i - 1]:
                first = i - 1
                if i > 1 and lines[i - 2].lstrip().startswith("//"):
                    first = i - 2
                changes.append((PUBLIC_KEY, "remove", m.group("val"), ""))
                new = "".join(lines[:first] + lines[i + 1:])
            break
    else:
        raise SystemExit_(2, "direction must be 'internal' or 'public'")
    return new, changes


class SystemExit_(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def main(argv):
    if len(argv) < 3 or argv[1] not in ("status", "plan", "apply"):
        sys.stderr.write(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    direction, host = None, ""
    rest = argv[3:]
    if cmd != "status":
        if not rest:
            sys.stderr.write("ERROR: %s needs a direction (internal|public)\n" % cmd)
            return 2
        direction = rest[0]
        rest = rest[1:]
    while rest:
        if rest[0] == "--host" and len(rest) > 1:
            host, rest = rest[1], rest[2:]
        else:
            sys.stderr.write("ERROR: unexpected argument %s\n" % rest[0])
            return 2
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        sys.stderr.write("ERROR: cannot read %s: %s\n" % (path, exc))
        return 3

    if cmd == "status":
        for key, (state, value) in read_keys(text).items():
            target = points_at(value) if state in ("internal", "public") else ""
            sys.stdout.write("%s\t%s\t%s\t%s\t%s\n" % (key, state, value, SERVICE_OF[key], target))
        return 0

    try:
        new, changes = compute(text, direction, host)
    except SystemExit_ as exc:
        sys.stderr.write("ERROR: %s\n" % exc.message)
        return exc.code
    if cmd == "apply" and new != text:
        # In place (same inode, owner, group and mode): config.js's group is
        # what lets the ps-server image read it.
        with open(path, "r+b") as fh:
            fh.seek(0)
            fh.write(new.encode("utf-8"))
            fh.truncate()
    for key, action, old, newv in changes:
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (key, action, old, newv))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
