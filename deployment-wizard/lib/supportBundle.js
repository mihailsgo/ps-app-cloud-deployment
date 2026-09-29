'use strict';

const fs = require('fs');
const path = require('path');

const { HOST_PROJECT_DIR, projectPath } = require('./paths');
const { parseHelperCheckOutput } = require('./outputParser');
const { describeExecFailure } = require('./execError');
const { isValidHost } = require('./hostName');

const BUNDLE_DIR = projectPath('support-bundles');
const SUPPORT_BUNDLE_SCRIPT = projectPath('installation-scripts', 'support-bundle.sh');

// Matches exactly what support-bundle.sh names its output:
// padsign-support-<host>-<YYYYMMDDTHHMMSSZ>.tar.gz. Deliberately strict: the
// download route hands a file from the host to a browser, so a name must
// never be able to escape support-bundles/.
const NAME_RE = /^padsign-support-[A-Za-z0-9.-]+-\d{8}T\d{6}Z\.tar\.gz$/;

const SINCE_CHOICES = ['1h', '6h', '24h', '72h', '168h'];

// One bundle generation at a time. This is its own flag rather than
// scriptRunner.js's run lock: support-bundle.sh is read-only diagnostics, not
// a mutating deploy/upgrade run, so it must not fight over (or be blocked by)
// scriptRunner's lock, but two bundles writing into BUNDLE_DIR concurrently
// is still worth serializing. Process-local by design: the wizard is a single
// container running a single Node process, so there is nothing to share it
// with (and a lock file would only go stale when the container restarts).
let inProgress = false;

function isBundleRunning() {
  return inProgress;
}

// Extracts the bundle path support-bundle.sh reports as its LAST stdout
// line ("BUNDLE <path>"), and the OK/WARN progress rows via the same
// parseHelperCheckOutput() every other helper script's output goes through.
function parseBundleOutput(stdout) {
  const text = String(stdout || '');
  let bundlePath = null;
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/\r$/, '');
    const m = /^BUNDLE (.+)$/.exec(line);
    if (m) bundlePath = m[1].trim(); // keep the LAST match, in case of a retry line earlier
  }
  // The BUNDLE line is skipped so it is not folded into the last OK/WARN
  // row's message as a continuation line.
  const { checks } = parseHelperCheckOutput(text, { skip: (line) => /^BUNDLE /.test(line) });
  return { path: bundlePath, checks };
}

// The single trust decision for "is this file a bundle we may hand out?",
// used both for the path the script reports and for a name the browser sends
// back. It judges the file AFTER symlinks are resolved - a name that merely
// looks right proves nothing when `dir` could hold a link pointing anywhere.
// The resolved file must be a regular file whose parent directory is exactly
// the real `dir` (directly inside it, not merely somewhere below it) and
// whose own resolved name matches NAME_RE. Because the returned name is the
// resolved basename, anything createBundle() reports also round-trips through
// resolveBundle(). Returns the resolved absolute path, or null.
function resolveInDir(candidate, dir) {
  try {
    const realDir = fs.realpathSync(dir);
    const resolved = fs.realpathSync(candidate);
    if (path.dirname(resolved) !== realDir) return null;
    if (!NAME_RE.test(path.basename(resolved))) return null;
    if (!fs.statSync(resolved).isFile()) return null;
    return resolved;
  } catch (err) {
    return null; // missing file/dir, permission error, ... - all "not a bundle"
  }
}

function resolveReportedPath(reportedPath, dir) {
  if (!reportedPath) return null;
  return resolveInDir(reportedPath, dir);
}

// Runs support-bundle.sh and returns the resulting bundle's name/size, plus
// the OK/WARN rows for display. `exec` is injectable (no default) because
// installation-scripts/support-bundle.sh does not exist in this checkout yet
// — every test supplies its own `exec`; the real caller (routes, a later
// task) passes the promisified execFile.
async function createBundle({ host, since = '24h', exec, dir = BUNDLE_DIR } = {}) {
  if (!SINCE_CHOICES.includes(since)) {
    const err = new Error(`since must be one of: ${SINCE_CHOICES.join(', ')}`);
    err.code = 'BAD_SINCE';
    throw err;
  }
  if (host && !isValidHost(host)) {
    const err = new Error('Invalid hostname.');
    err.code = 'BAD_HOST';
    throw err;
  }
  if (inProgress) {
    const err = new Error('A support bundle is already being generated.');
    err.code = 'BUNDLE_IN_PROGRESS';
    throw err;
  }

  inProgress = true;
  try {
    const args = [
      SUPPORT_BUNDLE_SCRIPT,
      '--since', since,
      '--output-dir', dir,
      ...(host ? ['--host', host] : [])
    ];

    let stdout;
    try {
      const result = await exec('bash', args, {
        cwd: HOST_PROJECT_DIR,
        timeout: 600000,
        maxBuffer: 8 * 1024 * 1024
      });
      stdout = result.stdout;
    } catch (err) {
      // Any rejection is fatal by design: support-bundle.sh exits 0 when the
      // bundle was written (individual items may only WARN), 1 when the
      // archive could NOT be written, 2 on a usage error.
      throw new Error(describeExecFailure(err));
    }

    const { path: reportedPath, checks } = parseBundleOutput(stdout);
    const resolvedPath = resolveReportedPath(reportedPath, dir);
    if (!resolvedPath) {
      throw new Error('support-bundle.sh did not report a bundle');
    }

    const { size } = fs.statSync(resolvedPath);
    return { name: path.basename(resolvedPath), sizeBytes: size, checks };
  } finally {
    inProgress = false;
  }
}

// Re-validates a bundle name handed back by the browser (e.g. a download
// link) before touching the filesystem with it. Returns an absolute path or
// null — never throws, so a route can treat null as a plain 404.
function resolveBundle(name, { dir = BUNDLE_DIR } = {}) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) return null;
  // Belt and braces: NAME_RE's character class already forbids '/' and '\',
  // and '..' can only survive inside the host part. Kept so this stays safe
  // even if NAME_RE is loosened later.
  if (name.includes('/') || name.includes('\\') || name.includes('..')) return null;

  return resolveInDir(path.join(dir, name), dir);
}

// Lists previously generated bundles, newest first. Never throws — a
// missing BUNDLE_DIR (no bundle generated yet) is just an empty list.
function listBundles({ dir = BUNDLE_DIR, limit = 10 } = {}) {
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (err) {
    return [];
  }

  return entries
    .filter((name) => NAME_RE.test(name))
    .map((name) => {
      try {
        // lstat, not stat: a symlink (or a directory) that merely has a
        // bundle's name is neither listed nor downloadable.
        const stat = fs.lstatSync(path.join(dir, name));
        if (!stat.isFile()) return null;
        return { name, sizeBytes: stat.size, createdAt: stat.mtime.toISOString(), mtimeMs: stat.mtimeMs };
      } catch (err) {
        return null; // vanished between readdir and stat — skip it
      }
    })
    .filter(Boolean)
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, limit)
    .map(({ name, sizeBytes, createdAt }) => ({ name, sizeBytes, createdAt }));
}

module.exports = {
  BUNDLE_DIR,
  NAME_RE,
  SINCE_CHOICES,
  parseBundleOutput,
  createBundle,
  resolveBundle,
  listBundles,
  isBundleRunning
};
