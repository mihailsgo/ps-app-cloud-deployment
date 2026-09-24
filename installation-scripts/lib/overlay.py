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
            else:
                write_compose_starter(out, storage, live_model)
            if base_model is not None:
                ln = normalise_services(live_model, [live])
                bn = normalise_services(base_model, [base_dir, os.path.realpath(base_dir)])
                compose_notes = compose_differences(bn, ln, "release baseline", "host")
            else:
                r.warn(f"could not render the baseline compose model: {berr}")

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
            # Holds the backend client secret and stamping credentials. Only
            # ps-server reads it, and ps-server runs as root (see
            # lib/dir-permissions.sh), so "other" needs no access at all.
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

IGNORED_EXPECTED = re.compile(r"^(\.env|\.overlay-applied\.json|deployment-evidence\.json(\.previous)?|nginx/certs/.*|\.rollback-snapshots/.*)$")


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
    candidates = [".env", "config/config.js"] + [f"nginx/certs/{c['path'].split('/', 2)[2]}" for c in m["certs"] if c["path"].endswith(".key")]
    for rel in candidates:
        p = os.path.join(target, rel)
        if os.path.isfile(p):
            mode = file_mode(p)
            (r.warn if mode & 0o004 else r.ok)(f"{rel}: mode {oct(mode)}" + (" is world-readable" if mode & 0o004 else ""))
    snaps = os.path.join(target, ".rollback-snapshots")
    if os.path.isdir(snaps) and file_mode(snaps) & 0o077:
        r.warn(f".rollback-snapshots/ is mode {oct(file_mode(snaps))}; it holds copies of config.js - chmod 700")

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
            r.warn(f"{svc_name}: image '{img}' is not digest-pinned")

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

def cmd_rehash(args):
    """Re-record checksums after the operator deliberately edits overlay files
    (resolved a merge conflict, changed a value, renewed a certificate).
    Prints what changed so the edit is visible in the log."""
    overlay = os.path.realpath(args.overlay)
    m = load_manifest(overlay)
    changed = 0
    for e in m["files"]:
        p = os.path.join(overlay, "files", e["path"])
        new = sha256_file(p)
        if new != e["sha256"]:
            print(f"  files/{e['path']}: re-recorded")
            e["sha256"] = new
            changed += 1
    for c in m["certs"]:
        p = os.path.join(overlay, "certs", c["path"].split("/", 2)[2])
        new = sha256_file(p)
        if new != c["sha256"]:
            print(f"  certs/{os.path.basename(p)}: re-recorded")
            c["sha256"] = new
            changed += 1
    m["rehashed_at"] = utcnow()
    with open(os.path.join(overlay, "MANIFEST.json"), "w", encoding="utf-8") as fh:
        json.dump(m, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"  {changed} checksum(s) updated in MANIFEST.json")
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
    rb = sub.add_parser("rebase")
    rb.add_argument("--overlay", required=True)
    rb.add_argument("--out", required=True)
    args = p.parse_args(argv)
    return {"capture": cmd_capture, "apply": cmd_apply, "verify": cmd_verify,
            "rehash": cmd_rehash, "rebase": cmd_rebase}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
