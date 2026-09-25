"""Secrets a fresh install must not keep, and where the ones it needs live.

Called by configure-host.sh (bootstrap.sh passes --generate-secrets) and
validate-config.sh, never directly by an operator. Nothing here ever prints a
secret value: only field names, states and file modes.

  shipped <config.js>
      One "<STATUS>\t<message>" line per credential in config.js that still
      holds the value this PUBLIC repository ships (STATUS OK or WARN), or a
      single OK line when none does. validate-config.sh's convention, the
      same one lib/digest_gate.py uses. Reads $PADSIGN_HOST_HINT for the
      command it suggests, and $PADSIGN_OVERLAY_HOST (set on a checkout run
      as release baseline + overlay) to point at the overlay instead.

  generate <config.js>
      Replaces REGISTER_PDF_API_KEY and SESSION_SECRET with random values
      when, and only when, they still hold the shipped value. A value anyone
      already changed is never touched, so re-running is a no-op. Prints the
      name of each field it replaced. Writes the file in place (same inode),
      so its owner, group and mode are kept.

  env-set <env-file> <KEY>
      Sets KEY in a docker compose .env file to the value in $SECRET_VALUE
      (never argv). A new file is created mode 600 (owned by the project
      directory's owner when run as root, so `docker compose` still works for
      that user); an existing one keeps its owner and loses any "other"
      permission bits. The value is double-quoted with \\ " $ escaped, which
      compose's .env parser reads back verbatim (checked on Compose v2.38).

  admin-password <docker-compose.yml> [<env-file>]
      Prints how the tracked compose file sets the Keycloak bootstrap admin
      password: "inline-default" (the literal demo value admin), "inline"
      (any other literal - a real password in a tracked file), "placeholder
      <VAR> set|default" (read from VAR, which the shell environment or the
      .env file sets, or not), or "absent".

  admin-password-placeholder <docker-compose.yml>
      Rewrites an inline KEYCLOAK_ADMIN_PASSWORD value to the release's
      ${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin} reference, keeping the
      line's indentation, list style and quoting. Prints "changed",
      "unchanged" (already a reference) or "absent".

Why the shipped values are known by sha256 and not read from git HEAD: a
host that commits its own config.js (documentation/04-04 allows "stash or
commit") would otherwise have its real values taken for the shipped ones, and
`generate` would rotate them. The hashes identify public values without this
file becoming one more copy of them. When a release changes a shipped value
in config/config.js, add its hash here: installation-scripts/tests/
test-secret-hygiene.sh fails until every value the checkout ships is listed.
"""

import hashlib
import os
import re
import secrets
import stat
import sys

sys.dont_write_bytecode = True  # never leave a __pycache__/ in the checkout

# label, config.js regex (group "v" = the value), sha256 of every value this
# repository has shipped for it, how to replace it (None = not ours to choose).
FIELDS = [
    ("backend client secret (KEYCLOAK_CONFIG.credentials.secret)",
     r"""^\s*["']?secret["']?\s*:\s*(?P<q>["'])(?P<v>[^"'\n]*)(?P=q)""",
     {"a1c2cb054021a46d6591b476de20b3a6d533c47ddac5e3444d29188ec1687f35"},
     None),
    ("REGISTER_PDF_API_KEY",
     r"""^\s*["']?REGISTER_PDF_API_KEY["']?\s*:\s*(?P<q>["'])(?P<v>[^"'\n]*)(?P=q)""",
     {"718b196ccbf20dfd514b7dc24464f3e4116177d55a707dd587e0b92388951cf8"},
     lambda: "tlx_pdf_" + secrets.token_hex(32)),
    ("SESSION_SECRET",
     r"""^\s*["']?SESSION_SECRET["']?\s*:\s*(?P<q>["'])(?P<v>[^"'\n]*)(?P=q)""",
     {"b0bc523a9ebfead11d5f452711dbd6da8147df65db06be488a6aac516d0619b0"},
     lambda: secrets.token_hex(32)),
    ("STAMP_API_KEY",
     r"""^\s*["']?STAMP_API_KEY["']?\s*:\s*(?P<q>["'])(?P<v>[^"'\n]*)(?P=q)""",
     {"4455f71d8673905b28b19fa65f02f607b878d615ecdcaf3566cbb79e2948a6f5"},
     None),
    ("STAMP_COMPANY_SECRET",
     r"""^\s*["']?STAMP_COMPANY_SECRET["']?\s*:\s*(?P<q>["'])(?P<v>[^"'\n]*)(?P=q)""",
     {"d0e3a7a61c343e8c2cfc8cf07dd63ce147a86e3da907bf51802f3758b14fe0f3"},
     None),
]
EXTERNAL_STAMP_FIELDS = {"STAMP_API_KEY", "STAMP_COMPANY_SECRET"}

# The compose variable the release's docker-compose.yml reads Keycloak's
# first-boot admin password from. Deliberately NOT KEYCLOAK_ADMIN_PASSWORD:
# operators export that one for the scripts (documentation/42-02 and others),
# and compose lets the shell environment override .env, so reusing the name
# would let an exported current password change the keycloak container's
# definition (and recreate it) on the next `docker compose up`.
FIRST_BOOT_VAR = "KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD"
PLACEHOLDER = "${%s:-admin}" % FIRST_BOOT_VAR
ADMIN_PASSWORD_KEYS = ("KEYCLOAK_ADMIN_PASSWORD", "KC_BOOTSTRAP_ADMIN_PASSWORD")


def die(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(code)


def sha256(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def read_text(path):
    with open(path, encoding="utf-8", newline="") as fh:
        return fh.read()


def write_in_place(path, text):
    # Truncate-and-write keeps the inode, so owner, group and mode survive -
    # unlike perl -i / sed -i, which write a new file as the current user.
    with open(path, "r+", encoding="utf-8", newline="") as fh:
        fh.seek(0)
        fh.write(text)
        fh.truncate()


def published(label):
    for name, _rx, hashes, _gen in FIELDS:
        if name == label:
            return hashes
    return set()


def field_values(text):
    for label, rx, hashes, gen in FIELDS:
        m = re.search(rx, text, re.MULTILINE)
        yield label, m, hashes, gen


# ── shipped ────────────────────────────────────────────────────────────────

def cmd_shipped(config_js):
    text = read_text(config_js)
    local_stamp = bool(re.search(r"""^\s*STAMP_MODE\s*:\s*["']local["']""", text, re.MULTILINE))
    host = os.environ.get("PADSIGN_HOST_HINT") or "<host>"
    found = 0
    for label, m, hashes, gen in field_values(text):
        if not m or not m.group("v") or sha256(m.group("v")) not in hashes:
            continue
        found += 1
        if label in EXTERNAL_STAMP_FIELDS:
            if local_stamp:
                print(f"OK\t{label} is the demo value shipped in the public repository, but unused here "
                      "(STAMP_MODE is \"local\", so ps-server never sends it)")
            else:
                print(f"WARN\t{label} is the shared demo e-sealing credential shipped in the public "
                      "repository (value not shown) - ask your e-sealing provider for this "
                      "deployment's own and put it in config/config.js")
        elif gen is not None:
            # An overlay-managed checkout is never edited in place
            # (documentation/42-06): the value changes in the overlay.
            fix = ("change it in the overlay's config.js (documentation/42-06, Changing a value in the overlay)"
                   if os.environ.get("PADSIGN_OVERLAY_HOST") else
                   f"./installation-scripts/configure-host.sh --host {host} --generate-secrets, then "
                   "docker compose restart ps-server")
            print(f"WARN\t{label} is still the value shipped in the public repository (value not shown). "
                  f"Fix: {fix}"
                  + (" - and give the new key (documentation/18-05) to every /api/registerPDF client, "
                     "e.g. the Virtual Printer" if label == "REGISTER_PDF_API_KEY" else ""))
        else:
            print(f"WARN\t{label} is still the value shipped in the public repository - rotate it "
                  "(value not shown)")
    if not found:
        print("OK\tno config.js credential still equals the value shipped in the repository")


# ── generate ───────────────────────────────────────────────────────────────

def cmd_generate(config_js):
    text = read_text(config_js)
    replaced = []
    for label, rx, hashes, gen in FIELDS:
        if gen is None:
            continue
        m = re.search(rx, text, re.MULTILINE)
        if not m or sha256(m.group("v")) not in hashes:
            continue
        text = text[:m.start("v")] + gen() + text[m.end("v"):]
        replaced.append(label)
    if replaced:
        write_in_place(config_js, text)
    for label in replaced:
        print(label)


# ── .env ───────────────────────────────────────────────────────────────────

def dotenv_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$") + '"'


def dotenv_key_re(key):
    return re.compile(r"^\s*(?:export\s+)?" + re.escape(key) + r"\s*=")


ENV_COMMENT = {
    FIRST_BOOT_VAR: (
        "# Keycloak's master-realm admin password, used by Keycloak ONLY on its first\n"
        "# boot against an empty keycloak_data volume (documentation/17-01). Written by\n"
        "# bootstrap.sh; editing it later changes nothing in Keycloak. Keep this file\n"
        "# mode 600 and out of git (.gitignore already excludes it).\n"
    ),
}


def cmd_env_set(env_file, key):
    value = os.environ.get("SECRET_VALUE")
    if value is None:
        die("SECRET_VALUE is not set")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        die(f"{key}: a value with a control character (newline, tab, ...) is not supported")
    line = f"{key}={dotenv_quote(value)}"
    key_re = dotenv_key_re(key)

    if not os.path.exists(env_file):
        fd = os.open(env_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(ENV_COMMENT.get(key, "") + line + "\n")
        os.chmod(env_file, 0o600)
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            # Run as root (sudo): hand the file to whoever owns the project
            # directory, or `docker compose` run as that user can no longer
            # read .env and fails outright ("open .env: permission denied").
            st = os.stat(os.path.dirname(os.path.abspath(env_file)))
            if st.st_uid != 0:
                os.chown(env_file, st.st_uid, st.st_gid)
        print("created")
        return

    text = read_text(env_file)
    nl = "\r\n" if "\r\n" in text else "\n"
    out, done = [], False
    for raw in text.splitlines(keepends=True):
        if key_re.match(raw):
            if not done:
                out.append(line + nl)
                done = True
            continue  # a second definition of the same key: drop it
        out.append(raw)
    if not done:
        if out and not out[-1].endswith(("\n", "\r")):
            out.append(nl)
        comment = ENV_COMMENT.get(key, "")
        out.append(comment.replace("\n", nl) + line + nl)
    write_in_place(env_file, "".join(out))
    mode = stat.S_IMODE(os.stat(env_file).st_mode)
    if mode & 0o007:
        os.chmod(env_file, mode & ~0o007)
    print("updated")


def dotenv_value(env_file, key):
    """The value KEY has in env_file (best effort, enough to tell empty from
    set), or None when the file or the key is absent."""
    try:
        text = read_text(env_file)
    except OSError:
        return None
    key_re = dotenv_key_re(key)
    value = None
    for raw in text.splitlines():
        if key_re.match(raw):
            v = raw.split("=", 1)[1].strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            value = v
    return value


# ── docker-compose.yml admin password ──────────────────────────────────────

# "      - KEYCLOAK_ADMIN_PASSWORD=value", '- "KEYCLOAK_ADMIN_PASSWORD=value"' or
# the mapping form "KEYCLOAK_ADMIN_PASSWORD: value". Matched against a line
# with its line ending removed.
_ADMIN_LINE_RE = re.compile(
    r"""^(?P<prefix>\s*(?:-\s*)?(?P<q>["']?)(?P<key>%s)\s*[=:]\s*)(?P<value>.*?)(?P<tail>(?P=q)\s*)\Z"""
    % "|".join(ADMIN_PASSWORD_KEYS)
)
_REFERENCE_RE = re.compile(r"^\$(?:\{(?P<braced>[A-Za-z_][A-Za-z0-9_]*)(?P<rest>[^}]*)\}|(?P<bare>[A-Za-z_][A-Za-z0-9_]*))$")


def split_eol(raw):
    body = raw.rstrip("\r\n")
    return body, raw[len(body):]


def unquote(value):
    v = value.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v


def admin_lines(text):
    for raw in text.splitlines(keepends=True):
        body, eol = split_eol(raw)
        m = _ADMIN_LINE_RE.match(body)
        if m and not body.lstrip().startswith("#"):
            yield raw, body, eol, m


def classify(value, env_file):
    v = unquote(value)
    ref = _REFERENCE_RE.match(v)
    if ref:
        var = ref.group("braced") or ref.group("bare")
        rest = ref.group("rest") or ""
        # Compose's own order: the shell environment first, then .env.
        if var in os.environ:
            resolved = os.environ[var]
        else:
            resolved = dotenv_value(env_file, var) if env_file else None
        if resolved:
            return f"placeholder {var} set"
        # Unset or empty: ${VAR:-x} / ${VAR-x} fall back to x.
        default = rest[2:] if rest.startswith(":-") else rest[1:] if rest.startswith("-") else ""
        if default == "admin":
            return f"placeholder {var} default"
        if default:
            return "inline"  # a literal fallback written into the tracked file
        return f"placeholder {var} empty"
    if v == "admin":
        return "inline-default"
    if v == "":
        return "absent"
    return "inline"


def cmd_admin_password(compose_yml, env_file=None):
    states = [classify(m.group("value"), env_file) for _raw, _b, _e, m in admin_lines(read_text(compose_yml))]
    if not states:
        print("absent")
        return
    # Worst first: a real password in the tracked file beats everything.
    for want in ("inline", "inline-default"):
        if want in states:
            print(want)
            return
    print(states[0])


def cmd_admin_password_placeholder(compose_yml):
    text = read_text(compose_yml)
    out, seen, changed = [], False, False
    for raw in text.splitlines(keepends=True):
        body, eol = split_eol(raw)
        m = _ADMIN_LINE_RE.match(body)
        if m and m.group("key") == "KEYCLOAK_ADMIN_PASSWORD" and not body.lstrip().startswith("#"):
            seen = True
            if not _REFERENCE_RE.match(unquote(m.group("value"))):
                raw = m.group("prefix") + PLACEHOLDER + m.group("tail") + eol
                changed = True
        out.append(raw)
    if changed:
        write_in_place(compose_yml, "".join(out))
    print("changed" if changed else "unchanged" if seen else "absent")


def main(argv):
    if len(argv) < 3:
        die(__doc__.strip().splitlines()[0] + " - see the module docstring for usage")
    cmd, args = argv[1], argv[2:]
    if cmd == "shipped" and len(args) == 1:
        cmd_shipped(args[0])
    elif cmd == "generate" and len(args) == 1:
        cmd_generate(args[0])
    elif cmd == "env-set" and len(args) == 2:
        cmd_env_set(args[0], args[1])
    elif cmd == "admin-password" and len(args) in (1, 2):
        cmd_admin_password(*args)
    elif cmd == "admin-password-placeholder" and len(args) == 1:
        cmd_admin_password_placeholder(args[0])
    else:
        die(f"unknown command or wrong arguments: {' '.join(argv[1:])}")


if __name__ == "__main__":
    main(sys.argv)
