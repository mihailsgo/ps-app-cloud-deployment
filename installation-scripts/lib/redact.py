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

redact_line() is what the importers use. Text that leaves the host
(support-bundle.sh) goes through `--filter`, which adds, for configuration
(redact_config_line + RedactingFilter):

  - URLs: an http(s) URL outside the stack keeps only scheme://host[:port]
    (a webhook's path or ?code= is its credential); the deployment's own
    host (--keep-host), localhost and the stack's service names keep their
    path. Secret query parameters and key=value pairs go anywhere.
  - every value inside a `headers` block, whatever the header is called;
  - the lines of a YAML block scalar under a secret key (`password: |`);
  - a PEM private key, which becomes one `<private key redacted>` line.

and for container logs (`--filter --log`, redact_log_line), where a secret
has no config key to recognise it by: the rules run after the
`docker compose logs --timestamps` prefix ("ps-server-1  | <time> "), a
secret-named word followed by a value is redacted anywhere in the line
(Spring's "Using generated security password: ..."), JWTs become
<jwt redacted>, base64 runs of 200+ characters (drawn signatures,
documents) become <base64 N chars elided>, other 200+ character token runs
become <N chars elided>, and ps-server's signing activity lines
("padsignAudit") shrink to their event and outcome: no signer, no file name.

  python3 installation-scripts/lib/redact.py --filter --keep-host padsign.example.com < config.js
  docker compose logs ps-server | python3 installation-scripts/lib/redact.py --filter --log

Line endings are kept as they are; bytes that are not UTF-8 become U+FFFD.
Without arguments it runs its self-test.
"""

import io
import json
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
    r"(secret|passw(or)?d|pwd|passphrase|api[_-]?key|apikey|token|credential|"
    r"private[_-]?key|authorization|cookie)",
    re.IGNORECASE,
)
# A key named `key` (REGISTER_PDF_API_KEYS: [{ company, key }]) or ending in
# _key / -key / .key. Not keystore, keyAlias, keyUsage, *JsonKey or monkey:
# those name a file, an alias or a field, not a secret.
_KEY_NAME_RE = re.compile(r"(?:^|[_.\-])key$", re.IGNORECASE)

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
    return bool(key) and bool(SECRET_KEY_RE.search(key) or _KEY_NAME_RE.search(key))


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


# ── URLs ────────────────────────────────────────────────────────────────────
# A webhook URL is a capability: whoever has https://hooks.example.com/T0/B0/x
# or ...?code=x can post to it. Outside the stack only scheme://host[:port]
# is kept. The deployment's own URLs (--keep-host), localhost and the stack's
# service names keep their path, which support does need; their secret query
# parameters still go (_QUERY_SECRET_RE, _KV_RE).
_URL_RE = re.compile(r"""(?i)\bhttps?:(?:\\?/){2}[^\s"'<>`]*[^\s"'<>`;,.)\]}]""")
_LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "host.docker.internal",
                "keycloak", "ps-server", "ps-client", "nginx", "wizard"}
# Query parameters that carry a capability without a secret-looking name.
_QUERY_SECRET_RE = re.compile(r"(?i)(?P<prefix>[?&;](?:code|sig|signature|key|token|access_token|api_key|apikey|password|secret)=)(?P<value>[^&\s\"'<>#;,]+)")
URL_PATH_REDACTED = "/" + REDACTED


def _is_local_host(host, keep_hosts):
    host = host.lower().strip("[]")
    if host in _LOCAL_HOSTS or host in keep_hosts or host.startswith("127."):
        return True
    # dmss-archive-services, pdf-converter: a dot-less name resolves only on
    # the Docker network or the host, never to a public endpoint.
    return host.startswith("dmss-") or ("." not in host and ":" not in host)


def _redact_url(url, keep_hosts):
    scheme, sep, rest = url.partition("//")
    scheme += sep
    authority = re.match(r"[^/\\?#]*", rest).group(0)
    tail = rest[len(authority):]
    if "@" in authority:
        userinfo, _, hostport = authority.rpartition("@")
        user = userinfo.split(":", 1)[0]
        authority = f"{user}:{REDACTED}@{hostport}" if ":" in userinfo else authority
    else:
        hostport = authority
    host = hostport.split("]")[0] + "]" if hostport.startswith("[") else hostport.split(":")[0]
    if _is_local_host(host, keep_hosts):
        return scheme + authority + tail
    if tail in ("", "/", "\\/"):
        return scheme + authority + tail
    return scheme + authority + URL_PATH_REDACTED


def redact_urls(line, keep_hosts=()):
    """Cut every non-local http(s) URL after its host; see _URL_RE."""
    if "/" not in line:
        return line
    keep = {h.lower() for h in keep_hosts}
    return _URL_RE.sub(lambda m: _redact_url(m.group(0), keep), line)


# ── Rules for both --filter modes ──────────────────────────────────────────
_JWT_RE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*")
JWT_REDACTED = "<jwt redacted>"
# key=value anywhere in the line: query strings and form bodies
# (grant_type=client_credentials&client_secret=...), which redact_line's
# line-start rule never sees behind a log line's timestamp. Starts only at
# the beginning of a key-character run, so a long run costs one pass.
_KV_RE = re.compile(r"""(?P<prefix>(?<![A-Za-z0-9_.\-])(?P<key>[A-Za-z0-9_.\-]+)=)(?P<value>[^\s&;,"'<>]+)""")


def _kv_and_query(line):
    if "=" not in line:
        return line
    line = _KV_RE.sub(
        lambda mm: f"{mm.group('prefix')}{REDACTED}" if is_secret_key(mm.group("key")) else mm.group(0), line)
    return _QUERY_SECRET_RE.sub(lambda mm: f"{mm.group('prefix')}{REDACTED}", line)


def redact_config_line(line, keep_hosts=()):
    """What `--filter` applies to each line of a configuration file:
    redact_line() plus JWTs, URLs (redact_urls) and secret key=value /
    query parameters anywhere in the line. URLs go first: redact_line()'s
    userinfo rule inserts a `<`, which would end the URL match early."""
    line = _JWT_RE.sub(JWT_REDACTED, line)
    line = redact_urls(line, keep_hosts)
    return _kv_and_query(redact_line(line))


# ── Logs ────────────────────────────────────────────────────────────────────
# `docker compose logs --timestamps`: "ps-server-1  | 2026-09-29T10:00:00.1Z ",
# either part optional. redact_line()'s rules are anchored at the start of
# the text, so they run on what follows.
_LOG_PREFIX_RE = re.compile(r"^(?:\S+\s+\|\s)?(?:\d{4}-\d\d-\d\dT\S+\s)?")
# A drawn signature, a PDF or any other payload, with its data: URI prefix
# when it has one.
_BASE64_RUN_RE = re.compile(r"(?:data:[a-z]+/[a-z0-9.+-]+;base64,)?[A-Za-z0-9+/]{200,}={0,2}")
# Any other run of 200+ token characters: base64url, an opaque token. Also
# what keeps redact_line() linear: its unanchored key and URL-scheme patterns
# retry from every position of a run of their characters, which costs the
# square of the run's length (a 160 000-character run took minutes).
_OPAQUE_RUN_RE = re.compile(r"[A-Za-z0-9+/_.\-]{200,}={0,2}")
# A secret-named word and its value anywhere in prose: Spring's "Using
# generated security password: <uuid>", util.inspect's "  password: 'x'"
# behind a prefix, "token=...". Never an already redacted <...> value.
_PROSE_SECRET_RE = re.compile(
    r"""(?P<prefix>(?<![A-Za-z0-9_.\-])(?P<key>[A-Za-z0-9_.\-]*?(?:passw(?:or)?d|pwd|passphrase|secret|token)[A-Za-z0-9_.\-]*)["']?(?::\s+|\s*=\s*))"""
    r"""(?P<value>"[^"]*"|'[^']*'|[^\s,;&)}\]<>"'{\[][^\s,;&)}\]<>"']*)""",
    re.IGNORECASE,
)
# Every word that can make redact_line() or _PROSE_SECRET_RE change a line
# (SECRET_KEY_RE, _KEY_NAME_RE, the Bearer/Basic and userinfo rules).
_SECRET_HINT_RE = re.compile(r"(?i)secret|passw|pwd|passphrase|api[_-]?key|token|credential|private|"
                             r"authoriz|cookie|key|bearer|basic|://")
# ps-server's signing activity log line (one JSON object per signing event):
# the signer's e-mail address and the file name must not leave the host.
_AUDIT_RE = re.compile(r'"padsignAudit"\s*:\s*1\b')
_AUDIT_WORD_RE = re.compile(r"^[A-Za-z0-9._:-]{1,64}$")


def _elide_base64(m):
    text = m.group(0)
    prefix = ""
    if text.startswith("data:"):
        # The media type is not secret and says what was there (image/png,
        # application/pdf); only the payload goes.
        prefix, _, text = text.partition(",")
        prefix += ","
    return f"{prefix}<base64 {len(text.rstrip('='))} chars elided>"


def _audit_summary(text):
    try:
        entry = json.loads(text[text.index("{"):text.rindex("}") + 1])
        event, outcome = str(entry["event"]), str(entry["outcome"])
        if _AUDIT_WORD_RE.match(event) and _AUDIT_WORD_RE.match(outcome):
            return f"<padsignAudit event={event} outcome={outcome} omitted>"
    except (ValueError, KeyError, TypeError):
        pass
    return "<padsignAudit line omitted>"


def redact_log_line(line, keep_hosts=()):
    """redact_config_line() plus log-only rules, applied after the compose
    prefix and timestamp: JWTs -> <jwt redacted>, base64 runs of 200+
    chars (drawn signatures, PDFs) -> <base64 N chars elided>, other 200+
    char token runs -> <N chars elided>, secret-named words followed by a
    value anywhere in the line, and signing activity lines reduced to
    their event and outcome.

    JWTs go first (a token's payload segment is itself a long base64 run),
    then long runs, before redact_line() (see _OPAQUE_RUN_RE)."""
    prefix = _LOG_PREFIX_RE.match(line).group(0)
    text = line[len(prefix):]
    if _AUDIT_RE.search(text):
        return prefix + _audit_summary(text)
    text = _JWT_RE.sub(JWT_REDACTED, text)
    text = _BASE64_RUN_RE.sub(_elide_base64, text)
    text = _OPAQUE_RUN_RE.sub(lambda mm: f"<{len(mm.group(0))} chars elided>", text)
    text = redact_urls(text, keep_hosts)
    # Most log lines name no secret at all: skip the per-key rules for them
    # (a 24-hour log is hundreds of thousands of lines).
    if _SECRET_HINT_RE.search(text):
        text = redact_line(text)
        text = _PROSE_SECRET_RE.sub(lambda mm: f"{mm.group('prefix')}{REDACTED}", text)
    return prefix + _kv_and_query(text)


# ── --filter: whole streams ─────────────────────────────────────────────────
PRIVATE_KEY_REDACTED = "<private key redacted>"
_PEM_BEGIN_RE = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")
_PEM_END_RE = re.compile(r"-----END [A-Z0-9 ]*PRIVATE KEY-----")
# `headers: {` in config.js (DOCUMENT_ROUTING webhooks), or a YAML `headers:`
# mapping: every value in it is a credential, whatever the header is called.
_HEADERS_JS_RE = re.compile(r"""(?:^|[\s{,])["']?headers["']?\s*:\s*\{""")
_HEADERS_YAML_RE = re.compile(r"""^(?P<indent>\s*)["']?headers["']?\s*:\s*(?:#.*)?$""")
_MEMBER_VALUE_RE = re.compile(
    r"""(?P<k>["']?[A-Za-z0-9_.\-]+["']?\s*:\s*)(?P<v>"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`|[^,}\s][^,}]*?)(?=\s*(?:,|}|$))""")
# `password: |` / `secret: >-`: a YAML block scalar under a secret key.
_BLOCK_SCALAR_RE = re.compile(
    r"""^(?P<indent>\s*)(?:-\s*)?["']?(?P<key>[A-Za-z0-9_.\-]+)["']?\s*:\s*[|>][-+0-9]*\s*(?:#.*)?$""")


def _redact_members(text):
    def one(m):
        v = m.group("v")
        q = v[0] if v[0] in "\"'`" and len(v) >= 2 and v[-1] == v[0] else ""
        return f"{m.group('k')}{q}{REDACTED}{q}"
    return _MEMBER_VALUE_RE.sub(one, text)


def _close_brace(text, depth):
    """Index just past the `}` that brings `depth` to 0, or None, and the
    depth left at the end of `text`. Braces inside quotes do not count."""
    quote = None
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "\"'`":
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i, 0
        i += 1
    return None, depth


class RedactingFilter:
    """The `--filter` state machine. Per line: redact_config_line() or
    redact_log_line(). Across lines, in both modes: a PEM private key
    becomes one `<private key redacted>` line (unterminated: everything to
    the end of the input). Config mode also redacts every value inside a
    `headers` block and the lines of a YAML block scalar under a secret key."""

    def __init__(self, log=False, keep_hosts=()):
        self.log = log
        self.keep_hosts = tuple(keep_hosts)
        self.in_pem = False
        self.js_headers_depth = 0     # > 0: inside `headers: { ...`
        self.yaml_block_indent = None  # inside a `headers:` mapping or secret block scalar
        self.yaml_block_is_headers = False

    def _line(self, text):
        if self.log:
            return redact_log_line(text, self.keep_hosts)
        return redact_config_line(text, self.keep_hosts)

    def _pem(self, body):
        """Returns (handled, output). handled: the line was (part of) a key."""
        if self.in_pem:
            end = _PEM_END_RE.search(body)
            if end:
                self.in_pem = False
            return True, None
        begin = _PEM_BEGIN_RE.search(body)
        if not begin:
            return False, body
        head = body[:begin.start()]
        # A compose prefix, YAML indentation or `key: "` stays, redacted as usual.
        out = (self._line(head) if head.strip() else head) + PRIVATE_KEY_REDACTED
        end = _PEM_END_RE.search(body, begin.end())
        if end:
            rest = body[end.end():]
            return True, out + (self._line(rest) if rest.strip() else rest)
        # BEGIN without END: a key serialized on one line ("\n" escapes) was
        # cut short - that line only. Otherwise the key runs on.
        if "\\n" not in body[begin.end():]:
            self.in_pem = True
        return True, out

    def _config_blocks(self, body):
        """Returns output for a line inside a headers block / secret block
        scalar, or None when the line is not in one."""
        if self.js_headers_depth:
            close, depth = _close_brace(body, self.js_headers_depth)
            if close is None:
                self.js_headers_depth = depth
                return _redact_members(body)
            self.js_headers_depth = 0
            return _redact_members(body[:close]) + self._line(body[close:])
        if self.yaml_block_indent is not None:
            indent = len(body) - len(body.lstrip())
            if not body.strip():
                return body
            if indent > self.yaml_block_indent:
                if self.yaml_block_is_headers:
                    return _redact_members(body)
                return body[:indent] + REDACTED
            self.yaml_block_indent = None
        return None

    def feed(self, body):
        """One line without its ending -> the redacted line, or None to drop it."""
        handled, out = self._pem(body)
        if handled:
            return out
        if self.log:
            return self._line(body)
        inside = self._config_blocks(body)
        if inside is not None:
            return inside
        m = _HEADERS_JS_RE.search(body)
        if m:
            close, depth = _close_brace(body[m.end():], 1)
            if close is None:
                self.js_headers_depth = depth
                return self._line(body[:m.end()]) + _redact_members(body[m.end():])
            end = m.end() + close
            return self._line(body[:m.end()]) + _redact_members(body[m.end():end]) + self._line(body[end:])
        m = _HEADERS_YAML_RE.match(body)
        if m:
            self.yaml_block_indent, self.yaml_block_is_headers = len(m.group("indent")), True
            return body
        m = _BLOCK_SCALAR_RE.match(body)
        if m and is_secret_key(m.group("key")):
            self.yaml_block_indent, self.yaml_block_is_headers = len(m.group("indent")), False
            return body
        return self._line(body)

    def run(self, lines):
        """Lines with their endings in, redacted lines with the same endings out."""
        for line in lines:
            body = line.rstrip("\r\n")
            out = self.feed(body)
            if out is not None:
                yield out + line[len(body):]


def _filter(log, keep_hosts):
    """stdin -> stdout through RedactingFilter. Binary streams wrapped here,
    so no platform newline translation (a Windows python3 would otherwise
    write CRLF) and no locale encoding."""
    src = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace", newline="")
    dst = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace", newline="")
    for out in RedactingFilter(log=log, keep_hosts=keep_hosts).run(src):
        dst.write(out)
    dst.flush()


USAGE = """Usage:
  python3 installation-scripts/lib/redact.py                  run the self-test
  python3 installation-scripts/lib/redact.py --filter [--log] [--keep-host HOST]...
      stdin -> stdout. Config text by default; --log also removes JWTs, base64
      runs, secret words in prose and signing activity lines. --keep-host: a
      host whose URLs keep their path (the deployment's own hostname).
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
        # A member named `key` (REGISTER_PDF_API_KEYS entries), or *_key.
        '      { company: "Amit", key: "tlx_pdf_LEAK1" },': '      { company: "Amit", key: "<redacted>" },',
        '        key: "tlx_pdf_LEAK2"': '        key: "<redacted>"',
        "  signing_key: abc": "  signing_key: <redacted>",
        "  passphrase: hunter2": "  passphrase: <redacted>",
        # ... but not names that merely contain "key".
        "          keystore: file:/seal/seal.p12": "          keystore: file:/seal/seal.p12",
        "  keyAlias: seal": "  keyAlias: seal",
        "  key-alias: seal": "  key-alias: seal",
        "  keyUsage: digitalSignature": "  keyUsage: digitalSignature",
        '      containerExtensionJsonKey: "containerExtension"': '      containerExtensionJsonKey: "containerExtension"',
        "  monkey: banana": "  monkey: banana",
    }
    log_cases = {
        "2026-09-29T10:00:00Z Authorization: Bearer abcdef123456":
            "2026-09-29T10:00:00Z Authorization: <redacted>",
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
        # Padding is not part of the payload count.
        "img " + "B" * 298 + "==": "img <base64 298 chars elided>",
        # docker compose logs --timestamps: "<service>-1  | <RFC3339> <text>".
        "container-signature-1  | 2026-09-29T10:00:00.000000000Z   password: LEAKPW":
            "container-signature-1  | 2026-09-29T10:00:00.000000000Z   password: <redacted>",
        "ps-server-1  | 2026-09-29T10:00:00.000000000Z secret: LEAKSEC":
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z secret: <redacted>",
        "ps-server-1  | 2026-09-29T10:00:00.000000000Z Authorization: Bearer abcdef123456":
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z Authorization: <redacted>",
        # Spring Boot prints the endpoint password it generated.
        "c-1  | 2026-09-29T10:00:00.000000000Z Using generated security password: 1b2c3d4e-LEAKGEN":
            "c-1  | 2026-09-29T10:00:00.000000000Z Using generated security password: <redacted>",
        "c-1  | 2026-09-29T10:00:00.000000000Z login failed, token=LEAKTOK1 user=bob":
            "c-1  | 2026-09-29T10:00:00.000000000Z login failed, token=<redacted> user=bob",
        # The wizard's access token (deployment-wizard/server.js), should its log ever get in.
        "wizard-1  | 2026-09-29T10:00:00.000000000Z   Access token: " + "0f" * 32:
            "wizard-1  | 2026-09-29T10:00:00.000000000Z   Access token: <redacted>",
        # Prose that only mentions the words stays.
        "ps-server-1  | 2026-09-29T10:00:00.000000000Z [apiProtect] Token valid: true":
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z [apiProtect] Token valid: true",
        "k-1  | 2026-09-29 10:00:00,123 WARN type=LOGIN_ERROR, clientId=padsign-client, error=invalid_user_credentials":
            "k-1  | 2026-09-29 10:00:00,123 WARN type=LOGIN_ERROR, clientId=padsign-client, error=invalid_user_credentials",
        # Webhook URLs carry their capability in the path or query: host only.
        "ps-server-1  | 2026-09-29T10:00:00.000000000Z [documentRouting:webhook] delivered { url: 'https://hooks.example.com/T0/B0/LEAK40', status: 200 }":
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z [documentRouting:webhook] delivered { url: 'https://hooks.example.com/<redacted>', status: 200 }",
        "POST https://fn.azurewebsites.net/api/hook?code=LEAK41 failed": "POST https://fn.azurewebsites.net/<redacted> failed",
        "GET https://u:LEAKUI@hooks.example.com:8443/x/y": "GET https://u:<redacted>@hooks.example.com:8443/<redacted>",
        # In-stack and local URLs keep their path; secret query parameters still go.
        "GET http://dmss-archive-services:8090/api/document/1?token=LEAKQ1&x=1":
            "GET http://dmss-archive-services:8090/api/document/1?token=<redacted>&x=1",
        "GET http://localhost:3001/api/x?sig=LEAKQ2": "GET http://localhost:3001/api/x?sig=<redacted>",
        # The signing activity log: never its signer or file name.
        'ps-server-1  | 2026-09-29T10:00:00.000000000Z {"padsignAudit":1,"ts":"2026-09-29T10:00:00Z","event":"signature.visual","outcome":"ok","user":"a@b.c","filename":"x.pdf"}':
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z <padsignAudit event=signature.visual outcome=ok omitted>",
        'ps-server-1  | 2026-09-29T10:00:00.000000000Z {"padsignAudit":1,"user":"a@b.c", truncated':
            "ps-server-1  | 2026-09-29T10:00:00.000000000Z <padsignAudit line omitted>",
    }
    # Whole streams through the --filter state machine: (log mode, keep hosts, in, out).
    stream_cases = [
        # A PEM private key becomes one line, in either mode; unterminated: to the end.
        (False, (), "a: 1\nk: |\n  -----BEGIN PRIVATE KEY-----\n  MIIEv\n  -----END PRIVATE KEY-----\nb: 2\n",
         "a: 1\nk: |\n  <private key redacted>\nb: 2\n"),
        (True, (), "x-1  | 2026-09-29T10:00:00Z -----BEGIN RSA PRIVATE KEY-----\nx-1  | MIIE\n",
         "x-1  | 2026-09-29T10:00:00Z <private key redacted>\n"),
        (False, (), 'k: "-----BEGIN EC PRIVATE KEY-----\\nMHc\\n-----END EC PRIVATE KEY-----\\n",\n',
         'k: "<private key redacted>\\n",\n'),
        # Every value in a headers block, whatever the header is called.
        (False, (), '  headers: { "X-Hook-Signature": "LEAK6", X-Auth: \'LEAK8\' },\n',
         '  headers: { "X-Hook-Signature": "<redacted>", X-Auth: \'<redacted>\' },\n'),
        (False, (), '  headers: {\n    "X-Webhook-Key": "LEAK7",\n    "X-Other": `LEAK9`\n  },\n  method: "POST",\n',
         '  headers: {\n    "X-Webhook-Key": "<redacted>",\n    "X-Other": `<redacted>`\n  },\n  method: "POST",\n'),
        (False, (), "  headers: {},\n  method: POST\n", "  headers: {},\n  method: POST\n"),
        (False, (), "headers:\n  X-Sig: LEAK10\nnext: 1\n", "headers:\n  X-Sig: <redacted>\nnext: 1\n"),
        # A YAML block scalar under a secret key.
        (False, (), "  password: |\n    LEAKB1\n\n    LEAKB2\n  user: sa\n",
         "  password: |\n    <redacted>\n\n    <redacted>\n  user: sa\n"),
        # URLs in configuration: the deployment's own host keeps its path.
        (False, ("padsign.example.com",),
         'A: "https://padsign.example.com/archive/api/",\nB: "https://hooks.example.com/services/T0/B0/LEAK3",\n'
         'C: "https://fn.example.net/api/hook?token=LEAK4",\nD: "jdbc:postgresql://db:5432/x?user=u&password=LEAK11",\n'
         "  proxy_pass http://ps-server:3001/;\n",
         'A: "https://padsign.example.com/archive/api/",\nB: "https://hooks.example.com/<redacted>",\n'
         'C: "https://fn.example.net/<redacted>",\nD: "jdbc:postgresql://db:5432/x?user=u&password=<redacted>",\n'
         "  proxy_pass http://ps-server:3001/;\n"),
        # Line endings survive.
        (False, (), "  password: x\r\nplain\n", "  password: <redacted>\r\nplain\n"),
    ]
    failed = 0
    for fn, table in ((redact_line, cases), (redact_log_line, log_cases)):
        for given, want in table.items():
            got = fn(given)
            if got != want:
                failed += 1
                print(f"FAIL {fn.__name__}\n  given: {given}\n  want:  {want}\n  got:   {got}")
    for log, keep, given, want in stream_cases:
        got = "".join(RedactingFilter(log=log, keep_hosts=keep).run(given.splitlines(keepends=True)))
        if got != want:
            failed += 1
            print(f"FAIL RedactingFilter(log={log})\n  given: {given!r}\n  want:  {want!r}\n  got:   {got!r}")
    # Linear, not quadratic, in a long run of key characters: this took
    # minutes before _OPAQUE_RUN_RE, and milliseconds with it.
    started = time.monotonic()
    got = redact_log_line("abc-def_" * 20000)
    if got != "<160000 chars elided>" or time.monotonic() - started > 10:
        failed += 1
        print(f"FAIL redact_log_line on a 160000-character run: {got[:60]!r}, {time.monotonic() - started:.1f} s")
    total = len(cases) + len(log_cases) + len(stream_cases) + 1
    print("redact.py self-test:", "FAIL" if failed else "OK", f"({total - failed}/{total})")
    return 1 if failed else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        raise SystemExit(_self_test())
    log, keep, filter_mode = False, [], False
    while args:
        a = args.pop(0)
        if a == "--filter":
            filter_mode = True
        elif a == "--log":
            log = True
        elif a == "--keep-host" and args and args[0] and not args[0].startswith("-"):
            keep.append(args.pop(0))
        else:
            filter_mode = False
            break
    if not filter_mode:
        sys.stderr.write(USAGE)
        raise SystemExit(2)
    _filter(log, keep)
