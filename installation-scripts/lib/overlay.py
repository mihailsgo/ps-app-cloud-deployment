"""Environment overlay: capture a deployed host's per-environment state into a
protected directory OUTSIDE the checkout, re-apply it onto a clean baseline
checkout, and verify the result. Driven by installation-scripts/overlay.sh;
see documentation/42-host-reconciliation-runbook.md for the operator flow.

Design constraints (psapp-saas#7):
  * Never modifies the source (live) directory during capture.
  * Never reads, moves, copies or rewrites signed-document storage
    (signed-output/, docs/). Storage stays exactly where it is; the overlay
    only points the new checkout's bind mounts at it.
  * Never prints a secret value: every line shown about a config file goes
    through lib/redact.py.
  * Never runs `docker compose up/down`: it only reads Docker state
    (`docker compose config`, `docker inspect`, `docker volume inspect`).
"""

import datetime
import difflib
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

# No .pyc next to the scripts: a __pycache__/ inside the checkout is exactly
# the kind of untracked file `verify` exists to flag.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from redact import is_secret_key, redact_line, REDACTED  # noqa: E402

SCHEMA_VERSION = 1

# Operational state that is never part of the overlay and never copied.
# Storage is deliberately listed: capture must not even read it.
EXCLUDED_DIRS = {
    ".git", "signed-output", "docs", ".rollback-snapshots", "node_modules",
    "tmp", "temp", "PSDOCS", "logs", "log", "__pycache__",
}
EXCLUDED_FILES = {"deployment-evidence.json", "deployment-evidence.json.previous", ".overlay-applied.json"}

STORAGE_TARGETS = {
    # container target path -> (service, human label)
    "/signed-output": ("ps-server", "signed documents written by ps-server (DOCUMENT_ROUTING filesystem strategy)"),
    "/docs": ("dmss-archive-services-fallback", "filesystem fallback archive"),
}

# Images whose version is owned by the release (upgrade.sh/rollback.sh rewrite
# them in docker-compose.yml). An overlay must never override these, or the
# next upgrade.sh would silently change nothing.
RELEASE_MANAGED_IMAGES = ("mihailsgordijenko/ps-server", "mihailsgordijenko/ps-client")

# Paths that are RELEASE content: scripts, tooling, docs, repo metadata. A
# difference here means the host runs an older (or hand-patched) release, not
# that the environment needs it - capturing it would silently downgrade the
# new release's scripts on apply. Reported, never captured.
RELEASE_CONTENT_PREFIXES = (
    "installation-scripts/", "deployment-wizard/", "documentation/", "release/",
    ".claude/", ".agents/", ".github/",
)
RELEASE_CONTENT_FILES = {
    "README.md", "CHANGELOG.md", "AGENTS.md", ".gitignore", ".gitattributes",
    "renovate.json", "LICENSE",
}

BACKUP_NAME_RE = re.compile(r"(\.bak($|[-._].*)|\.orig$|\.old$|~$|\.swp$|\.rej$)")
BACKUP_DIR_RE = re.compile(r"^(retired-|backup|bak)", re.IGNORECASE)
SENSITIVE_EXT_RE = re.compile(r"\.(key|pem|crt|cer|p12|pfx|jks|keystore|truststore)$", re.IGNORECASE)
SECRET_BEARING_PATHS = {"config/config.js", ".env"}


# ── small helpers ───────────────────────────────────────────────────────────

class Report:
    def __init__(self):
        self.failed = False
        self.warned = False

    def ok(self, msg):
        print(f"  OK   {msg}")

    def warn(self, msg):
        self.warned = True
        print(f"  WARN {msg}")

    def fail(self, msg):
        self.failed = True
        print(f"  FAIL {msg}")

    def info(self, msg):
        print(f"       {msg}")


def die(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def file_mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def is_within(child, parent):
    child = os.path.realpath(child)
    parent = os.path.realpath(parent)
    return child == parent or child.startswith(parent.rstrip(os.sep) + os.sep)


def run(cmd, cwd=None, env=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        return 127, "", f"{cmd[0]}: not found"
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


def dir_permissions(target, *call):
    """Run a lib/dir-permissions.sh function against checkout `target`, so
    apply and verify use the very code bootstrap.sh, configure-host.sh and
    validate-config.sh use for config/config.js (one model, one set of
    advice). Returns (exit code, output lines without \\r)."""
    script = 'repo_root="$1"; shift; . "${repo_root}/installation-scripts/lib/dir-permissions.sh"; "$@"'
    try:
        p = subprocess.run(["bash", "-c", script, "dir-permissions", target] + list(call),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except FileNotFoundError:
        return 127, ["bash: not found"]
    return p.returncode, [l for l in p.stdout.decode("utf-8", "replace").replace("\r", "").splitlines() if l.strip()]


def is_text(path, limit=8192):
    with open(path, "rb") as fh:
        chunk = fh.read(limit)
    return b"\0" not in chunk


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(repo, *args):
    return run(["git", "-C", repo] + list(args))


def git_head(repo):
    rc, out, _ = git(repo, "rev-parse", "HEAD")
    return out.strip() if rc == 0 else None


def committed_sha256(repo, rel):
    """sha256 of HEAD:<rel> as a checkout would write it (eol/filters applied,
    matching what `git archive` produced at capture time), or None."""
    p = subprocess.run(["git", "-C", repo, "cat-file", "--filters", f"HEAD:{rel}"],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return hashlib.sha256(p.stdout).hexdigest() if p.returncode == 0 else None


def git_tracked_dirty(repo):
    rc, out, _ = git(repo, "status", "--porcelain", "--untracked-files=no")
    return None if rc != 0 else [l[3:] for l in out.splitlines() if l.strip()]


def walk_files(root):
    """Yield repo-relative paths of regular files under root, skipping
    operational state (see EXCLUDED_DIRS). Symlinks are reported, not followed."""
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir.replace(os.sep, "/")
        # Only prune excluded names at the top level for storage-like dirs,
        # but .git / node_modules / __pycache__ anywhere.
        keep = []
        for d in dirnames:
            top = rel_dir == ""
            if d in (".git", "node_modules", "__pycache__"):
                continue
            if top and d in EXCLUDED_DIRS:
                continue
            keep.append(d)
        dirnames[:] = sorted(keep)
        for f in sorted(filenames):
            rel = f"{rel_dir}/{f}" if rel_dir else f
            if rel in EXCLUDED_FILES:
                continue
            yield rel


def extract_git_ref(repo, ref, dest):
    """`git archive <ref>` into dest (no working-tree state, no .git)."""
    rc, out, err = git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    if rc != 0:
        return None
    commit = out.strip()
    p = subprocess.run(["git", "-C", repo, "archive", "--format=tar", commit], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        die(f"git archive {ref} failed: {p.stderr.decode('utf-8', 'replace').strip()}")
    tar_path = os.path.join(dest, "..", "baseline.tar")
    with open(tar_path, "wb") as fh:
        fh.write(p.stdout)
    with tarfile.open(tar_path) as tf:
        if hasattr(tarfile, "data_filter"):
            tf.extractall(dest, filter="data")
        else:
            tf.extractall(dest)
    os.remove(tar_path)
    return commit


# ── Docker compose normalisation ────────────────────────────────────────────

def compose_config(project_dir, project_name=None, extra_env=None, use_dotenv=True):
    """Effective, fully-merged compose model for project_dir as JSON, or None.

    Run from inside project_dir so its .env (COMPOSE_FILE, COMPOSE_PROFILES,
    COMPOSE_PROJECT_NAME) is honoured exactly as `docker compose up` would."""
    env = dict(os.environ)
    for k in ("COMPOSE_FILE", "COMPOSE_PROJECT_NAME", "COMPOSE_PROFILES"):
        env.pop(k, None)  # never let the CALLER's shell leak into either side
    if extra_env:
        env.update(extra_env)
    cmd = ["docker", "compose"]
    if not use_dotenv:
        cmd += ["--env-file", os.devnull, "-f", os.path.join(project_dir, "docker-compose.yml")]
    if project_name:
        cmd += ["-p", project_name]
    cmd += ["config", "--format", "json"]
    rc, out, err = run(cmd, cwd=project_dir, env=env)
    if rc != 0:
        return None, err.strip()
    return json.loads(out), None


def active_profiles(project_dir):
    """COMPOSE_PROFILES from project_dir/.env (what `docker compose up` uses)."""
    path = os.path.join(project_dir, ".env")
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("COMPOSE_PROFILES="):
                return [p for p in line.split("=", 1)[1].strip().strip("\"'").split(",") if p]
    return []


def existing_compose_overlay(project_dir):
    """The compose overlay file already in effect for project_dir (listed in
    its .env COMPOSE_FILE after docker-compose.yml), if any."""
    path = os.path.join(project_dir, ".env")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("COMPOSE_FILE="):
                for f in line.split("=", 1)[1].strip().strip("\"'").split(os.pathsep):
                    f = f if os.path.isabs(f) else os.path.join(project_dir, f)
                    if os.path.basename(f) != "docker-compose.yml" and os.path.isfile(f):
                        return f
    return None


def _replace_prefix(obj, prefixes, marker="<DEPLOY_DIR>"):
    if isinstance(obj, dict):
        return {k: _replace_prefix(v, prefixes, marker) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_replace_prefix(v, prefixes, marker) for v in obj]
    if isinstance(obj, str):
        for p in prefixes:
            if p and (obj == p or obj.startswith(p.rstrip("/") + "/")):
                return marker + obj[len(p.rstrip("/")):]
        return obj
    return obj


def normalise_services(model, dir_prefixes):
    """Per-service dicts with deployment-dir prefixes replaced by a marker, so
    two checkouts at different paths compare equal where they should."""
    services = (model or {}).get("services") or {}
    out = {}
    for name, svc in services.items():
        svc = _replace_prefix(svc, dir_prefixes)
        # Volumes keyed by container target: that is also how compose merges
        # override files, so a difference here maps 1:1 to an overlay entry.
        vols = {}
        for v in svc.get("volumes") or []:
            vols[v.get("target")] = {k: v.get(k) for k in ("type", "source", "read_only") if v.get(k) is not None}
        svc["volumes"] = vols
        env = svc.get("environment") or {}
        if isinstance(env, list):
            env = dict(e.split("=", 1) if "=" in e else (e, None) for e in env)
        svc["environment"] = env
        out[name] = svc
    return out


# Read by Keycloak only on its FIRST boot against an EMPTY data volume (see
# documentation/14-07). On a host with an existing realm they change nothing,
# so a difference is reported as information, never as behaviour drift. The
# admin credential itself lives in the Keycloak volume + the secret manager.
FIRST_BOOT_ONLY_ENV = {"KEYCLOAK_ADMIN", "KEYCLOAK_ADMIN_PASSWORD",
                       "KC_BOOTSTRAP_ADMIN_USERNAME", "KC_BOOTSTRAP_ADMIN_PASSWORD"}
# The .env key the release's docker-compose.yml reads KEYCLOAK_ADMIN_PASSWORD
# from (bootstrap.sh writes it; lib/secret_hygiene.py). Same first-boot-only
# value, so capture does not carry it either.
FIRST_BOOT_ONLY_DOTENV = {"KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD"}

COMPARED_KEYS = (
    "image", "command", "entrypoint", "environment", "volumes", "ports", "extra_hosts",
    "networks", "profiles", "restart", "user", "working_dir", "env_file", "healthcheck",
    "depends_on", "container_name", "labels", "cap_add", "privileged", "network_mode",
)


def _fmt_value(key, value):
    """One-line, redacted rendering of a compose value for reports."""
    m_env = re.match(r"^environment\[(.*)\]$", key or "")
    if m_env and is_secret_key(m_env.group(1)) and value not in (None, "<absent>"):
        return json.dumps(REDACTED)
    if key == "environment" and isinstance(value, dict):
        value = {k: (REDACTED if is_secret_key(k) else v) for k, v in value.items()}
    text = json.dumps(value, sort_keys=True)
    return redact_line(text) if len(text) < 400 else redact_line(text[:400]) + " ...(truncated)"


def compose_differences(a, b, a_label="reference", b_label="candidate"):
    """Differences from service model `a` to `b`.

    Returns a list of (service, key, detail, a_value, b_value)."""
    diffs = []
    for name in sorted(set(a) | set(b)):
        if name not in b:
            diffs.append((name, "*", f"service present only in the {a_label}", None, None))
            continue
        if name not in a:
            diffs.append((name, "*", f"service present only in the {b_label}", None, b[name]))
            continue
        sa, sb = a[name], b[name]
        for key in COMPARED_KEYS:
            va, vb = sa.get(key), sb.get(key)
            if key in ("environment", "volumes"):
                va, vb = va or {}, vb or {}
                for sub in sorted(set(va) | set(vb), key=str):
                    if va.get(sub) != vb.get(sub):
                        diffs.append((name, f"{key}[{sub}]", "", va.get(sub, "<absent>"), vb.get(sub, "<absent>")))
                continue
            if va != vb:
                diffs.append((name, key, "", va, vb))
    return diffs


def running_project(live_dir):
    """(project_name, container_names) of the compose project whose keycloak
    container was started from live_dir, if Docker can tell us."""
    rc, out, _ = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.service=keycloak",
                      "--format", '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}'])
    if rc != 0:
        return None
    live_real = os.path.realpath(live_dir)
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[1] and os.path.realpath(parts[1]) == live_real:
            return parts[0]
    return None


def volume_exists(name):
    rc, _, _ = run(["docker", "volume", "inspect", name])
    return rc == 0


def named_volume_names(model):
    """Real Docker volume names (project-prefixed) the model uses."""
    names = {}
    for key, vol in ((model or {}).get("volumes") or {}).items():
        names[key] = (vol or {}).get("name") or f"{model.get('name')}_{key}"
    return names


# ── host boot and cron hooks ────────────────────────────────────────────────
#
# systemd units, cron entries, rc.local and init scripts live on the HOST,
# outside every checkout, so capture does not carry them and apply does not
# install them. One that still starts the stack from the old directory runs
# at the next boot. On the demo host, an enabled padsign.service
# (WorkingDirectory=<old>, `docker compose -f <old>/docker-compose.yml down`,
# then `up -d`) tore down the new checkout's containers at the first reboot
# after the cut-over (same compose project name) and started the OLD stack,
# whose Keycloak then ran on a database the newer Keycloak had already
# migrated. capture and verify list every hook that names the old directory
# or runs docker compose, so the cut-over (42.4 C4) repoints or disables it.
# Read-only. A location that is missing is skipped; one that is not readable
# is named in the report.

HOST_SCAN_ROOT_ENV = "PADSIGN_HOST_SCAN_ROOT"  # tests: scan <root>/etc/... instead of /etc/...
SYSTEMD_UNIT_DIRS = ("/etc/systemd/system", "/run/systemd/system", "/usr/local/lib/systemd/system",
                     "/usr/lib/systemd/system", "/lib/systemd/system")
SYSTEMD_UNIT_SUFFIXES = (".service", ".timer", ".path", ".socket", ".target", ".mount")
SYSTEMD_ENABLE_DIR_SUFFIXES = (".wants", ".requires", ".upholds")
CRON_FILES = ("/etc/crontab", "/etc/anacrontab")
CRON_DIRS = ("/etc/cron.d", "/etc/cron.hourly", "/etc/cron.daily", "/etc/cron.weekly", "/etc/cron.monthly")
RC_FILES = ("/etc/rc.local", "/etc/rc.d/rc.local")
INIT_DIRS = ("/etc/init.d",)
CRONTAB_SPOOLS = ("/var/spool/cron/crontabs", "/var/spool/cron")  # Debian/Ubuntu, RHEL
HOOK_MAX_BYTES = 1 << 20
HOOK_SCANNED = ("systemd unit directories, /etc/crontab, /etc/anacrontab, /etc/cron.d, "
                "/etc/cron.{hourly,daily,weekly,monthly}, user crontabs, /etc/rc.local, /etc/init.d")

# `docker compose` or the old `docker-compose` binary, not a docker-compose.yml path.
COMPOSE_CMD_RE = re.compile(r"\bdocker\s+compose\b|\bdocker-compose\b(?![.\w-])")
# Absolute paths in a command line (a drive prefix only so the tests run under Git Bash).
PATH_TOKEN_RE = re.compile(r"(?<![\w.$/:\\])((?:[A-Za-z]:)?/[^\s\"'`;|&<>(){}=,:]*)")
_COMPOSE_VALUE_FLAGS = {"-f", "--file", "-p", "--project-name", "--project-directory", "--env-file",
                        "--profile", "--ansi", "--parallel", "--progress"}
_CMD_SEPARATORS = {"&&", "||", ";", "|", "&"}


def _norm(p):
    return os.path.normcase(os.path.normpath(p))


_realpath_cache = {}


def _real(p):
    """os.path.realpath, cached: the scan resolves every path token of every
    unit file on the host against several directories."""
    if p not in _realpath_cache:
        try:
            _realpath_cache[p] = _norm(os.path.realpath(p))
        except (OSError, ValueError):
            _realpath_cache[p] = _norm(p)
    return _realpath_cache[p]


def _under(t, d):
    return t == d or t.startswith(d.rstrip(os.sep) + os.sep)


def _dir_ref(token, d):
    """'path' if token names d or something under it, 'symlink' if it only
    resolves there (e.g. /opt/trustlynx/padsign-current -> d), else None."""
    t = _norm(token)
    if _under(t, _norm(d)) or _under(t, _real(d)):
        return "path"
    if _under(_real(token), _real(d)):
        return "symlink"
    return None


def _compose_calls(line):
    """(global options, subcommand, subcommand args) for each docker compose
    call in a command line. Approximate (no shell parsing), which is enough
    to spot `-f` before the subcommand and `down -v` after it."""
    calls = []
    for m in COMPOSE_CMD_RE.finditer(line):
        opts, sub, args, value_next = [], None, [], False
        for raw in line[m.end():].split():
            t = raw.strip("\"'")
            if t in _CMD_SEPARATORS:
                break
            last = t.endswith(";")  # `up -d;` ends this command
            t = t.rstrip(";")
            if value_next:
                opts.append(t)
                value_next = False
            elif sub is None and t.startswith("-"):
                opts.append(t)
                value_next = t in _COMPOSE_VALUE_FLAGS
            elif sub is None:
                sub = t or None
            elif t:
                args.append(t)
            if last:
                break
        calls.append((opts, sub, args))
    return calls


_HOOK_ASSIGN_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|[^\s\"']+)")
_HOOK_SECRET_FLAG_RE = re.compile(r"(--?[A-Za-z0-9_-]*(?:pass|secret|token|key|credential|auth)[A-Za-z0-9_-]*)(=|\s+)(\S+)",
                                  re.IGNORECASE)


def _redact_hook_line(line, limit=200):
    """A hook line as reports show it. Unlike a config line, a command line
    carries its secrets anywhere, not only at the start: an inline
    `KEY=value` with a secret-looking KEY (lib/redact.py) or a WEBHOOK/URL
    one, the value of a --*pass*/--*secret*/--*token* flag, and every URL
    after its host (a webhook URL's path is the secret) become <redacted>."""
    def assign(mm):
        key, val = mm.group(1), mm.group(2)
        if is_secret_key(key) or re.search(r"WEBHOOK|URL", key, re.IGNORECASE):
            return f"{key}={REDACTED}"
        if val[:1] in ("\"", "'"):  # systemd Environment="KEY=value": look inside
            return f"{key}={val[0]}{_HOOK_ASSIGN_RE.sub(assign, val[1:-1])}{val[-1]}"
        return mm.group(0)

    s = redact_line(line.strip())
    s = _HOOK_ASSIGN_RE.sub(assign, s)
    s = _HOOK_SECRET_FLAG_RE.sub(lambda mm: f"{mm.group(1)}{mm.group(2)}{REDACTED}", s)
    s = re.sub(r"\b(https?://[^/\s\"'<>]+)/[^\s\"'<>]*", lambda mm: f"{mm.group(1)}/{REDACTED}", s,
               flags=re.IGNORECASE)
    return s if len(s) <= limit else s[:limit] + " ...(truncated)"


def _read_hook_text(path):
    try:
        if os.path.getsize(path) > HOOK_MAX_BYTES:
            return None
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    if b"\0" in data[:8192]:
        return None
    return data.decode("utf-8", "replace")


def _current_user():
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_name
    except (ImportError, KeyError, AttributeError):
        import getpass
        return getpass.getuser()


def host_hook_files():
    """(files, enablement, not_scanned): every candidate hook file with its
    text, the systemd *.wants/ (etc.) directories each unit name appears in,
    and the locations that exist but could not be read."""
    root = os.environ.get(HOST_SCAN_ROOT_ENV, "")

    def host(p):
        return os.path.join(root, p.lstrip("/")) if root else p

    files, not_scanned, seen, enabled_by = [], [], set(), {}

    def add(shown, real, kind, unit=None, text=None):
        key = os.path.realpath(real) if real else shown
        if key in seen:
            return
        seen.add(key)
        if text is None:
            if not os.access(real, os.R_OK):
                not_scanned.append(f"{shown} (not readable as {_current_user()})")
                return
            text = _read_hook_text(real)
            if text is None:
                return  # binary or larger than HOOK_MAX_BYTES: not a hook script
        files.append({"path": shown, "kind": kind, "unit": unit, "text": text})

    for d in SYSTEMD_UNIT_DIRS:
        base = host(d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            parent = os.path.basename(dirpath)
            for f in sorted(filenames):
                fp = os.path.join(dirpath, f)
                shown = d + "/" + os.path.relpath(fp, base).replace(os.sep, "/")
                if parent.endswith(SYSTEMD_ENABLE_DIR_SUFFIXES):
                    enabled_by.setdefault(f, set()).add(parent)
                elif parent.endswith(".d") and f.endswith(".conf") and os.path.isfile(fp):
                    add(shown, fp, "systemd drop-in", parent[:-2])
                elif f.endswith(SYSTEMD_UNIT_SUFFIXES) and os.path.isfile(fp):  # masked (-> /dev/null): skipped
                    add(shown, fp, "systemd unit", f)
    for f in CRON_FILES + RC_FILES:
        fp = host(f)
        if os.path.isfile(fp):
            add(f, fp, "rc.local" if f.endswith("rc.local") else "system crontab")
    for d in CRON_DIRS + INIT_DIRS:
        base = host(d)
        if not os.path.isdir(base):
            continue
        try:
            names = sorted(os.listdir(base))
        except OSError:
            not_scanned.append(f"{d}/ (not readable as {_current_user()})")
            continue
        kind = "init script" if d in INIT_DIRS else ("cron.d entry" if d.endswith("cron.d") else f"{os.path.basename(d)} script")
        for n in names:
            fp = os.path.join(base, n)
            if os.path.isfile(fp):
                add(f"{d}/{n}", fp, kind)
    user_crontabs_read = False
    for d in CRONTAB_SPOOLS:
        base = host(d)
        if not os.path.isdir(base):
            continue
        try:
            names = sorted(os.listdir(base))
        except OSError:
            not_scanned.append(f"{d}/ (not readable as {_current_user()}: every user's crontab, "
                               f"root's and the deploy user's included - run as root, or `sudo crontab -l -u <user>`)")
            continue
        for n in names:
            fp = os.path.join(base, n)
            if os.path.isfile(fp):
                user_crontabs_read = True
                add(f"{d}/{n}", fp, f"crontab of {n}")
        if d == CRONTAB_SPOOLS[0]:
            user_crontabs_read = True
    if not user_crontabs_read and not root:
        # The spool is root-only; this user's own crontab is still readable.
        rc, out, _ = run(["crontab", "-l"])
        if rc == 0 and out.strip():
            add(f"crontab of {_current_user()} (crontab -l)", None, f"crontab of {_current_user()}", text=out)
    return files, enabled_by, not_scanned


def host_hooks(old_dirs, checkout=None, storage=()):
    """Hooks that reference one of old_dirs or the checkout, or run docker
    compose. A path inside `storage` (the signed documents, which stay where
    they are, often under the old directory) is not a reference to the old
    checkout: a backup job for them is fine. Returns (hooks, not_scanned);
    hooks carry redacted lines only."""
    files, enabled_by, not_scanned = host_hook_files()
    storage = [s for s in storage if s]
    hooks = []
    for f in files:
        lines, old_refs, via, checkout_ref, subs = [], [], [], False, []
        file_flag = down_volumes = runs_compose = False
        for n, raw in enumerate(f["text"].splitlines(), 1):
            s = raw.strip()
            if not s or s.startswith(("#", ";")):
                continue
            hit = False
            for t in PATH_TOKEN_RE.findall(s):
                if any(_dir_ref(t, sd) for sd in storage):
                    continue
                how = _dir_ref(t, checkout) if checkout else None
                if how:
                    checkout_ref = hit = True
                    continue
                for d in old_dirs:
                    how = _dir_ref(t, d)
                    if how:
                        hit = True
                        if d not in old_refs:
                            old_refs.append(d)
                        if how == "symlink" and t not in via:
                            via.append(t)
                        break
            for opts, sub, args in (_compose_calls(s) if COMPOSE_CMD_RE.search(s) else []):
                runs_compose = hit = True
                if sub and sub not in subs:
                    subs.append(sub)
                if any(o in ("-f", "--file") or o.startswith("--file=") or (o.startswith("-f") and not o.startswith("--"))
                       for o in opts):
                    file_flag = True
                if sub == "down" and any(a in ("-v", "--volumes") or a.startswith("--volumes") for a in args):
                    down_volumes = True
            if hit:
                lines.append({"line": n, "text": _redact_hook_line(s)})
        if not lines:
            continue
        enabled = None
        if f["kind"].startswith("systemd"):
            unit = f["unit"] or ""
            dirs = sorted(enabled_by.get(unit, ()))
            timer = unit[:-len(".service")] + ".timer" if unit.endswith(".service") else None
            tdirs = sorted(enabled_by.get(timer, ())) if timer else []
            if dirs:
                enabled = f"enabled ({', '.join(dirs)})"
            elif tdirs:
                enabled = f"enabled via {timer} ({', '.join(tdirs)})"
            else:
                enabled = "not enabled"
            if f["kind"] == "systemd drop-in":
                enabled = f"drop-in for {unit}, {enabled}"
        hooks.append({"path": f["path"], "kind": f["kind"], "enabled": enabled,
                      "references_old": old_refs, "via_symlink": via, "references_checkout": checkout_ref,
                      "runs_compose": runs_compose, "compose_commands": subs,
                      "compose_file_flag": file_flag, "down_volumes": down_volumes, "lines": lines})
    return hooks, not_scanned


def report_host_hooks(r, hooks, not_scanned, old_dirs, checkout=None):
    """WARN for every hook that would start or stop the stack from the wrong
    place; OK for one that runs compose for `checkout`. Used by capture
    (checkout=None) and verify."""
    olds = ", ".join(old_dirs) or "the old checkout"
    if not hooks:
        r.ok(f"no systemd unit, cron entry, rc.local or init script names {olds} or runs docker compose")
    for h in hooks:
        where = f"{h['path']} ({h['kind']}" + (f", {h['enabled']}" if h.get("enabled") else "") + ")"
        if h["references_old"]:
            via = f" (via {', '.join(h['via_symlink'])})" if h["via_symlink"] else ""
            r.warn(f"{where}: references the old checkout {', '.join(h['references_old'])}{via}. After the cut-over, "
                   "a job that starts the stack from there brings the OLD stack back (same compose project, same "
                   "Keycloak volume), and one that runs its scripts stops working at 42.4 C7 - repoint it at the "
                   "new checkout or disable it in the cut-over window (42.4 C4)")
        elif h["runs_compose"] and h["references_checkout"]:
            r.ok(f"{where}: runs docker compose for this checkout")
        elif h["runs_compose"]:
            names = f"does not name {olds}" + (" or this checkout" if checkout else "")
            r.warn(f"{where}: runs docker compose, but {names} - confirm it does not start or stop this stack "
                   "(a compose project with the same name), or disable it")
        else:
            r.ok(f"{where}: references this checkout")
        if h["compose_file_flag"]:
            r.warn(f"{h['path']}: passes -f/--file to docker compose. On an overlay-managed checkout that ignores "
                   "COMPOSE_FILE in .env, so compose.overlay.yml (storage mounts, image overrides) is left out - "
                   "use the boot unit in documentation/42-06 instead")
        if h["down_volumes"]:
            r.warn(f"{h['path']}: runs `docker compose down` with -v/--volumes, which deletes named volumes, "
                   "the Keycloak data volume included")
        for l in h["lines"][:8]:
            r.info(f"line {l['line']}: {l['text']}")
        if len(h["lines"]) > 8:
            r.info(f"... {len(h['lines']) - 8} more matching line(s)")
    for s in not_scanned:
        r.info(f"not scanned: {s}")
    r.info(f"scanned: {HOOK_SCANNED}. These are host files, outside the checkout and the overlay: "
           "on a rebuilt host, re-create the ones you keep (documentation/42-06).")


# ── capture ─────────────────────────────────────────────────────────────────

def is_release_content(rel):
    if rel in RELEASE_CONTENT_FILES:
        return True
    if rel.startswith("installation-scripts/certs/"):
        return False  # cert staging area: host state, handled separately
    return rel.startswith(RELEASE_CONTENT_PREFIXES)


def classify_path(rel):
    base = rel.rsplit("/", 1)[-1]
    parts = rel.split("/")
    if any(BACKUP_DIR_RE.match(p) for p in parts[:-1]) or BACKUP_NAME_RE.search(base):
        return "operational-backup"
    if rel.startswith("nginx/certs/"):
        return "tls-cert" if base != ".gitkeep" else "ignore"
    if rel.startswith("installation-scripts/certs/"):
        return "cert-staging-leftover" if base != ".gitkeep" else "ignore"
    if rel == "docker-compose.yml":
        return "compose"
    if rel == ".env":
        return "dotenv"
    if SENSITIVE_EXT_RE.search(base):
        return "sensitive-file"
    return "file"


def keep_base(overlay, rel, src):
    dst = os.path.join(overlay, "base", rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def merge3(release_path, host_base_path, host_path, out_path):
    """Replay the host's own edits (host_base -> host) onto the new release
    file with `git merge-file`. Returns the number of conflicts (0 = clean),
    or None if the files cannot be merged as text."""
    if not (is_text(release_path) and is_text(host_base_path) and is_text(host_path)):
        return None
    p = subprocess.run(["git", "merge-file", "-p", "-L", "new release", "-L", "host's original release",
                        "-L", "host", release_path, host_base_path, host_path],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode < 0 or p.returncode > 127:
        return None
    with open(out_path, "wb") as fh:
        fh.write(p.stdout)
    return p.returncode


def resolve_tree(ref_or_dir, repos, dest):
    """Materialise a release tree from a git ref (searched in `repos`) or a
    clean directory into dest. Returns (commit_or_None, description)."""
    for repo in repos:
        if repo and (os.path.isdir(os.path.join(repo, ".git")) or os.path.isfile(os.path.join(repo, ".git"))):
            commit = extract_git_ref(repo, ref_or_dir, dest)
            if commit:
                return commit, f"git archive in {repo}"
    if not os.path.isdir(ref_or_dir):
        return None, None
    src = os.path.realpath(ref_or_dir)
    for rel in walk_files(src):
        sp = os.path.join(src, rel)
        if os.path.islink(sp) or not os.path.isfile(sp):
            continue
        dp = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        shutil.copy2(sp, dp)
    return git_head(src), f"directory {src}"


def cmd_capture(args):
    live = os.path.realpath(args.source or args.repo_root)
    out = os.path.abspath(args.out)
    if not os.path.isdir(live):
        die(f"--from {live} is not a directory")
    if is_within(out, live):
        die(f"--out {out} is inside the deployment directory {live}. The overlay holds secrets and "
            "certificates; it must live OUTSIDE any checkout (e.g. /etc/padsign/overlay).")
    if os.path.exists(out) and os.listdir(out):
        die(f"--out {out} already exists and is not empty; capture never overwrites an overlay")

    work = tempfile.mkdtemp(prefix="padsign-overlay-")
    try:
        base_dir = os.path.join(work, "baseline")
        os.makedirs(base_dir)
        if os.path.isdir(args.baseline):
            bdir = os.path.realpath(args.baseline)
            if is_within(bdir, live) or is_within(live, bdir):
                die("--baseline and --from must be separate directories")
            dirty = git_tracked_dirty(bdir)
            if dirty:
                die(f"--baseline directory {bdir} has modified tracked files ({', '.join(dirty[:5])}); "
                    "a baseline must be a clean checkout of the release")
            commit, how = resolve_tree(args.baseline, [], base_dir)
        else:
            commit, how = resolve_tree(args.baseline, [live, args.repo_root], base_dir)
        if how is None:
            die(f"--baseline {args.baseline} is neither a git ref (in {live} or {args.repo_root}) nor a directory")
        baseline = {"ref": args.baseline, "commit": commit, "source": how}

        # The release the HOST was originally deployed from. With it, capture
        # can tell the host's own edits apart from "this file is simply the
        # old release's version" and replay only the edits onto the new
        # release (3-way merge). Without it, every differing file is carried
        # whole and each '-' line in DEVIATIONS.md needs a human decision.
        hb_dir = os.path.join(work, "host-base")
        os.makedirs(hb_dir)
        host_base = {"ref": None, "commit": None, "source": None}
        hb_ref = args.host_base or (git_head(live) if git_head(live) else None)
        if hb_ref:
            hb_commit, hb_how = resolve_tree(hb_ref, [live, args.repo_root], hb_dir)
            if hb_how is None:
                die(f"--host-base {hb_ref} is neither a git ref nor a directory")
            host_base = {"ref": hb_ref, "commit": hb_commit, "source": hb_how}
        else:
            hb_dir = None

        old_umask = os.umask(0o077)
        os.makedirs(os.path.join(out, "files"))
        os.makedirs(os.path.join(out, "certs"))
        os.makedirs(os.path.join(out, "reference"))
        os.makedirs(os.path.join(out, "base"))
        os.chmod(out, 0o700)

        manifest = {
            "schema_version": SCHEMA_VERSION,
            "captured_at": utcnow(),
            "source_dir": live,
            "baseline": baseline,
            "host_base": host_base,
            "project_name": None,
            "files": [],
            "certs": [],
            "env_keys": [],
            "not_captured": [],
        }
        print(f"Capturing environment overlay")
        print(f"  from:     {live}")
        print(f"  baseline: {args.baseline} ({baseline['source']}, commit {baseline['commit'] or 'unknown'})")
        if hb_dir:
            print(f"  host was deployed from: {host_base['ref']} ({host_base['source']}) - host edits are 3-way merged onto the baseline")
        else:
            print("  host was deployed from: UNKNOWN (not a git checkout, no --host-base) - differing files are carried whole")
        print(f"  into:     {out}")
        print()

        r = Report()
        deviations = []  # (path, classification, redacted diff lines)
        stale_release_files = 0
        whole_file_overrides = 0
        for rel in walk_files(live):
            src = os.path.join(live, rel)
            if os.path.islink(src):
                manifest["not_captured"].append({"path": rel, "reason": "symlink (not followed)"})
                continue
            if not os.path.isfile(src):
                continue
            base_path = os.path.join(base_dir, rel)
            in_base = os.path.isfile(base_path)
            if in_base and sha256_file(base_path) == sha256_file(src):
                continue  # identical to the release: nothing to carry
            cls = classify_path(rel)
            if cls == "ignore":
                continue
            size = os.path.getsize(src)
            mode = file_mode(src)
            hb_path = os.path.join(hb_dir, rel) if hb_dir else None
            in_hb = bool(hb_path) and os.path.isfile(hb_path)
            unchanged_since_host_release = in_hb and sha256_file(hb_path) == sha256_file(src)

            if is_release_content(rel) and cls not in ("operational-backup",):
                if unchanged_since_host_release:
                    stale_release_files += 1
                else:
                    manifest["not_captured"].append({"path": rel, "reason": "release content differs from the baseline and was not captured "
                                                     "(hand-patched script/doc on the host, or unknown host release) - upstream it or drop it"})
                continue

            if cls == "operational-backup":
                manifest["not_captured"].append({"path": rel, "reason": "operational backup - move out of the tree", "bytes": size, "mode": oct(mode)})
                continue
            if cls == "cert-staging-leftover":
                manifest["not_captured"].append({"path": rel, "reason": "certificate staging copy - nginx/certs/ is captured instead; remove from tree after verifying", "mode": oct(mode)})
                continue
            if cls == "tls-cert":
                dst = os.path.join(out, "certs", rel.split("/", 2)[2])
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(src, dst)
                os.chmod(dst, 0o600)
                manifest["certs"].append({"path": rel, "sha256": sha256_file(dst), "mode": oct(mode)})
                continue
            if cls == "compose":
                shutil.copyfile(src, os.path.join(out, "reference", "docker-compose.live.yml"))
                manifest["not_captured"].append({"path": rel, "reason": "compose is never applied wholesale - port differences into compose.overlay.yml (see COMPOSE-DIFFERENCES below)"})
                if in_base:
                    deviations.append((rel, "compose (reference only)", unified(base_path, src, rel)))
                continue
            if cls == "dotenv":
                keys, lines = [], []
                with open(src, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        s = line.strip()
                        if not s or s.startswith("#") or "=" not in s:
                            continue
                        k = s.split("=", 1)[0].replace("export ", "").strip()
                        if k in ("COMPOSE_FILE", "COMPOSE_PROJECT_NAME"):
                            continue  # regenerated by apply
                        if k in FIRST_BOOT_ONLY_DOTENV:
                            manifest["not_captured"].append({
                                "path": f".env {k}",
                                "reason": "first-boot-only Keycloak admin password - the credential lives in the "
                                          "Keycloak volume and your secret manager (documentation/17-01)"})
                            continue
                        keys.append(k)
                        lines.append(s)
                with open(os.path.join(out, "env"), "w", encoding="utf-8") as fh:
                    fh.write("\n".join(lines) + ("\n" if lines else ""))
                manifest["env_keys"] = keys
                continue

            if unchanged_since_host_release:
                # The host never edited this file: it is just the OLD release's
                # version. The new release's version applies - not a deviation.
                stale_release_files += 1
                continue
            if not in_base and in_hb and not unchanged_since_host_release:
                r.warn(f"{rel}: the new release no longer ships this file but the host edited it - carried as an extra file, review")

            dst = os.path.join(out, "files", rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            merge = "whole-file"
            conflicts = 0
            if in_base and in_hb:
                n = merge3(base_path, hb_path, src, dst)
                if n is None:
                    shutil.copyfile(src, dst)
                    merge = "whole-file (binary)"
                else:
                    merge = "3-way"
                    conflicts = n
                    if n:
                        r.fail(f"{rel}: {n} merge conflict(s) replaying the host's edits onto the new release - "
                               f"resolve the <<<<<<< markers in files/{rel}, then `overlay.sh rehash`")
            else:
                shutil.copyfile(src, dst)
                if in_base and not hb_dir:
                    whole_file_overrides += 1
            entry = {
                "path": rel,
                "sha256": sha256_file(dst),
                "mode": oct(mode),
                "class": "override" if in_base else "extra",
                "sensitive": cls == "sensitive-file" or rel in SECRET_BEARING_PATHS or rel.rsplit("/", 1)[-1].startswith(".env"),
                "baseline_sha256": sha256_file(base_path) if in_base else None,
                "merge": merge,
                "conflicts": conflicts,
            }
            manifest["files"].append(entry)
            if in_base:
                keep_base(out, rel, base_path)
            if in_base and is_text(dst) and is_text(base_path):
                label = {"3-way": "host edits replayed onto the release (3-way merge)"}.get(merge, "whole-file override")
                if conflicts:
                    label += f" - {conflicts} CONFLICT(S) TO RESOLVE"
                deviations.append((rel, label, unified(base_path, dst, rel)))
            elif not in_base:
                deviations.append((rel, "extra file (not in baseline)", [f"  ({size} bytes, mode {oct(mode)})"]))
            else:
                deviations.append((rel, "binary override", [f"  sha256 baseline={entry['baseline_sha256'][:12]}... live={entry['sha256'][:12]}..."]))

        # Tracked-by-baseline files that are MISSING on the host.
        live_files = set(walk_files(live))
        for rel in walk_files(base_dir):
            if rel not in live_files and classify_path(rel) not in ("ignore",):
                deviations.append((rel, "present in baseline, missing on host", ["  (apply will leave the baseline version in place)"]))

        # Compose: effective model of the host vs the baseline.
        compose_notes = []
        live_model, err = compose_config(live)
        # Render the baseline with the SAME active profiles as the host, so a
        # profile-gated service (local-eseal) the host enables through .env is
        # compared field by field instead of reported as an extra service.
        profiles = active_profiles(live)
        base_model, berr = compose_config(base_dir, project_name=(live_model or {}).get("name"), use_dotenv=False,
                                          extra_env={"COMPOSE_PROFILES": ",".join(profiles)} if profiles else None)
        project = running_project(live) or (live_model or {}).get("name")
        manifest["project_name"] = project
        if live_model is None:
            r.warn(f"could not render the host's compose model ({err or 'docker unavailable'}); "
                   "COMPOSE-DIFFERENCES and storage/volume facts are missing - rerun capture where `docker compose` works")
        else:
            if (live_model.get("name") != project):
                r.warn(f"running containers belong to compose project '{project}' but the compose files resolve to "
                       f"'{live_model.get('name')}' - the overlay pins '{project}' (the one holding the live Keycloak volume)")
            vols = named_volume_names(dict(live_model, name=project))
            manifest["named_volumes"] = vols
            storage = {}
            for svc_name, svc in (live_model.get("services") or {}).items():
                for v in svc.get("volumes") or []:
                    if v.get("target") in STORAGE_TARGETS and STORAGE_TARGETS[v["target"]][0] == svc_name:
                        storage[v["target"]] = {"service": svc_name, "type": v.get("type"), "source": v.get("source")}
            manifest["storage"] = storage
            carried = existing_compose_overlay(live)
            if carried:
                # Re-capturing an overlay-managed checkout (e.g. after
                # renew-cert.sh): keep the operator's reviewed compose overlay
                # instead of regenerating the storage-only starter.
                shutil.copyfile(carried, os.path.join(out, "compose.overlay.yml"))
                print(f"  compose.overlay.yml carried over from {carried} (already in effect on the source)")
                # Its image approvals travel with it: without them the
                # digest gate (lib/digest_gate.py) fails every image the
                # overlay adds or replaces.
                approvals = os.path.join(os.path.dirname(carried), "approved-digests.json")
                if os.path.isfile(approvals):
                    shutil.copyfile(approvals, os.path.join(out, "approved-digests.json"))
                    print(f"  approved-digests.json carried over from {approvals}")
            else:
                write_compose_starter(out, storage, live_model)
            if base_model is not None:
                ln = normalise_services(live_model, [live])
                bn = normalise_services(base_model, [base_dir, os.path.realpath(base_dir)])
                compose_notes = compose_differences(bn, ln, "release baseline", "host")
            else:
                r.warn(f"could not render the baseline compose model: {berr}")

        # Host boot/cron hooks: outside the tree, never captured, but a hook
        # that starts the stack from `live` brings the OLD stack back at the
        # first reboot after the cut-over (42.4 C4).
        hooks, hooks_not_scanned = host_hooks(
            [live], storage=[s.get("source") for s in (manifest.get("storage") or {}).values() if s.get("type") == "bind"])
        manifest["host_hooks"] = {"hooks": hooks, "not_scanned": hooks_not_scanned}

        manifest_path = os.path.join(out, "MANIFEST.json")
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, sort_keys=True)
            fh.write("\n")
        write_deviations(out, manifest, deviations, compose_notes)
        os.umask(old_umask)

        print(f"  Captured {len(manifest['files'])} file(s), {len(manifest['certs'])} certificate file(s), "
              f"{len(manifest['env_keys'])} .env key(s)")
        if stale_release_files:
            print(f"  {stale_release_files} file(s) were just the host's older release version - the new release replaces them (not captured)")
        if whole_file_overrides:
            r.warn(f"{whole_file_overrides} file(s) carried WHOLE because the host's original release is unknown: every '-' line "
                   "in their DEVIATIONS.md diff is new-release content the overlay would drop - merge it in, then `overlay.sh rehash`")
        print(f"  Compose project (Keycloak volume owner): {project or 'UNKNOWN'}")
        for tgt, s in sorted((manifest.get("storage") or {}).items()):
            print(f"  Storage {tgt:<15} {s['service']}: {s['source']} (left in place, not read)")
        leftovers = [n for n in manifest["not_captured"] if "backup" in n["reason"] or "staging" in n["reason"]]
        if leftovers:
            r.warn(f"{len(leftovers)} operational backup / staging file(s) found in the tree - listed in DEVIATIONS.md; move them out")
        print("  Host boot/cron hooks (systemd, cron, rc.local, init scripts - host files, NOT captured; DEVIATIONS.md lists them):")
        report_host_hooks(r, hooks, hooks_not_scanned, [live])
        print()
        print(f"  Review {os.path.join(out, 'DEVIATIONS.md')} and edit {os.path.join(out, 'compose.overlay.yml')}")
        print("  before running `overlay.sh apply` on the new checkout.")
        return 1 if r.failed else 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


def unified(a_path, b_path, rel, limit=400):
    try:
        with open(a_path, encoding="utf-8", errors="replace") as fh:
            a = fh.read().splitlines()
        with open(b_path, encoding="utf-8", errors="replace") as fh:
            b = fh.read().splitlines()
    except OSError:
        return ["  (unreadable)"]
    lines = list(difflib.unified_diff(a, b, f"baseline/{rel}", f"host/{rel}", n=1, lineterm=""))
    # Redact the CONTENT of each diff line, not the line with its +/-/space
    # prefix: "+      - KEYCLOAK_ADMIN_PASSWORD=..." does not look like an
    # assignment to redact_line() until the diff marker is stripped.
    out = [l if l.startswith(("+++", "---", "@@")) else (l[:1] + redact_line(l[1:]) if l else l)
           for l in lines[:limit]]
    if len(lines) > limit:
        out.append(f"... {len(lines) - limit} more diff lines not shown")
    return out


def yaml_str(s):
    # JSON strings are valid YAML double-quoted scalars. Compose interpolates
    # "$" in its files, so a literal "$" must be written as "$$".
    return json.dumps(s).replace("$", "$$")


def write_compose_starter(out, storage, live_model):
    lines = [
        "# compose.overlay.yml - per-environment Docker Compose overlay.",
        "#",
        "# Merged ON TOP of the release's docker-compose.yml via COMPOSE_FILE in the",
        "# checkout's .env (overlay.sh apply writes that). Compose merges override",
        "# files key by key: volumes by container target path, environment by",
        "# variable name, image/command by replacement. See documentation/42-03.",
        "#",
        "# Generated by `overlay.sh capture`. It contains ONLY the signed-document",
        "# storage mounts, pointing at where the documents already are on this host,",
        "# so a new checkout keeps reading and writing the same files. Everything",
        "# else the host needs (DMSS image versions, extra services, extra mounts or",
        "# env) must be ported by hand from COMPOSE-DIFFERENCES in DEVIATIONS.md and",
        "# then confirmed with `overlay.sh verify --live <old-dir>`.",
        "#",
        "# Never override mihailsgordijenko/ps-server or ps-client images here:",
        "# upgrade.sh and rollback.sh manage those in docker-compose.yml.",
        "services:",
    ]
    by_service = {}
    for tgt, s in sorted(storage.items()):
        by_service.setdefault(s["service"], []).append((tgt, s))
    for svc, mounts in sorted(by_service.items()):
        lines.append(f"  {svc}:")
        lines.append("    volumes:")
        for tgt, s in mounts:
            lines.append(f"      # {STORAGE_TARGETS[tgt][1]} - existing data, left in place")
            if s.get("type") == "bind":
                lines.append(f"      - {yaml_str(s['source'] + ':' + tgt)}")
            else:
                lines.append(f"      - {yaml_str(str(s['source']) + ':' + tgt)}")
    if not by_service:
        lines.append("  {}")
    with open(os.path.join(out, "compose.overlay.yml"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def write_deviations(out, manifest, deviations, compose_notes):
    b = manifest["baseline"]
    L = [
        "# Environment deviation record",
        "",
        f"Captured {manifest['captured_at']} from `{manifest['source_dir']}`.",
        f"Baseline: `{b['ref']}` (commit `{b['commit'] or 'unknown'}`, via {b['source']}).",
        f"Compose project: `{manifest.get('project_name') or 'UNKNOWN'}`.",
        "",
        "Every secret-bearing value below is shown as `<redacted>` (installation-scripts/lib/redact.py).",
        "This file lists paths, modes and redacted diffs only - never certificate keys or file contents",
        "of binary files. It is still environment-specific: keep it with the overlay, not in git.",
        "",
        "For each entry, record in the right-hand column of your change ticket whether the deviation",
        "is INTENTIONAL (keep in overlay), OBSOLETE (drop), or should be UPSTREAMED into the release.",
        "",
        "## Files carried by the overlay",
        "",
    ]
    if not deviations:
        L.append("None - the host's files are identical to the baseline.")
    for rel, cls, diff in deviations:
        L.append(f"### `{rel}` - {cls}")
        L.append("")
        L.append("```diff")
        L.extend(diff or ["  (no textual diff)"])
        L.append("```")
        L.append("")
    L += ["## Certificates", ""]
    if manifest["certs"]:
        for c in manifest["certs"]:
            L.append(f"- `{c['path']}` (host mode {c['mode']}) -> overlay `certs/` (mode 0600)")
    else:
        L.append("None found under nginx/certs/.")
    L += ["", "## .env keys", ""]
    L.append(", ".join(f"`{k}`" for k in manifest["env_keys"]) or "None (no .env on the host).")
    L += ["", "## Signed-document storage and Keycloak data", ""]
    for tgt, s in sorted((manifest.get("storage") or {}).items()):
        L.append(f"- `{tgt}` ({s['service']}): `{s['source']}` - left in place; the overlay mounts it as-is.")
    for key, name in sorted((manifest.get("named_volumes") or {}).items()):
        L.append(f"- named volume `{key}` -> Docker volume `{name}` (kept by pinning COMPOSE_PROJECT_NAME)")
    L += ["", "## COMPOSE-DIFFERENCES (baseline -> host, effective merged model)", ""]
    if not compose_notes:
        L.append("None, or compose could not be rendered (see capture output).")
    for svc, key, detail, a, bval in compose_notes:
        managed = key == "image" and any(str(bval or "").startswith(m) for m in RELEASE_MANAGED_IMAGES)
        tag = " **release-managed: choose a baseline whose release pins this, do NOT overlay it**" if managed else ""
        env_key = re.match(r"^environment\[(.*)\]$", key)
        if env_key and env_key.group(1) in FIRST_BOOT_ONLY_ENV:
            tag = " (first-boot-only: not carried by the overlay - the credential lives in the Keycloak volume and your secret manager)"
        if key == "*":
            L.append(f"- `{svc}`: {detail}{tag}")
        else:
            L.append(f"- `{svc}` `{key}`: baseline `{_fmt_value(key, a)}` -> host `{_fmt_value(key, bval)}`{tag}")
    L += ["", "## Host boot/cron hooks that reference the old checkout or run docker compose", ""]
    L += [
        "systemd units, cron entries, rc.local and init scripts are host files, outside the checkout and outside",
        "this overlay: capture does not carry them and apply does not install them. A hook that still starts",
        "the stack from the old directory runs at the next boot and brings the OLD stack back (same compose",
        "project, same Keycloak volume). Record a decision for each: repoint it at the new checkout, or disable",
        "it, in the cut-over window (42.4 C4). On a rebuilt host, re-create the ones you keep (42.6, *Host-level",
        "state the overlay does not carry*). Lines are redacted, and URLs are cut after the host.",
        "",
    ]
    hh = manifest.get("host_hooks") or {}
    if not hh.get("hooks"):
        L.append(f"None found. Scanned: {HOOK_SCANNED}.")
    for h in hh.get("hooks") or []:
        what = []
        if h["references_old"]:
            what.append("**references the old checkout** " + ", ".join(f"`{d}`" for d in h["references_old"])
                        + (" via " + ", ".join(f"`{t}`" for t in h["via_symlink"]) if h["via_symlink"] else ""))
        if h["runs_compose"]:
            what.append("runs `docker compose " + ("`, `".join(h["compose_commands"]) or "...") + "`")
        if h["compose_file_flag"]:
            what.append("passes `-f`/`--file` (ignores the overlay's COMPOSE_FILE)")
        if h["down_volumes"]:
            what.append("`down -v` (deletes the Keycloak data volume)")
        state = f", {h['enabled']}" if h.get("enabled") else ""
        L.append(f"- `{h['path']}` ({h['kind']}{state}): " + "; ".join(what))
        for l in h["lines"]:
            L.append(f"  - line {l['line']}: `{l['text'].replace('`', chr(39))}`")
    for s in hh.get("not_scanned") or []:
        L.append(f"- not scanned: {s}")
    L += ["", "## Found in the tree, NOT captured", ""]
    if manifest["not_captured"]:
        for n in manifest["not_captured"]:
            extra = f", {n['bytes']} bytes" if "bytes" in n else ""
            mode = f", mode {n['mode']}" if "mode" in n else ""
            L.append(f"- `{n['path']}` - {n['reason']}{extra}{mode}")
    else:
        L.append("Nothing.")
    with open(os.path.join(out, "DEVIATIONS.md"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(L) + "\n")


# ── apply ───────────────────────────────────────────────────────────────────

def load_manifest(overlay):
    path = os.path.join(overlay, "MANIFEST.json")
    if not os.path.isfile(path):
        die(f"{path} not found - is --overlay a directory written by `overlay.sh capture`?")
    with open(path, encoding="utf-8") as fh:
        m = json.load(fh)
    if m.get("schema_version") != SCHEMA_VERSION:
        die(f"unsupported overlay schema_version {m.get('schema_version')}")
    return m


def check_overlay_integrity(overlay, m, r):
    ok = True
    for e in m["files"]:
        p = os.path.join(overlay, "files", e["path"])
        if not os.path.isfile(p):
            r.fail(f"overlay file missing: files/{e['path']}")
            ok = False
        elif sha256_file(p) != e["sha256"]:
            r.fail(f"overlay file changed since capture: files/{e['path']} "
                   "(if you edited it on purpose, re-record it with `overlay.sh rehash`)")
            ok = False
    for e in m["files"]:
        if e.get("baseline_sha256"):
            bp = os.path.join(overlay, "base", e["path"])
            if not os.path.isfile(bp) or sha256_file(bp) != e["baseline_sha256"]:
                r.fail(f"overlay base copy missing or changed: base/{e['path']}")
                ok = False
    for c in m["certs"]:
        p = os.path.join(overlay, "certs", c["path"].split("/", 2)[2])
        if not os.path.isfile(p):
            r.fail(f"overlay certificate missing: {p}")
            ok = False
        elif sha256_file(p) != c["sha256"]:
            r.fail(f"overlay certificate changed since capture: {p} (re-record with `overlay.sh rehash` after a renewal)")
            ok = False
    mode = file_mode(overlay)
    if mode & 0o077:
        r.warn(f"overlay directory {overlay} is accessible to group/other (mode {oct(mode)}); it holds secrets - chmod 700")
    return ok


CONFLICT_MARKER_RE = re.compile(rb"^(<<<<<<< |>>>>>>> )", re.MULTILINE)


def no_unresolved_conflicts(overlay, m, r):
    """False (and a FAIL per file) if any overlay file still holds merge markers."""
    ok = True
    for e in m["files"]:
        p = os.path.join(overlay, "files", e["path"])
        if os.path.isfile(p):
            with open(p, "rb") as fh:
                if CONFLICT_MARKER_RE.search(fh.read()):
                    r.fail(f"files/{e['path']} still contains merge-conflict markers - resolve them, then `overlay.sh rehash`")
                    ok = False
    return ok


def cmd_apply(args):
    target = os.path.realpath(args.repo_root)
    overlay = os.path.realpath(args.overlay)
    if is_within(overlay, target):
        die("the overlay directory must be outside the checkout it is applied to")
    m = load_manifest(overlay)
    r = Report()
    print(f"Applying environment overlay {overlay}")
    print(f"  onto checkout {target} (HEAD {git_head(target) or 'not a git checkout'})")
    print()

    dirty = git_tracked_dirty(target)
    if dirty is None:
        die(f"{target} is not a git checkout; apply needs a clean checkout of the release baseline")
    if dirty and not args.force:
        die(f"{target} has modified tracked files ({', '.join(dirty[:8])}). Apply onto a CLEAN checkout "
            "of the release (or pass --force to re-apply onto a checkout this overlay was already applied to).")
    if os.path.exists(os.path.join(target, ".env")) and not args.force:
        die(f"{target}/.env already exists; refusing to overwrite (pass --force)")
    same_as_source = is_within(target, m["source_dir"]) or is_within(m["source_dir"], target)
    if same_as_source and not args.force:
        # First migration: never write into the directory being migrated
        # away from. A deliberate re-apply onto an overlay-managed checkout
        # (after re-capturing it, e.g. for a renewed certificate) is --force.
        die("the target checkout is the directory the overlay was captured from; migrate into a NEW "
            "directory, or pass --force to deliberately re-apply onto this overlay-managed checkout")

    if not check_overlay_integrity(overlay, m, r):
        return 1
    if not no_unresolved_conflicts(overlay, m, r):
        return 1

    # Baseline-change guard: an override replaces a whole file, so if the
    # release changed that file since capture, applying would silently throw
    # the release's change away.
    conflicts = []
    for e in m["files"]:
        tp = os.path.join(target, e["path"])
        committed = committed_sha256(target, e["path"])
        if e["class"] == "override" and committed != e["baseline_sha256"]:
            conflicts.append((e["path"], "the release changed (or removed) this file since the overlay was captured"))
        if e["class"] == "extra" and committed is not None:
            conflicts.append((e["path"], "the release now ships a file at this path"))
    if conflicts:
        for path, why in conflicts:
            (r.warn if args.accept_baseline_change else r.fail)(f"{path}: {why}")
        if not args.accept_baseline_change:
            r.info("Carry the overlay forward onto THIS release first (writes a new overlay, the old one stays intact):")
            r.info(f"  ./installation-scripts/overlay.sh rebase --overlay {overlay} --out <new-overlay-dir>")
            r.info("Or pass --accept-baseline-change to apply the old copy anyway (the release's change is dropped).")
            return 1

    for e in m["files"]:
        src = os.path.join(overlay, "files", e["path"])
        dst = os.path.join(target, e["path"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        mode = int(e["mode"], 8)
        new_mode = mode & ~0o002  # never propagate world-writable
        if e["path"] == "config/config.js":
            # Holds the backend client secret and stamping credentials: other
            # users get no access. ps-server must still read it, and from
            # 3.30 it runs as uid 1000, not root - a root:root 0o770 copy
            # crash-looped it with EACCES. secure_config_js below gives the
            # file the image's group and checks it can read it.
            new_mode &= ~0o007
        os.chmod(dst, new_mode)
        note = f" (narrowed from host mode {e['mode']})" if new_mode != mode else ""
        r.ok(f"{e['path']} ({e['class']}, mode {oct(new_mode)}){note}")

    certs_dir = os.path.join(target, "nginx", "certs")
    os.makedirs(certs_dir, exist_ok=True)
    for c in m["certs"]:
        name = c["path"].split("/", 2)[2]
        dst = os.path.join(certs_dir, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(overlay, "certs", name), dst)
        os.chmod(dst, 0o600 if name.endswith(".key") else 0o644)
        r.ok(f"nginx/certs/{name}")

    env_lines = []
    env_src = os.path.join(overlay, "env")
    if os.path.isfile(env_src):
        with open(env_src, encoding="utf-8") as fh:
            env_lines = [l.rstrip("\n") for l in fh if l.strip()]
    if m.get("project_name"):
        env_lines.append(f"COMPOSE_PROJECT_NAME={m['project_name']}")
    else:
        r.warn("overlay has no compose project name - the new checkout would get a NEW, EMPTY Keycloak volume. "
               "Set COMPOSE_PROJECT_NAME in .env by hand before `docker compose up`.")
    overlay_compose = os.path.join(overlay, "compose.overlay.yml")
    if os.path.isfile(overlay_compose):
        env_lines.append(f"COMPOSE_FILE=docker-compose.yml{os.pathsep}{overlay_compose}")
    env_path = os.path.join(target, ".env")
    fd = os.open(env_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("# Written by overlay.sh apply - regenerate with apply, do not hand-edit.\n")
        fh.write("\n".join(env_lines) + "\n")
    os.chmod(env_path, 0o600)
    r.ok(f".env (keys: {', '.join(l.split('=', 1)[0] for l in env_lines)}; mode 0600)")

    # After .env: its COMPOSE_FILE decides which ps-server image (and so which
    # uid) the effective compose model runs. --strict never widens the mode;
    # if the image cannot read config.js, apply fails here instead of
    # ps-server crash-looping at `docker compose up`.
    if any(e["path"] == "config/config.js" for e in m["files"]):
        rc, lines = dir_permissions(target, "secure_config_js", "--strict")
        text = [l.strip() for l in lines]
        if rc == 0 and text:
            r.ok(text[0])
            for t in text[1:]:
                r.info(t)
        elif rc == 1:
            r.fail((text[0] if text else "config/config.js is not readable by ps-server").replace("ERROR: ", "", 1))
            for t in text[1:]:
                r.info(t)
        else:
            r.warn("could not check that ps-server can read config/config.js ("
                   + (text[0] if text else f"exit {rc}") + ") - validate-config.sh checks it; do so before `docker compose up`")

    stamp = {"applied_at": utcnow(), "overlay_dir": overlay,
             "manifest_sha256": sha256_file(os.path.join(overlay, "MANIFEST.json")),
             "baseline_ref": m["baseline"]["ref"], "baseline_commit": m["baseline"]["commit"],
             "target_head": git_head(target)}
    with open(os.path.join(target, ".overlay-applied.json"), "w", encoding="utf-8") as fh:
        json.dump(stamp, fh, indent=2)
        fh.write("\n")

    print()
    print("Overlay applied. Nothing was started or stopped. Next:")
    print(f"  ./installation-scripts/overlay.sh verify --overlay {overlay} --live {m['source_dir']}")
    return 1 if r.failed else 0


# ── verify ──────────────────────────────────────────────────────────────────

IGNORED_EXPECTED = re.compile(r"^(\.env|\.overlay-applied\.json|\.rollback-applied\.json|deployment-evidence\.json(\.previous)?|nginx/certs/.*|\.rollback-snapshots/.*)$")


def cmd_verify(args):
    target = os.path.realpath(args.repo_root)
    overlay = os.path.realpath(args.overlay)
    m = load_manifest(overlay)
    r = Report()
    print(f"Verifying checkout {target} against overlay {overlay}")

    print("\n== Overlay integrity ==")
    if check_overlay_integrity(overlay, m, r) and no_unresolved_conflicts(overlay, m, r):
        r.ok("every overlay file matches MANIFEST.json; no unresolved merge conflicts")

    print("\n== Git working tree (tracked files) ==")
    declared = {e["path"]: e for e in m["files"]}
    rc, out, _ = git(target, "status", "--porcelain", "--untracked-files=all", "--ignored")
    if rc != 0:
        r.fail("not a git checkout")
        return 1
    modified, untracked, ignored = [], [], []
    for line in out.splitlines():
        code, path = line[:2], line[3:]
        if code == "??":
            untracked.append(path)
        elif code == "!!":
            ignored.append(path)
        else:
            modified.append(path)
    for path in modified:
        e = declared.get(path)
        if e is None:
            r.fail(f"{path}: modified but NOT declared in the overlay (undocumented drift)")
        elif sha256_file(os.path.join(target, path)) != e["sha256"]:
            r.fail(f"{path}: differs from the overlay copy (edited after apply? re-capture or re-apply)")
        else:
            r.ok(f"{path}: modified exactly as declared by the overlay")
    for path in untracked:
        e = declared.get(path)
        if e and sha256_file(os.path.join(target, path)) == e["sha256"]:
            r.ok(f"{path}: overlay extra file")
        else:
            r.fail(f"{path}: untracked and not declared in the overlay")
    for path in declared:
        if path not in modified and path not in untracked and declared[path]["class"] == "override":
            if os.path.isfile(os.path.join(target, path)) and sha256_file(os.path.join(target, path)) != declared[path]["sha256"]:
                r.fail(f"{path}: overlay override not applied")
    if not modified and not untracked:
        r.ok("git status shows no tracked modifications and no untracked files")

    print("\n== Ignored files (host state that git does not see) ==")
    for path in ignored:
        clean = path.rstrip("/")
        if IGNORED_EXPECTED.match(clean) or clean in ("nginx/certs", ".rollback-snapshots", "signed-output", "docs"):
            continue
        cls = classify_path(clean)
        if cls == "operational-backup":
            r.warn(f"{clean}: operational backup inside the checkout - move it to the backup location (see 42-04)")
        elif cls in ("sensitive-file", "cert-staging-leftover"):
            r.warn(f"{clean}: key/certificate material inside the checkout outside nginx/certs/")
        else:
            r.warn(f"{clean}: ignored file not accounted for by the overlay")

    print("\n== Certificates (nginx/certs vs the overlay's copy) ==")
    for c in m["certs"]:
        name = c["path"].split("/", 2)[2]
        live_cert = os.path.join(target, "nginx", "certs", name)
        if not os.path.isfile(live_cert):
            r.fail(f"nginx/certs/{name} is missing (the overlay has it - re-apply)")
        elif sha256_file(live_cert) != c["sha256"]:
            # Typically a renewal (renew-cert.sh or an automated renewer) that
            # the overlay has not caught up with: the next apply would put the
            # OLD certificate back.
            r.warn(f"nginx/certs/{name} differs from the overlay's copy - after a renewal, re-capture "
                   "the overlay (documentation/42-06) so a later apply does not reinstall the old one")
        else:
            r.ok(f"nginx/certs/{name} matches the overlay")

    print("\n== Secret-bearing file modes ==")
    # config/config.js: not world-readable AND readable by the ps-server
    # image the effective model runs - the same check validate-config.sh runs.
    if os.path.isfile(os.path.join(target, "config", "config.js")):
        rc, lines = dir_permissions(target, "config_js_access_report")
        report = {"OK": r.ok, "WARN": r.warn, "FAIL": r.fail}
        for l in lines or ["WARN\tconfig/config.js: could not run the permission check"]:
            status, _, msg = l.partition("\t")
            report.get(status, r.warn)(msg or l)
    candidates = [".env"] + [f"nginx/certs/{c['path'].split('/', 2)[2]}" for c in m["certs"] if c["path"].endswith(".key")]
    for rel in candidates:
        p = os.path.join(target, rel)
        if os.path.isfile(p):
            mode = file_mode(p)
            (r.warn if mode & 0o004 else r.ok)(f"{rel}: mode {oct(mode)}" + (" is world-readable" if mode & 0o004 else ""))
    snaps = os.path.join(target, ".rollback-snapshots")
    if os.path.isdir(snaps) and file_mode(snaps) & 0o077:
        r.warn(f".rollback-snapshots/ is mode {oct(file_mode(snaps))}; it holds copies of config.js - chmod 700")

    print("\n== Host boot and cron hooks (systemd, cron, rc.local, init scripts - host files, not in the overlay) ==")
    # The directory the overlay was captured from and the --live one are
    # "old" unless they are this checkout (a re-capture from it, 42.6).
    old_dirs = []
    for d in (args.live, m.get("source_dir")):
        if not d:
            continue
        d = os.path.abspath(d)
        if is_within(d, target) or is_within(target, d):
            continue
        if all(os.path.realpath(d) != os.path.realpath(x) for x in old_dirs):
            old_dirs.append(d)
    hooks, not_scanned = host_hooks(old_dirs, checkout=target, storage=[
        s.get("source") for s in (m.get("storage") or {}).values() if s.get("type") == "bind"])
    report_host_hooks(r, hooks, not_scanned, old_dirs, checkout=target)

    print("\n== Effective Docker Compose model ==")
    model, err = compose_config(target)
    if model is None:
        r.fail(f"`docker compose config` failed in {target}: {err}")
        return 1
    if m.get("project_name"):
        if model.get("name") == m["project_name"]:
            r.ok(f"compose project name '{model['name']}' matches the host (Keycloak data volume is reused)")
        else:
            r.fail(f"compose project name '{model.get('name')}' != host's '{m['project_name']}': "
                   "Keycloak would start against a NEW, EMPTY volume (no realm, no users)")
    for key, name in sorted(named_volume_names(model).items()):
        (r.ok if volume_exists(name) else r.fail)(
            f"named volume '{key}' -> '{name}' " + ("exists" if volume_exists(name) else
            "does NOT exist - `up` would create an empty one"))
    for svc_name, svc in sorted((model.get("services") or {}).items()):
        for v in svc.get("volumes") or []:
            tgt = v.get("target")
            if tgt in STORAGE_TARGETS and STORAGE_TARGETS[tgt][0] == svc_name:
                src = v.get("source")
                want = ((m.get("storage") or {}).get(tgt) or {}).get("source")
                if want and src != want:
                    r.fail(f"{svc_name} {tgt} -> {src}, but the host's documents are at {want}")
                elif v.get("type") == "bind" and src and not os.path.isdir(src):
                    r.fail(f"{svc_name} {tgt} -> {src} does not exist")
                else:
                    ww = v.get("type") == "bind" and src and os.path.isdir(src) and file_mode(src) & 0o002
                    (r.fail if ww else r.ok)(f"{svc_name} {tgt} -> {src}" + (" is WORLD-WRITABLE" if ww else ""))
            elif v.get("type") == "bind" and m.get("source_dir") and v.get("source") and is_within(v["source"], m["source_dir"]):
                r.warn(f"{svc_name} {tgt} is bind-mounted from the OLD deployment directory ({v['source']}) - intended?")
        img = svc.get("image") or ""
        if "@sha256:" not in img:
            r.warn(f"{svc_name}: image '{img}' is not digest-pinned (validate-config.sh FAILs it)")

    if args.live:
        print(f"\n== Effective model vs the running host ({args.live}) ==")
        live = os.path.realpath(args.live)
        live_model, lerr = compose_config(live)
        if live_model is None:
            r.warn(f"could not render the host's compose model: {lerr}")
        else:
            a = normalise_services(live_model, [live])
            b = normalise_services(model, [target, live])
            diffs = compose_differences(a, b, "running host", "new checkout")
            real = 0
            for svc, key, detail, va, vb in diffs:
                what = detail or f"host {_fmt_value(key, va)} -> new {_fmt_value(key, vb)}"
                env_key = re.match(r"^environment\[(.*)\]$", key)
                if env_key and env_key.group(1) in FIRST_BOOT_ONLY_ENV:
                    r.info(f"{svc} {key} differs - first-boot-only, no effect on the existing Keycloak volume")
                    continue
                real += 1
                r.warn(f"{svc} {key}: {what}")
            diffs = real
            if not diffs:
                r.ok("no behaviour differences from the running host (modulo checkout path)")
            if diffs:
                r.info("Each WARN above is a behaviour change the cut-over would introduce. Either port it into")
                r.info("compose.overlay.yml, or record it as intentional in the change ticket.")

    print()
    if r.failed:
        print("RESULT: FAIL - do not cut over.")
        return 1
    print("RESULT: OK" + (" with warnings (review each one)" if r.warned else ""))
    return 0


# ── rebase ──────────────────────────────────────────────────────────────────

def cmd_rebase(args):
    """Carry an overlay forward onto the release checked out in repo_root.

    For every whole-file override, replays (overlay copy - its old baseline)
    onto the new release's version with a 3-way merge. Writes a NEW overlay
    directory; the source overlay is never modified, so the previous release
    + previous overlay remain a complete rollback target."""
    src = os.path.realpath(args.overlay)
    out = os.path.abspath(args.out)
    target = os.path.realpath(args.repo_root)
    m = load_manifest(src)
    r = Report()
    if is_within(out, target) or is_within(out, src):
        die("--out must be a new directory outside the checkout and outside the source overlay")
    if os.path.exists(out) and os.listdir(out):
        die(f"--out {out} already exists and is not empty")
    dirty = git_tracked_dirty(target)
    if dirty is None or dirty:
        die(f"{target} must be a CLEAN git checkout of the new release (modified: {', '.join((dirty or [])[:5])})")
    if not check_overlay_integrity(src, m, r) or not no_unresolved_conflicts(src, m, r):
        return 1
    old_umask = os.umask(0o077)
    shutil.copytree(src, out)
    os.chmod(out, 0o700)
    print(f"Rebasing overlay {src}")
    print(f"  onto release {target} (HEAD {git_head(target)})")
    print(f"  into {out}")
    print()
    work = tempfile.mkdtemp(prefix="padsign-rebase-")
    try:
        for e in m["files"]:
            new_rel = os.path.join(work, "new")
            os.makedirs(os.path.dirname(os.path.join(new_rel, e["path"])), exist_ok=True)
            p = subprocess.run(["git", "-C", target, "cat-file", "--filters", f"HEAD:{e['path']}"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            in_new = p.returncode == 0
            if in_new:
                with open(os.path.join(new_rel, e["path"]), "wb") as fh:
                    fh.write(p.stdout)
            new_sha = hashlib.sha256(p.stdout).hexdigest() if in_new else None
            ov_file = os.path.join(out, "files", e["path"])
            if e["class"] == "extra":
                if in_new:
                    r.warn(f"{e['path']}: the new release now ships this file; the overlay's extra copy still replaces it - review")
                continue
            if not in_new:
                r.warn(f"{e['path']}: the new release removed this file; the overlay still carries it as an override - review")
                continue
            if new_sha == e["baseline_sha256"]:
                r.ok(f"{e['path']}: unchanged by the new release")
                continue
            old_base = os.path.join(src, "base", e["path"])
            n = merge3(os.path.join(new_rel, e["path"]), old_base, os.path.join(src, "files", e["path"]), ov_file)
            if n is None:
                r.fail(f"{e['path']}: changed by the new release and cannot be merged as text - merge files/{e['path']} by hand")
                continue
            e["baseline_sha256"] = new_sha
            e["sha256"] = sha256_file(ov_file)
            e["merge"] = "3-way (rebase)"
            e["conflicts"] = n
            keep_base(out, e["path"], os.path.join(new_rel, e["path"]))
            if n:
                r.fail(f"{e['path']}: {n} conflict(s) - resolve the <<<<<<< markers in {ov_file}, then `overlay.sh rehash --overlay {out}`")
            else:
                r.ok(f"{e['path']}: release changes merged under the overlay's edits")
        m["rebased_from"] = {"overlay": src, "baseline": m["baseline"]}
        m["baseline"] = {"ref": git_head(target), "commit": git_head(target), "source": f"rebase onto {target}"}
        m["rebased_at"] = utcnow()
        with open(os.path.join(out, "MANIFEST.json"), "w", encoding="utf-8") as fh:
            json.dump(m, fh, indent=2, sort_keys=True)
            fh.write("\n")
    finally:
        shutil.rmtree(work, ignore_errors=True)
        os.umask(old_umask)
    print()
    print("RESULT: " + ("FAIL - resolve the conflicts above" if r.failed else "OK") + f" (new overlay: {out})")
    return 1 if r.failed else 0


# ── rehash ──────────────────────────────────────────────────────────────────

def write_manifest(overlay, m):
    with open(os.path.join(overlay, "MANIFEST.json"), "w", encoding="utf-8") as fh:
        json.dump(m, fh, indent=2, sort_keys=True)
        fh.write("\n")


def cmd_rehash(args):
    """Re-record checksums after the operator deliberately edits overlay files
    (resolved a merge conflict, changed a value, renewed a certificate).
    Prints what changed so the edit is visible in the log. A file the
    manifest lists but that is gone is an error, and nothing is re-recorded:
    re-recording around it would make the overlay look complete."""
    overlay = os.path.realpath(args.overlay)
    m = load_manifest(overlay)
    entries = [(f"files/{e['path']}", os.path.join(overlay, "files", e["path"]), e) for e in m["files"]]
    entries += [(f"certs/{c['path'].split('/', 2)[2]}", os.path.join(overlay, "certs", c["path"].split("/", 2)[2]), c)
                for c in m["certs"]]
    missing = [(label, e) for label, p, e in entries if not os.path.isfile(p)]
    if missing:
        for label, e in missing:
            print(f"  FAIL {label} is listed in MANIFEST.json but is missing from the overlay")
        print()
        print("  Nothing was re-recorded. Either restore the file(s) (from the overlay's backup, 42.3 O5),")
        missing_files = [e["path"] for label, e in missing if label.startswith("files/")]
        if missing_files:
            print("  or, if the entry is OBSOLETE and should leave the overlay, drop it:")
            print(f"    ./installation-scripts/overlay.sh drop --overlay {overlay} {' '.join(missing_files)}")
        if any(label.startswith("certs/") for label, _ in missing):
            print("  A missing certificate must be restored or re-captured (documentation/42-06, Certificate renewal).")
        return 1
    changed = 0
    for label, p, e in entries:
        new = sha256_file(p)
        if new != e["sha256"]:
            print(f"  {label}: re-recorded")
            e["sha256"] = new
            changed += 1
    m["rehashed_at"] = utcnow()
    write_manifest(overlay, m)
    print(f"  {changed} checksum(s) updated in MANIFEST.json")
    return 0


# ── drop ────────────────────────────────────────────────────────────────────

def _manifest_path(raw):
    """A path as the operator types it -> the MANIFEST "path" form:
    forward slashes, no leading "./", and the overlay's own "files/" prefix
    accepted as well (DEVIATIONS.md headings name repo paths, `ls` shows
    files/<path>)."""
    p = raw.replace("\\", "/").strip()
    while p.startswith("./"):
        p = p[2:]
    if p.startswith("files/"):
        p = p[len("files/"):]
    return p


def _prune_empty_dirs(path, stop):
    """Remove now-empty parent directories of path, up to (not including) stop."""
    d = os.path.dirname(path)
    stop = os.path.realpath(stop)
    while os.path.realpath(d) != stop and is_within(d, stop):
        try:
            os.rmdir(d)
        except OSError:
            break
        d = os.path.dirname(d)


def cmd_drop(args):
    """Remove captured files from an overlay: the DEVIATIONS.md entries the
    change ticket marks OBSOLETE (runbook 42.3 O4). For each path: deletes
    files/<path> (and base/<path>, the release copy kept for merges), removes
    its MANIFEST.json record, and appends a note to DEVIATIONS.md. All or
    nothing: if any path is not a captured file, nothing is changed."""
    overlay = os.path.realpath(args.overlay)
    m = load_manifest(overlay)
    declared = {e["path"]: e for e in m["files"]}
    cert_paths = {c["path"] for c in m["certs"]}
    wanted, unknown = [], []
    for raw in args.paths:
        p = _manifest_path(raw)
        if p in declared:
            if p not in wanted:
                wanted.append(p)
        else:
            unknown.append((raw, p))
    if unknown:
        for raw, p in unknown:
            if p in cert_paths or p.startswith("certs/") or p.startswith("nginx/certs/"):
                why = "a certificate - not dropped this way; re-capture after a certificate change (documentation/42-06)"
            elif p in ("env", ".env") or p in (m.get("env_keys") or []):
                why = ".env values are not files of the overlay - edit the overlay's env file"
            elif p in ("compose.overlay.yml", "docker-compose.yml"):
                why = "compose differences are dropped by editing compose.overlay.yml (42.3 O4)"
            else:
                why = "not a file captured in MANIFEST.json"
            print(f"  FAIL {raw}: {why}")
        print()
        print(f"  Nothing was dropped. Files this overlay carries ({len(declared)}):")
        for p in sorted(declared):
            print(f"    {p}")
        return 1

    print(f"Dropping {len(wanted)} file(s) from overlay {overlay}")
    when = utcnow()
    notes = []
    for p in wanted:
        e = declared[p]
        for sub in ("files", "base"):
            fp = os.path.join(overlay, sub, p)
            if os.path.lexists(fp):
                os.remove(fp)
                _prune_empty_dirs(fp, os.path.join(overlay, sub))
        m["files"] = [x for x in m["files"] if x["path"] != p]
        m.setdefault("dropped", []).append({"path": p, "class": e.get("class"), "sha256": e.get("sha256"),
                                           "dropped_at": when})
        if e.get("class") == "override":
            effect = "the checkout keeps the release's version of this file"
        else:
            effect = "the checkout no longer gets this file"
        notes.append(f"- `{p}` ({e.get('class')}) - dropped {when} with `overlay.sh drop` (OBSOLETE): {effect}.")
        print(f"  OK   {p} ({e.get('class')}): removed from files/ and MANIFEST.json - {effect}")
        if p == "config/config.js":
            print("  WARN config/config.js holds this environment's secrets and settings: without it the checkout")
            print("       runs the release's shipped config.js (demo credentials). Intended?")
    write_manifest(overlay, m)

    dev = os.path.join(overlay, "DEVIATIONS.md")
    header = "## Dropped from the overlay"
    text = ""
    if os.path.isfile(dev):
        with open(dev, encoding="utf-8") as fh:
            text = fh.read()
    fd = os.open(dev, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fh:
        if header not in text:
            # One blank line between the previous content and the new section.
            sep = "" if not text or text.endswith("\n\n") else "\n" if text.endswith("\n") else "\n\n"
            fh.write(sep + header + "\n\n")
        fh.write("\n".join(notes) + "\n")
    print(f"  DEVIATIONS.md: {len(notes)} note(s) appended under '{header[3:]}'")
    print()
    print("  If this overlay is already applied to a checkout, the dropped files are still there: restore")
    print("  the release's version (`git checkout -- <path>` for an override, delete an extra file), then")
    print("  `overlay.sh apply --force` and `overlay.sh verify`. See documentation/42-03 O4.")
    return 0


def main(argv):
    import argparse
    p = argparse.ArgumentParser(prog="overlay.sh")
    p.add_argument("--repo-root", required=True, help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("capture")
    c.add_argument("--baseline", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--from", dest="source")
    c.add_argument("--host-base", help="git ref or clean checkout of the release the host was ORIGINALLY deployed from "
                                        "(default: the host's own git HEAD, if it is a git checkout)")
    a = sub.add_parser("apply")
    a.add_argument("--overlay", required=True)
    a.add_argument("--accept-baseline-change", action="store_true")
    a.add_argument("--force", action="store_true")
    v = sub.add_parser("verify")
    v.add_argument("--overlay", required=True)
    v.add_argument("--live")
    h = sub.add_parser("rehash")
    h.add_argument("--overlay", required=True)
    d = sub.add_parser("drop")
    d.add_argument("--overlay", required=True)
    d.add_argument("paths", nargs="+", metavar="path")
    rb = sub.add_parser("rebase")
    rb.add_argument("--overlay", required=True)
    rb.add_argument("--out", required=True)
    args = p.parse_args(argv)
    return {"capture": cmd_capture, "apply": cmd_apply, "verify": cmd_verify,
            "rehash": cmd_rehash, "drop": cmd_drop, "rebase": cmd_rebase}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
