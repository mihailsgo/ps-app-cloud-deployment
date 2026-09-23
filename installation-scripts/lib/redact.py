"""Secret redaction for anything this repo's tooling prints about config files.

Imported (via sys.path) by the python3 heredocs in diff-baseline-overlay.sh
and overlay.sh, so there is exactly one definition of "which fields are
secret" instead of one per script (the same duplication problem
lib/dir-permissions.sh's header describes for directory modes).

The rule is name-based, not value-based: a line is redacted when the KEY it
assigns looks secret-bearing (secret, password, api key, token, ...), no
matter what the value looks like. A value-based heuristic ("looks random")
misses weak secrets such as "changeit" - which are exactly the known-default
values an operator most needs to find, and least wants pasted into a ticket.

Redaction replaces the whole value with <redacted>. It deliberately does not
print a hash or a prefix: a short hash of a low-entropy password is trivially
brute-forced offline, and "the value changed" is already conveyed by the line
appearing in a diff at all.
"""

import re

# Key names that carry secret material in this stack's config files:
# config.js (KEYCLOAK_CONFIG.credentials.secret, STAMP_API_KEY,
# STAMP_COMPANY_SECRET, REGISTER_PDF_API_KEY, SESSION_SECRET,
# CUSTOMER_DATA_API_KEY, STAMP_LOCAL.password), docker-compose.yml
# (KEYCLOAK_ADMIN_PASSWORD, SPRING_SECURITY_USER_PASSWORD), DMSS
# application.yml (keystore/datasource `password:`), .env files.
SECRET_KEY_RE = re.compile(
    r"(secret|passw(or)?d|pwd|api[_-]?key|apikey|token|credential|"
    r"private[_-]?key|authorization|cookie)",
    re.IGNORECASE,
)

REDACTED = "<redacted>"

# key: value | key = value | "key": value | - KEY=value | export KEY=value
_ASSIGNMENT_RE = re.compile(
    r"""^(?P<prefix>\s*(?:-\s*|export\s+)?["']?(?P<key>[A-Za-z0-9_.\-]+)["']?\s*[:=]\s*)(?P<value>.*)$"""
)
# Inline object members such as: headers: { "Authorization": "Bearer abc" }
_INLINE_MEMBER_RE = re.compile(
    r"""(?P<prefix>["']?(?P<key>[A-Za-z0-9_.\-]+)["']?\s*:\s*)(?P<quote>["'])(?P<value>(?:(?!(?P=quote)).)*)(?P=quote)"""
)
_BEARER_RE = re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{6,}")
# userinfo in URLs: scheme://user:password@host
_URL_USERINFO_RE = re.compile(r"(?P<scheme>[a-z][a-z0-9+.\-]*://)(?P<user>[^/\s:@]+):(?P<pw>[^/\s@]+)@", re.IGNORECASE)


def is_secret_key(key):
    return bool(key) and bool(SECRET_KEY_RE.search(key))


def _redact_value_keep_punctuation(value):
    """Replace a scalar value but keep a trailing comma / closing quote style,
    so a redacted JS/JSON/YAML line still reads like the original shape."""
    stripped = value.rstrip()
    trailing = ""
    if stripped.endswith(","):
        trailing = ","
    quote = ""
    body = stripped[:-1] if trailing else stripped
    body = body.strip()
    if len(body) >= 2 and body[0] == body[-1] and body[0] in "\"'":
        quote = body[0]
    if body in ("", "{", "[", "|", ">"):
        # Opening a nested block (e.g. `credentials: {`), not a scalar.
        return value
    return f"{quote}{REDACTED}{quote}{trailing}"


def redact_line(line):
    """Return `line` with any secret-bearing value replaced by <redacted>."""
    m = _ASSIGNMENT_RE.match(line)
    if m and is_secret_key(m.group("key")):
        line = m.group("prefix") + _redact_value_keep_punctuation(m.group("value"))

    def _member(mm):
        if is_secret_key(mm.group("key")):
            q = mm.group("quote")
            return f"{mm.group('prefix')}{q}{REDACTED}{q}"
        return mm.group(0)

    line = _INLINE_MEMBER_RE.sub(_member, line)
    line = _BEARER_RE.sub(lambda mm: f"{mm.group(1)} {REDACTED}", line)
    line = _URL_USERINFO_RE.sub(lambda mm: f"{mm.group('scheme')}{mm.group('user')}:{REDACTED}@", line)
    return line


def redact_json_value(key, value):
    """For key-by-key JSON diffs: hide the value when the key is secret."""
    return REDACTED if is_secret_key(key) else value


if __name__ == "__main__":
    # Self-test: `python3 installation-scripts/lib/redact.py`
    cases = {
        '    STAMP_API_KEY: "abcDEF123==",': '    STAMP_API_KEY: "<redacted>",',
        '        "secret": "ZhFzSQ9mFvNs"': '        "secret": "<redacted>"',
        "      - KEYCLOAK_ADMIN_PASSWORD=hunter2": "      - KEYCLOAK_ADMIN_PASSWORD=<redacted>",
        "      password: changeit": "      password: <redacted>",
        '          headers: { "Authorization": "Bearer abcdef123456" },': '          headers: { "Authorization": "<redacted>" },',
        "    url: https://user:pa55word@host/x": "    url: https://user:<redacted>@host/x",
        "    SESSION_SECRET: 'change-this',": "    SESSION_SECRET: '<redacted>',",
        '    "credentials": {': '    "credentials": {',
        "    server_name padsign.example.com;": "    server_name padsign.example.com;",
        "COMPOSE_PROFILES=local-eseal": "COMPOSE_PROFILES=local-eseal",
        "  - SPRING_SECURITY_USER_PASSWORD=changeit": "  - SPRING_SECURITY_USER_PASSWORD=<redacted>",
        '    STAMP_LOCAL: { password: "changeit" },': '    STAMP_LOCAL: { password: "<redacted>" },',
    }
    failed = 0
    for given, want in cases.items():
        got = redact_line(given)
        if got != want:
            failed += 1
            print(f"FAIL\n  given: {given}\n  want:  {want}\n  got:   {got}")
    print("redact.py self-test:", "FAIL" if failed else "OK", f"({len(cases) - failed}/{len(cases)})")
    raise SystemExit(1 if failed else 0)
