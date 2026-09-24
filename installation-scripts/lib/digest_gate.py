"""Image digest gate over the EFFECTIVE compose model.

Called by lib/digests.sh (never directly by an operator). Two subcommands:

  images <repo_root>
      Prints every service image of the effective compose model, one
      "<service>\t<image>" line per service, preceded by one
      "#source\t<how>\t<detail>" line saying how the model was obtained.

      "Effective" means what `docker compose up` would actually run: the
      files COMPOSE_FILE names (shell environment first, then .env, exactly
      like compose itself), or docker-compose.yml plus an auto-loaded
      docker-compose.override.yml when COMPOSE_FILE is unset. That is how an
      environment overlay (installation-scripts/overlay.sh, documentation/42)
      adds or replaces images, so a gate that reads docker-compose.yml alone
      never sees them.

      Every profile is enabled, so the profile-gated services (local-eseal
      stamping, wizard) are always covered whether or not they run here.

      Uses `docker compose config` when docker is available. Without docker,
      or when compose cannot render the model, it falls back to reading the
      same files itself: later files replace an earlier file's image for the
      same service, which is compose's merge rule for `image:`.

  check <repo_root> <release approved-digests.json>
      Reads "images" output on stdin and prints one "<STATUS>\t<message>"
      line per finding, STATUS one of OK / FAIL / INFO. Every image must be
      digest-pinned and approved, either by the release's
      release/approved-digests.json or, on a host run as "release baseline +
      environment overlay", by the overlay's own approved-digests.json (the
      overlay directory named in .overlay-applied.json). Anything else FAILs.

  approvals <repo_root>
      Prints the overlay's approvals as "<key>\t<repository>\t<tag>\t<digest>"
      (nothing if there is no overlay or it approves nothing), for
      check-digest-drift.sh's live registry comparison.

Set PADSIGN_DIGEST_GATE_NO_DOCKER=1 to force the file fallback (used by tests
and on hosts where docker is present but must not be called).
"""

import json
import os
import re
import subprocess
import sys

try:
    sys.stdout.reconfigure(newline="\n")
except AttributeError:
    pass

# Same list as overlay.py's RELEASE_MANAGED_IMAGES (gate G2): an overlay never
# overrides these, so an overlay can never approve them either.
RELEASE_MANAGED_IMAGES = ("mihailsgordijenko/ps-server", "mihailsgordijenko/ps-client")

ENV_APPROVALS_NAME = "approved-digests.json"


# ── image references ────────────────────────────────────────────────────────

def split_ref(ref):
    """repository, tag, digest of an image reference. A registry port
    (host:5000/repo) is not mistaken for a tag."""
    name, _, digest = ref.partition("@")
    tag = ""
    if ":" in name.rsplit("/", 1)[-1]:
        name, tag = name.rsplit(":", 1)
    return name, tag, digest


def norm_repo(repo):
    """docker.io/library/nginx, docker.io/nginx and nginx are one repository."""
    for prefix in ("docker.io/library/", "index.docker.io/library/", "docker.io/", "index.docker.io/"):
        if repo.startswith(prefix):
            repo = repo[len(prefix):]
            break
    if repo.startswith("library/") and repo.count("/") == 1:
        repo = repo[len("library/"):]
    return repo


# ── effective compose model ─────────────────────────────────────────────────

def read_dotenv(repo_root):
    values = {}
    try:
        with open(os.path.join(repo_root, ".env"), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    return values


def compose_files(repo_root):
    """The files compose would load, resolved against repo_root."""
    dotenv = read_dotenv(repo_root)
    raw = os.environ.get("COMPOSE_FILE") or dotenv.get("COMPOSE_FILE") or ""
    if raw:
        sep = os.environ.get("COMPOSE_PATH_SEPARATOR") or dotenv.get("COMPOSE_PATH_SEPARATOR") or ""
        if not sep:
            # os.pathsep of whoever wrote it: ';' on Windows (where 'C:\' also
            # contains ':'), ':' on Linux.
            sep = ";" if ";" in raw else ":"
        files = [f for f in raw.split(sep) if f]
    else:
        files = ["docker-compose.yml"]
        if os.path.isfile(os.path.join(repo_root, "docker-compose.override.yml")):
            files.append("docker-compose.override.yml")
    return [f if os.path.isabs(f) else os.path.join(repo_root, f) for f in files]


def display_files(repo_root, files):
    out = []
    for f in files:
        rel = os.path.relpath(f, repo_root) if os.path.abspath(f).startswith(os.path.abspath(repo_root)) else f
        out.append(rel.replace(os.sep, "/"))
    return ", ".join(out)


def model_from_docker(repo_root):
    """(services dict {name: image}, profiles list) or (None, reason)."""
    def run(args):
        p = subprocess.run(["docker", "compose"] + args, cwd=repo_root,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

    try:
        rc, out, err = run(["version"])
    except OSError:
        return None, "docker is not installed"
    if rc != 0:
        return None, "docker compose is not available"
    # Enumerate the declared profiles rather than `--profile '*'`, which older
    # compose releases do not understand.
    rc, out, err = run(["config", "--profiles"])
    if rc != 0:
        return None, (err.strip().splitlines() or ["docker compose config failed"])[0]
    profiles = [p.strip() for p in out.splitlines() if p.strip()]
    args = []
    for p in profiles:
        args += ["--profile", p]
    rc, out, err = run(args + ["config", "--format", "json"])
    if rc != 0:
        return None, (err.strip().splitlines() or ["docker compose config failed"])[0]
    try:
        services = json.loads(out).get("services") or {}
    except ValueError as exc:
        return None, "unreadable docker compose config output: %s" % exc
    return {name: (svc or {}).get("image") or "" for name, svc in services.items()}, profiles


_TOP_KEY = re.compile(r"^([A-Za-z0-9_.\-\"']+)\s*:")
_KEY = re.compile(r"^(\s+)([A-Za-z0-9_.\-]+|\"[^\"]+\"|'[^']+')\s*:\s*(#.*)?$")
_IMAGE = re.compile(r"^\s+image\s*:\s*[\"']?([^\"'\s#]+)")


def model_from_files(files):
    """Minimal line reader for the one field this needs. Not a YAML parser:
    it tracks the top-level `services:` block, the indentation of its keys,
    and each service's `image:`."""
    services = {}
    missing = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            missing.append(path)
            continue
        in_services = False
        svc_indent = None
        svc = None
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            top = _TOP_KEY.match(line)
            if top:
                in_services = top.group(1).strip("\"'") == "services"
                svc_indent = None
                svc = None
                continue
            if not in_services:
                continue
            indent = len(line) - len(line.lstrip())
            key = _KEY.match(line)
            if key and (svc_indent is None or indent == svc_indent):
                svc_indent = indent
                svc = key.group(2).strip("\"'")
                services.setdefault(svc, "")
                continue
            if svc is not None and svc_indent is not None and indent > svc_indent:
                img = _IMAGE.match(line)
                if img:
                    services[svc] = img.group(1)
    return services, missing


def effective_images(repo_root):
    files = compose_files(repo_root)
    reason = "PADSIGN_DIGEST_GATE_NO_DOCKER is set"
    if os.environ.get("PADSIGN_DIGEST_GATE_NO_DOCKER") != "1":
        services, detail = model_from_docker(repo_root)
        if services is not None:
            profiles = ", ".join(detail) or "none declared"
            print("#source\tdocker\tdocker compose config over %s, all profiles (%s)"
                  % (display_files(repo_root, files), profiles))
            for name in sorted(services):
                print("%s\t%s" % (name, services[name]))
            return 0
        reason = detail
    services, missing = model_from_files(files)
    detail = "read %s directly (%s)" % (display_files(repo_root, files), reason)
    if missing:
        detail += "; MISSING: %s" % display_files(repo_root, missing)
    print("#source\tfiles\t%s" % detail)
    for name in sorted(services):
        print("%s\t%s" % (name, services[name]))
    return 0


# ── approvals ───────────────────────────────────────────────────────────────

def load_release(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    return {k: e for k, e in (data.get("images") or {}).items()}


def env_approvals_path(repo_root):
    """The overlay's approved-digests.json, if this checkout runs one."""
    try:
        with open(os.path.join(repo_root, ".overlay-applied.json"), encoding="utf-8") as fh:
            overlay_dir = (json.load(fh) or {}).get("overlay_dir")
    except (OSError, ValueError):
        return None
    if not overlay_dir:
        return None
    path = os.path.join(overlay_dir, ENV_APPROVALS_NAME)
    return path if os.path.isfile(path) else None


def load_env_approvals(repo_root, findings):
    """Validated overlay approvals as {key: entry}. Invalid entries are
    reported as FAIL findings and not used."""
    path = env_approvals_path(repo_root)
    if not path:
        return {}, None
    try:
        with open(path, encoding="utf-8") as fh:
            images = (json.load(fh) or {}).get("images") or {}
    except (OSError, ValueError) as exc:
        findings.append(("FAIL", "cannot read the overlay's %s (%s): %s" % (ENV_APPROVALS_NAME, path, exc)))
        return {}, path
    good = {}
    for key, e in images.items():
        repo = norm_repo(e.get("repository", ""))
        if repo in RELEASE_MANAGED_IMAGES:
            findings.append(("FAIL", "overlay %s entry '%s' approves %s, which only the release may approve (gate G2)"
                             % (ENV_APPROVALS_NAME, key, repo)))
        elif not (e.get("repository") and e.get("tag") and re.match(r"^sha256:[0-9a-f]{64}$", e.get("digest", ""))):
            findings.append(("FAIL", "overlay %s entry '%s' needs repository, tag and a sha256 digest"
                             % (ENV_APPROVALS_NAME, key)))
        elif not str(e.get("why", "")).strip():
            findings.append(("FAIL", "overlay %s entry '%s' has no 'why' - record the reviewed reason for the exception"
                             % (ENV_APPROVALS_NAME, key)))
        else:
            good[key] = e
    return good, path


def approvals(repo_root):
    findings = []
    env, _ = load_env_approvals(repo_root, findings)
    for key, e in env.items():
        print("\t".join([key, e["repository"], e["tag"], e["digest"]]))
    return 0


def check(repo_root, release_path):
    findings = []
    source = ""
    services = []
    for line in sys.stdin.read().splitlines():
        line = line.rstrip("\r")
        if not line:
            continue
        parts = line.split("\t")
        if parts[0] == "#source":
            source = parts[2] if len(parts) > 2 else ""
            findings.append(("INFO", "effective compose model: %s" % source))
            if "MISSING:" in source:
                findings.append(("FAIL", "a compose file named by COMPOSE_FILE does not exist (%s)"
                                 % source.split("MISSING:", 1)[1].strip()))
            continue
        services.append((parts[0], parts[1] if len(parts) > 1 else ""))

    try:
        release = load_release(release_path)
    except Exception as exc:  # noqa: BLE001 - any failure here is a FAIL
        print("FAIL\tcannot read %s: %s" % (release_path, exc))
        return 0
    env, env_path = load_env_approvals(repo_root, findings)

    by_repo = {}
    for key, e in release.items():
        by_repo.setdefault(norm_repo(e.get("repository", "")), []).append(("release", key, e))
    for key, e in env.items():
        by_repo.setdefault(norm_repo(e["repository"]), []).append(("overlay", key, e))

    # Every image the release approves has to be in the model at all - a
    # release image that vanished (renamed service, typo in an overlay) is
    # as wrong as an extra one.
    present = {norm_repo(split_ref(img)[0]) for _, img in services if img}
    for key, e in release.items():
        if norm_repo(e.get("repository", "")) not in present:
            findings.append(("FAIL", "%s: %s not found in the effective compose model" % (key, e.get("repository"))))

    for svc, image in services:
        if not image:
            findings.append(("FAIL", "service %s has no image (built locally?) - nothing to verify" % svc))
            continue
        repo, tag, digest = split_ref(image)
        entries = by_repo.get(norm_repo(repo), [])
        release_entries = [x for x in entries if x[0] == "release"]
        label = release_entries[0][1] if release_entries else "service %s" % svc
        if release_entries and release_entries[0][1] != svc:
            label = "%s (service %s)" % (label, svc)
        if not digest:
            findings.append(("FAIL", "%s: pinned by tag only (%s), no immutable digest" % (label, image)))
            continue
        where_approved = "release/approved-digests.json" + (" or the overlay's %s" % ENV_APPROVALS_NAME if env_path else "")
        if not entries:
            findings.append(("FAIL", "%s: %s has no entry in %s - unapproved image"
                             % (label, image, where_approved)))
            continue
        match = [x for x in entries if x[2].get("digest") == digest]
        if not match:
            want = ", ".join("%s for %s:%s" % (x[2].get("digest"), x[1], x[2].get("tag")) for x in entries)
            findings.append(("FAIL", "%s: pinned digest (%s) does not match the approved digest in %s (%s) - unapproved digest"
                             % (label, digest, where_approved, want)))
            continue
        exact = [x for x in match if x[2].get("tag") == tag]
        if not exact:
            # Same content, but the tag a human reads says something else.
            findings.append(("FAIL", "%s: pinned tag (%s) does not match the approved tag (%s)"
                             % (label, tag, match[0][2].get("tag"))))
            continue
        where, key, e = exact[0]
        if where == "release":
            findings.append(("OK", "%s: digest-pinned and matches release/approved-digests.json" % label))
        else:
            findings.append(("OK", "%s: digest-pinned and approved for this environment by %s (entry '%s': %s)"
                             % (label, env_path, key, str(e.get("why", "")).strip())))

    for status, message in findings:
        print("%s\t%s" % (status, message))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "images":
        return effective_images(argv[1])
    if len(argv) >= 3 and argv[0] == "check":
        return check(argv[1], argv[2])
    if len(argv) >= 2 and argv[0] == "approvals":
        return approvals(argv[1])
    sys.stderr.write("usage: digest_gate.py images <repo_root> | check <repo_root> <approved-digests.json> | approvals <repo_root>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
