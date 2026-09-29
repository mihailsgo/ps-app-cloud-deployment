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

Container logs (redact_log_line) get more rules, because a log line is not
a config assignment: a secret there has no key to recognise it by.
ps-server's apiProtect logging (API_PROTECT_LOGS_ENABLED) writes the raw
bearer token, and signing requests carry the drawn signature as a base64
image. So JWTs become <jwt redacted>, any base64 run of 200+ characters
becomes <base64 N chars elided> (it is a document or an image, never
something support needs to read), any other 200+ character run of token
characters (base64url, an opaque token) becomes <N chars elided>, and a
secret-named key=value anywhere in the line (a form body such as
...&client_secret=abc) is redacted as well.

As a filter (support-bundle.sh):

  python3 installation-scripts/lib/redact.py --filter        < config.js
  docker compose logs ps-server | python3 installation-scripts/lib/redact.py --filter --log

Line endings are kept as they are; bytes that are not UTF-8 become U+FFFD.
Without arguments it runs its self-test.
"""

import io
import re
import sys
import time

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


# ── Logs ────────────────────────────────────────────────────────────────────
# A drawn signature, a PDF or any other payload, with its data: URI prefix
# when it has one.
_BASE64_RUN_RE = re.compile(r"(?:data:[a-z]+/[a-z0-9.+-]+;base64,)?[A-Za-z0-9+/]{200,}={0,2}")
# Any other run of 200+ token characters: base64url, an opaque token. Also
# what keeps redact_line() linear: its unanchored key and URL-scheme patterns
# retry from every position of a run of their characters, which costs the
# square of the run's length (a 160 000-character run took minutes).
_OPAQUE_RUN_RE = re.compile(r"[A-Za-z0-9+/_.\-]{200,}={0,2}")
_JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*")
# key=value anywhere in the line: query strings and form bodies
# (grant_type=client_credentials&client_secret=...), which redact_line's
# line-start rule never sees behind a log line's timestamp. Starts only at
# the beginning of a key-character run, so a long run costs one pass.
_LOG_KV_RE = re.compile(r"""(?P<prefix>(?<![A-Za-z0-9_.\-])(?P<key>[A-Za-z0-9_.\-]+)=)(?P<value>[^\s&;,"'<>]+)""")
JWT_REDACTED = "<jwt redacted>"


def _elide_base64(m):
    text = m.group(0)
    prefix = ""
    if text.startswith("data:"):
        # The media type is not secret and says what was there (image/png,
        # application/pdf); only the payload goes.
        prefix, _, text = text.partition(",")
        prefix += ","
    return f"{prefix}<base64 {len(text)} chars elided>"


def redact_log_line(line):
    """redact_line() plus log-only rules: JWTs -> <jwt redacted>,
    base64 runs of 200+ chars (drawn signatures, PDFs) -> <base64 N chars elided>,
    other 200+ char token runs -> <N chars elided>, and secret-named
    key=value pairs anywhere in the line.

    JWTs go first (a token's payload segment is itself a long base64 run),
    then long runs, before redact_line() (see _OPAQUE_RUN_RE)."""
    line = _JWT_RE.sub(JWT_REDACTED, line)
    line = _BASE64_RUN_RE.sub(_elide_base64, line)
    line = _OPAQUE_RUN_RE.sub(lambda mm: f"<{len(mm.group(0))} chars elided>", line)
    line = redact_line(line)
    return _LOG_KV_RE.sub(
        lambda mm: f"{mm.group('prefix')}{REDACTED}" if is_secret_key(mm.group("key")) else mm.group(0), line)


def _filter(redact):
    """stdin -> stdout, one line at a time, each line's own ending kept.
    Binary streams wrapped here, so no platform newline translation (a
    Windows python3 would otherwise write CRLF) and no locale encoding."""
    src = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace", newline="")
    dst = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", newline="")
    for line in src:
        body = line.rstrip("\r\n")
        dst.write(redact(body) + line[len(body):])
    dst.flush()


USAGE = """Usage:
  python3 installation-scripts/lib/redact.py                  run the self-test
  python3 installation-scripts/lib/redact.py --filter         redact config text, stdin -> stdout
  python3 installation-scripts/lib/redact.py --filter --log   redact log text (also JWTs, base64 runs)
"""


def _self_test():
    cases = {
        '    STAMP_API_KEY: "abcDEF123==",': '    STAMP_API_KEY: "<redacted>",',
        '        "secret": "s3cr3tExAmPl"': '        "secret": "<redacted>"',
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
        # A log timestamp before the first colon is not a key that looks secret.
        "2026-09-29T10:00:00Z ps-server ready": "2026-09-29T10:00:00Z ps-server ready",
    }
    log_cases = {
        "2026-09-29T10:00:00Z Authorization: Bearer abcdef123456":
            "2026-09-29T10:00:00Z Authorization: Bearer <redacted>",
        "2026-09-29T10:00:01Z [apiProtect] Bearer token: eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig_part":
            "2026-09-29T10:00:01Z [apiProtect] Bearer token: <jwt redacted>",
        '{"signatureImage":"data:image/png;base64,' + "A" * 300 + '"}':
            '{"signatureImage":"data:image/png;base64,<base64 300 chars elided>"}',
        "[request:end] {path: '/api/stamp', status: 200}": "[request:end] {path: '/api/stamp', status: 200}",
        "  data: 'grant_type=client_credentials&client_id=padsign-backend&client_secret=s3cr3tExAmPl',":
            "  data: 'grant_type=client_credentials&client_id=padsign-backend&client_secret=<redacted>',",
        "2026-09-29T10:00:02Z pulled sha256:" + "a" * 64: "2026-09-29T10:00:02Z pulled sha256:" + "a" * 64,
        "      password: changeit": "      password: <redacted>",
        "refresh " + "ab-cd_ef." * 30 + " done": "refresh <270 chars elided> done",
    }
    failed = 0
    for fn, table in ((redact_line, cases), (redact_log_line, log_cases)):
        for given, want in table.items():
            got = fn(given)
            if got != want:
                failed += 1
                print(f"FAIL {fn.__name__}\n  given: {given}\n  want:  {want}\n  got:   {got}")
    # Linear, not quadratic, in a long run of key characters: this took
    # minutes before _OPAQUE_RUN_RE, and milliseconds with it.
    started = time.monotonic()
    got = redact_log_line("abc-def_" * 20000)
    if got != "<160000 chars elided>" or time.monotonic() - started > 10:
        failed += 1
        print(f"FAIL redact_log_line on a 160000-character run: {got[:60]!r}, {time.monotonic() - started:.1f} s")
    total = len(cases) + len(log_cases) + 1
    print("redact.py self-test:", "FAIL" if failed else "OK", f"({total - failed}/{total})")
    return 1 if failed else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        raise SystemExit(_self_test())
    if args == ["--filter"]:
        _filter(redact_line)
    elif sorted(args) == ["--filter", "--log"]:
        _filter(redact_log_line)
    else:
        sys.stderr.write(USAGE)
        raise SystemExit(2)
