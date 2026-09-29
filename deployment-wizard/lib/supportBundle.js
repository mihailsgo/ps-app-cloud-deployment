'use strict';

const fs = require('fs');
const path = require('path');

const { HOST_PROJECT_DIR, projectPath } = require('./paths');
const { parseHelperCheckOutput } = require('./outputParser');

const BUNDLE_DIR = projectPath('support-bundles');
const SUPPORT_BUNDLE_SCRIPT = projectPath('installation-scripts', 'support-bundle.sh');

// Matches exactly what support-bundle.sh names its output:
// padsign-support-<host>-<YYYYMMDDTHHMMSSZ>.tar.gz. Deliberately strict — see
// module-level note below on why.
const NAME_RE = /^padsign-support-[A-Za-z0-9.-]+-\d{8}T\d{6}Z\.tar\.gz$/;

const SINCE_CHOICES = ['1h', '6h', '24h', '72h', '168h'];

// One bundle generation at a time. This is its own flag rather than
// scriptRunner.js's run lock: support-bundle.sh is read-only diagnostics, not
// a mutating deploy/upgrade run, so it must not fight over (or be blocked by)
// scriptRunner's lock, but two bundles writing into BUNDLE_DIR concurrently
// is still worth serializing.
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
  return { path: bundlePath, checks: parseHelperCheckOutput(text).checks };
}

// Picks the clearest single line to surface when exec() itself rejects
// (bad args, timeout, missing script): an explicit ERROR: line from stderr
// if the script printed one, else the last non-empty stderr line, else the
// raw Error's own message.
function describeExecFailure(err) {
  const stderrLines = String((err && err.stderr) || '')
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  const explicit = stderrLines.find((l) => l.startsWith('ERROR:'));
  if (explicit) return explicit;
  if (stderrLines.length) return stderrLines[stderrLines.length - 1];
  return (err && err.message) || 'support-bundle.sh failed';
}

// The download route hands whatever this resolves to straight to a browser,
// so a script that reports a path outside its own --output-dir (or a name
// shaped to smuggle a traversal) must never be trusted. Requires the
// basename to match NAME_RE AND the real, existing file to live directly
// inside the real path of `dir` — both checks, not just the regex, since a
// symlink inside `dir` could otherwise point anywhere.
function resolveReportedPath(reportedPath, dir) {
  if (!reportedPath) return null;
  const basename = path.basename(reportedPath);
  if (!NAME_RE.test(basename)) return null;

  let resolvedDir;
  let resolvedPath;
  try {
    resolvedDir = fs.realpathSync(dir);
    resolvedPath = fs.realpathSync(reportedPath);
  } catch (err) {
    return null;
  }

  const rel = path.relative(resolvedDir, resolvedPath);
  if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return null;
  return resolvedPath;
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
  if (name.includes('/') || name.includes('\\') || name.includes('..')) return null;

  const candidate = path.join(dir, name);
  if (!fs.existsSync(candidate)) return null;

  try {
    const resolvedDir = fs.realpathSync(dir);
    const resolvedCandidate = fs.realpathSync(candidate);
    const rel = path.relative(resolvedDir, resolvedCandidate);
    if (rel === '' || rel.startsWith('..') || path.isAbsolute(rel)) return null;
    return resolvedCandidate;
  } catch (err) {
    return null;
  }
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
        const stat = fs.statSync(path.join(dir, name));
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
