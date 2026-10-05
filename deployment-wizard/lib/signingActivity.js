'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR } = require('./paths');
const { readImageTags } = require('./dockerFacts');

// Turns ps-server's per-line signing audit log (config/config.js AUDIT_LOG,
// ps-server 3.34+) into the "Signing activity" tab: tiles, filters, a paged
// per-document table with an event timeline, and CSV export. Read-only —
// this module never writes to the log or to any deployment file.

const PAGE_SIZE = 50;
const OUTCOME_VALUES = new Set(['completed', 'failed', 'pending']);

// ---------------------------------------------------------------------------
// AUDIT_LOG block in config/config.js
// ---------------------------------------------------------------------------

// Regex-scrapes the AUDIT_LOG block the same way dockerFacts.js's
// readConfiguredFeatures() scrapes DOCUMENT_ROUTING/STAMP_MODE, rather than
// requiring config.js as a module — config.js is a CommonJS file meant to be
// loaded by ps-server, not by the wizard, and requiring an operator-edited
// file we don't control would run arbitrary code in this process.
//
// As with every regex-scraped field in this codebase, this cannot tell a real
// AUDIT_LOG block from one left inside a comment, so a block an operator has
// commented out still reads as present. That is accepted: this only drives a
// read-only view, and a wrong read never rewrites anything.
function readAuditConfig(configJsText) {
  if (typeof configJsText !== 'string') {
    return { present: false, enabled: false, dir: null };
  }

  const blockMatch = configJsText.match(/AUDIT_LOG\s*:\s*\{([\s\S]*?)\}/);
  if (!blockMatch) {
    return { present: false, enabled: false, dir: null };
  }

  const block = blockMatch[1];
  const enabledMatch = block.match(/enabled\s*:\s*(true|false)/);
  const dirMatch = block.match(/dir\s*:\s*["']([^"']+)["']/);

  return {
    present: true,
    enabled: enabledMatch ? enabledMatch[1] === 'true' : false,
    dir: dirMatch ? dirMatch[1] : '/signed-output/.padsign-audit'
  };
}

// ---------------------------------------------------------------------------
// Version comparison (release/capabilities.json minimums)
// ---------------------------------------------------------------------------

// Dotted numeric version compare ('3.9' < '3.10'). Returns null rather than
// throwing/guessing on anything non-numeric — callers treat null as "can't
// tell, don't gate on it" (see resolveAuditSource's unsupported-version check).
function compareTags(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return null;

  const partsA = a.split('.');
  const partsB = b.split('.');
  if (!partsA.every((seg) => /^\d+$/.test(seg)) || !partsB.every((seg) => /^\d+$/.test(seg))) {
    return null;
  }

  const len = Math.max(partsA.length, partsB.length);
  for (let i = 0; i < len; i += 1) {
    const x = Number(partsA[i] || 0);
    const y = Number(partsB[i] || 0);
    if (x !== y) return x > y ? 1 : -1;
  }
  return 0;
}

// ---------------------------------------------------------------------------
// Container path -> host path mapping (docker inspect .Mounts)
// ---------------------------------------------------------------------------

// Path-segment-aware check for whether `target` equals or lies under `base`,
// for POSIX (container-side) paths. Returns the remainder without a leading
// slash (an empty string for an exact match), or null when `target` is not
// under `base`. '/signed' must never match '/signed-output' merely because it
// is a string prefix.
function posixRemainder(base, target) {
  const normBase = path.posix.normalize(base);
  const normTarget = path.posix.normalize(target);
  if (normTarget === normBase) return '';
  const prefix = normBase === '/' ? '/' : `${normBase}/`;
  if (normTarget.startsWith(prefix)) return normTarget.slice(prefix.length);
  return null;
}

// `source` comes verbatim from `docker inspect` — a real Linux host path in
// production (this project only ever deploys to Linux hosts). Plain string
// concatenation rather than path.posix.join()/path.join(): a test may hand
// this a Windows-style temp path as a stand-in Source, and forcing it
// through either path implementation risks normalizing separators it
// doesn't recognize. Trimming a trailing slash before concatenating is
// unambiguous either way.
function joinHostPath(source, remainder) {
  if (!remainder) return source;
  return `${source.replace(/[\\/]+$/, '')}/${remainder}`;
}

// mounts: [{ Source, Destination }, ...] as `docker inspect` reports them.
// Picks the mount whose Destination equals containerDir or is a parent
// directory of it, preferring the longest (most specific) Destination when
// more than one mount qualifies.
function mapContainerPath(containerDir, mounts) {
  if (typeof containerDir !== 'string' || !containerDir || !Array.isArray(mounts)) {
    return null;
  }

  let best = null;
  for (const mount of mounts) {
    if (!mount || typeof mount.Destination !== 'string' || typeof mount.Source !== 'string') continue;
    const remainder = posixRemainder(mount.Destination, containerDir);
    if (remainder === null) continue;
    const destLen = path.posix.normalize(mount.Destination).length;
    if (!best || destLen > best.destLen) {
      best = { destLen, source: mount.Source, remainder };
    }
  }

  if (!best) return null;
  return joinHostPath(best.source, best.remainder);
}

// ---------------------------------------------------------------------------
// resolveAuditSource
// ---------------------------------------------------------------------------

function defaultCapabilities(projectDir) {
  try {
    return JSON.parse(fs.readFileSync(path.join(projectDir, 'release', 'capabilities.json'), 'utf8'));
  } catch (err) {
    return null;
  }
}

const CONFIG_UNREADABLE_MESSAGE =
  'config/config.js could not be read, so the signing activity log settings are unknown.';
const NO_AUDIT_BLOCK_MESSAGE =
  'config/config.js has no AUDIT_LOG block; run an upgrade (Dashboard > Upgrade) to add it, then restart ps-server.';
const DISABLED_MESSAGE =
  'The signing activity log is switched off; set AUDIT_LOG.enabled to true in config/config.js and run docker compose restart ps-server.';
const NO_MOUNT_MESSAGE =
  'ps-server writes the signing activity log inside its container (AUDIT_LOG.dir is not on a mounted volume); keep AUDIT_LOG.dir under /signed-output.';
const MISSING_MESSAGE = 'No signing activity has been recorded yet.';

// hostDir is where the compose model's mount puts AUDIT_LOG.dir on the host.
// Moving AUDIT_LOG.dir cannot help: the directory is already on the mount
// ps-server writes to. What helps is the wizard seeing it, so name the
// exact read-only mount (the wizard container sees the deployment directory
// and what is mounted into it, at the same paths as on the host).
function outsideProjectMessage(hostDir) {
  return `The signing activity log is written to ${hostDir} on the host, which the wizard container cannot read: it sees only the deployment directory. To show it here, mount that directory into the wizard service read-only at the same path ("${hostDir}:${hostDir}:ro" under volumes in a compose override), or read the files on the host (documentation/09-13-signing-activity-log.md).`;
}

// Only reachable when docker inspect could not be used AND AUDIT_LOG.dir is not
// under the default /signed-output mount, so there is no host path to name.
function unmappableDirMessage(containerDir) {
  return `AUDIT_LOG.dir (${containerDir}) is not under /signed-output and ps-server could not be inspected to map it to a host path; keep AUDIT_LOG.dir under /signed-output.`;
}

// Figures out whether the wizard can read the signing audit log at all, and
// if so, the HOST filesystem directory it lives in. config.js's AUDIT_LOG.dir
// is a path INSIDE the ps-server container; this resolves it to wherever it
// actually landed on disk via the bind mounts `docker inspect` reports, since
// an overlay/customised deployment may mount signed-output from somewhere
// other than the release default.
//
// `exec` and `readFile` are injectable so this can be tested without a
// running Docker daemon. Directory existence (the 'missing' status) is checked
// against the real filesystem, deliberately not injected: tests create a real
// temp directory, which is also what the module does at runtime.
async function resolveAuditSource(opts = {}) {
  const {
    exec = execFileP,
    readFile = (p) => fs.readFileSync(p, 'utf8'),
    projectDir = HOST_PROJECT_DIR
  } = opts;

  let configText;
  try {
    configText = readFile(path.join(projectDir, 'config', 'config.js'));
  } catch (err) {
    return { status: 'not-configured', dir: null, message: CONFIG_UNREADABLE_MESSAGE };
  }

  const auditConfig = readAuditConfig(configText);
  if (!auditConfig.present) {
    return { status: 'not-configured', dir: null, message: NO_AUDIT_BLOCK_MESSAGE };
  }
  if (!auditConfig.enabled) {
    return { status: 'disabled', dir: null, message: DISABLED_MESSAGE };
  }

  // Resolved only now: reading release/capabilities.json and docker-compose.yml
  // is wasted work for the far more common not-configured / disabled outcomes.
  // An explicit null from the caller means "known to be unavailable", not
  // "use the default".
  const capabilities = opts.capabilities !== undefined ? opts.capabilities : defaultCapabilities(projectDir);
  const serverTag = opts.serverTag !== undefined ? opts.serverTag : readImageTags().serverTag;

  const minServerTag = capabilities
    && capabilities.capabilities
    && capabilities.capabilities['signing-audit']
    && capabilities.capabilities['signing-audit'].min
    && capabilities.capabilities['signing-audit'].min['ps-server'];

  if (serverTag && minServerTag) {
    const cmp = compareTags(serverTag, minServerTag);
    if (cmp !== null && cmp < 0) {
      return {
        status: 'unsupported-version',
        dir: null,
        message: `ps-server ${serverTag} does not write the signing activity log. Upgrade to ${minServerTag} or newer (Dashboard > Upgrade).`
      };
    }
  }

  let mounts = null;
  try {
    const { stdout } = await exec('docker', ['inspect', '--type', 'container', '--format', '{{json .Mounts}}', 'ps-server'], {
      cwd: projectDir,
      timeout: 10000
    });
    const parsed = JSON.parse(stdout);
    if (Array.isArray(parsed)) mounts = parsed;
  } catch (err) {
    mounts = null;
  }

  let hostDir;
  if (mounts === null) {
    // docker inspect itself gave us nothing usable (daemon unreachable,
    // container not created yet, or output that is not a JSON array). Only in
    // that case guess the release default bind mount
    // (./signed-output:/signed-output); if AUDIT_LOG.dir is not even under
    // /signed-output there is no sane host path to guess.
    const remainder = posixRemainder('/signed-output', auditConfig.dir);
    if (remainder === null) {
      return { status: 'outside-project', dir: null, message: unmappableDirMessage(auditConfig.dir) };
    }
    hostDir = remainder
      ? path.join(projectDir, 'signed-output', ...remainder.split('/'))
      : path.join(projectDir, 'signed-output');
  } else {
    // docker inspect worked, so its Mounts are authoritative. If none covers
    // AUDIT_LOG.dir the log lives only inside the container; falling back to
    // the default mount here would silently report on the wrong directory.
    const mapped = mapContainerPath(auditConfig.dir, mounts);
    if (mapped === null) {
      return { status: 'outside-project', dir: null, message: NO_MOUNT_MESSAGE };
    }
    // mapContainerPath() joins with a literal '/'. On the Linux-only delivery
    // target Source is POSIX too, so this is a no-op there; it only matters
    // when a test supplies a Windows-style Source, giving mixed separators.
    hostDir = path.normalize(mapped);
  }

  // Resolve symlinks (when the path exists) before the containment check, so a
  // link inside the project cannot make an outside directory look contained.
  // A path that does not exist yet cannot be resolved; it is reported as
  // 'missing' below.
  let realHostDir = hostDir;
  try {
    realHostDir = fs.realpathSync(hostDir);
  } catch (err) {
    // not there (yet): compare the path as computed
  }

  // A real deployment's Mounts can legitimately point somewhere outside the
  // project directory (an overlay host mounting signed-output from another
  // disk). When docker inspect named that path and the wizard has it mounted
  // too (read-only, at the same path: documentation/09-13), it is read like
  // any other. Otherwise the wizard container never sees it and the message
  // says which mount to add. A directory only guessed from the project (the
  // docker inspect fallback above) must stay inside the project, so a link
  // there cannot pull in an outside directory.
  const rel = path.relative(projectDir, realHostDir);
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel)) {
    let visible = false;
    if (mounts !== null) {
      try {
        visible = fs.statSync(realHostDir).isDirectory();
      } catch (err) {
        visible = false;
      }
    }
    if (!visible) {
      return { status: 'outside-project', dir: null, message: outsideProjectMessage(realHostDir) };
    }
  }

  let exists = false;
  try {
    exists = fs.statSync(realHostDir).isDirectory();
  } catch (err) {
    exists = false;
  }

  if (!exists) {
    return { status: 'missing', dir: hostDir, message: MISSING_MESSAGE };
  }

  return { status: 'ok', dir: realHostDir, message: '' };
}

// ---------------------------------------------------------------------------
// Date range parsing
// ---------------------------------------------------------------------------

function startOfUtcDay(d) {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 0, 0, 0, 0));
}

function endOfUtcDay(d) {
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), 23, 59, 59, 999));
}

// Strict YYYY-MM-DD (UTC), rejecting anything the calendar doesn't actually
// contain (e.g. 2026-02-30) rather than letting Date's own rollover silently
// produce a different day.
function parseUtcDateOnly(str) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(str).trim());
  if (!m) return null;
  const year = Number(m[1]);
  const month = Number(m[2]);
  const day = Number(m[3]);
  const d = new Date(Date.UTC(year, month - 1, day));
  if (d.getUTCFullYear() !== year || d.getUTCMonth() !== month - 1 || d.getUTCDate() !== day) return null;
  return d;
}

function formatDateOnly(d) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

// query.from/query.to are raw req.query strings (or undefined). Defaults to
// a trailing 30-day window ending today (UTC) — the common "what's happened
// lately" view — and refuses anything that would make readEvents() scan an
// unbounded number of monthly files.
function parseRange({ from, to } = {}, now = new Date()) {
  let toDate;
  if (to !== undefined && to !== null && to !== '') {
    const parsedTo = parseUtcDateOnly(to);
    if (!parsedTo) return { ok: false, error: `Invalid "to" date: ${to}` };
    toDate = endOfUtcDay(parsedTo);
  } else {
    toDate = endOfUtcDay(now);
  }

  let fromDate;
  if (from !== undefined && from !== null && from !== '') {
    const parsedFrom = parseUtcDateOnly(from);
    if (!parsedFrom) return { ok: false, error: `Invalid "from" date: ${from}` };
    fromDate = startOfUtcDay(parsedFrom);
  } else {
    const base = startOfUtcDay(toDate);
    fromDate = new Date(base.getTime() - 29 * 86400000);
  }

  if (fromDate.getTime() > toDate.getTime()) {
    return { ok: false, error: '"from" date must not be after "to" date' };
  }

  const dayCount = Math.round((startOfUtcDay(toDate).getTime() - startOfUtcDay(fromDate).getTime()) / 86400000) + 1;
  if (dayCount > 366) {
    return { ok: false, error: 'Date range must not exceed 366 days' };
  }

  return { ok: true, from: fromDate, to: toDate };
}

// ---------------------------------------------------------------------------
// Reading the JSONL log
// ---------------------------------------------------------------------------

function monthsInRange(from, to) {
  const months = [];
  let y = from.getUTCFullYear();
  let m = from.getUTCMonth();
  const endY = to.getUTCFullYear();
  const endM = to.getUTCMonth();
  while (y < endY || (y === endY && m <= endM)) {
    months.push(`${y}-${String(m + 1).padStart(2, '0')}`);
    m += 1;
    if (m > 11) { m = 0; y += 1; }
  }
  return months;
}

// Keeps only the schema's known fields, coerced to the types the rest of this
// module assumes (string-or-null, number-or-null, boolean). The log is an
// operator-readable file on disk, so a hand-edited or corrupt line must not be
// able to put an object where a string is expected and throw later in
// filtering or CSV export. Returns null when docid/event/outcome — the three
// fields grouping cannot work without — are not non-empty strings.
function normalizeEvent(obj) {
  const required = (v) => typeof v === 'string' && v !== '';
  if (!required(obj.docid) || !required(obj.event) || !required(obj.outcome)) return null;

  const str = (v) => (typeof v === 'string' ? v : null);
  return {
    padsignAudit: 1,
    ts: obj.ts,
    event: obj.event,
    outcome: obj.outcome,
    docid: obj.docid,
    user: str(obj.user),
    userId: str(obj.userId),
    company: str(obj.company),
    documentNumber: str(obj.documentNumber),
    filename: str(obj.filename),
    profile: str(obj.profile),
    mode: str(obj.mode),
    demo: obj.demo === true,
    correlationId: str(obj.correlationId),
    status: typeof obj.status === 'number' ? obj.status : null,
    error: str(obj.error)
  };
}

function readEventsFromFile(filePath, from, to, fsImpl) {
  return new Promise((resolve) => {
    const events = [];
    let skipped = 0;
    let settled = false;

    // Resolve exactly once, however the stream ends.
    const settle = () => {
      if (settled) return;
      settled = true;
      resolve({ events, skipped });
    };

    let stream;
    try {
      stream = fsImpl.createReadStream(filePath);
    } catch (err) {
      skipped += 1;
      settle();
      return;
    }

    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

    // A file removed between readdirSync() and open surfaces as an 'error' on
    // the stream, and readline re-emits it on the Interface. An 'error' event
    // with no listener throws, so both emitters need one or a single bad
    // month file takes the whole process down. The file counts as one skipped
    // unit (so the failure is visible in `skipped`, not silent) and whatever
    // was read before the error is kept.
    const onError = () => {
      skipped += 1;
      rl.close();
      stream.destroy();
      settle();
    };
    stream.on('error', onError);
    rl.on('error', onError);

    rl.on('line', (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;

      let obj;
      try {
        obj = JSON.parse(trimmed);
      } catch (err) {
        skipped += 1;
        return;
      }

      if (!obj || typeof obj !== 'object' || obj.padsignAudit !== 1) {
        skipped += 1;
        return;
      }

      const normalized = normalizeEvent(obj);
      if (!normalized) {
        skipped += 1;
        return;
      }

      const ts = normalized.ts ? new Date(normalized.ts) : null;
      if (!ts || Number.isNaN(ts.getTime())) {
        // A padsignAudit:1 record with no usable timestamp can't be placed
        // in the range or ordered against its siblings — treat it as
        // malformed rather than dropping it silently and uncounted.
        skipped += 1;
        return;
      }

      if (ts.getTime() < from.getTime() || ts.getTime() > to.getTime()) {
        // Well-formed, just outside the requested window: excluded, but not
        // an error, so it does not count against `skipped`.
        return;
      }

      events.push(normalized);
    });

    rl.on('close', settle);
  });
}

// Only opens the monthly files whose YYYY-MM overlaps [from, to] — on a
// deployment with a year of retained logs, a one-week query should not pay
// to stream twelve files just to discard eleven of them.
async function readEvents({ dir, from, to, fsImpl = fs } = {}) {
  if (!dir) return { events: [], skipped: 0 };

  let files;
  try {
    files = fsImpl.readdirSync(dir);
  } catch (err) {
    // Missing/unreadable dir: same "nothing recorded yet" shape as
    // resolveAuditSource's 'missing' status. Degrade rather than throw so
    // callers don't have to duplicate the existence check.
    return { events: [], skipped: 0 };
  }

  const wantedMonths = new Set(monthsInRange(from, to));
  const candidateFiles = files
    .filter((name) => {
      const m = /^audit-(\d{4}-\d{2})\.jsonl$/.exec(name);
      return Boolean(m) && wantedMonths.has(m[1]);
    })
    .filter((name) => {
      // Never try to stream something that is not a regular file (a directory
      // that happens to match the name). This is an optimisation, not the
      // safety net: a file can still vanish after this check, which is what
      // the error handling in readEventsFromFile covers.
      try {
        return fsImpl.lstatSync(path.join(dir, name)).isFile();
      } catch (err) {
        return false;
      }
    })
    .sort();

  const events = [];
  let skipped = 0;
  for (const name of candidateFiles) {
    const result = await readEventsFromFile(path.join(dir, name), from, to, fsImpl);
    // Not events.push(...result.events): spreading a very large array into a
    // call exceeds the engine's argument limit (RangeError) well before a
    // busy month's log runs out.
    for (const event of result.events) events.push(event);
    skipped += result.skipped;
  }

  return { events, skipped };
}

// ---------------------------------------------------------------------------
// Grouping events into per-document history
// ---------------------------------------------------------------------------

function groupByDocument(events) {
  const byDoc = new Map();
  for (const e of events) {
    if (!e || !e.docid) continue;
    if (!byDoc.has(e.docid)) byDoc.set(e.docid, []);
    byDoc.get(e.docid).push(e);
  }

  const docs = [];
  for (const [docid, rawEvents] of byDoc) {
    const evs = rawEvents.slice().sort((a, b) => new Date(a.ts).getTime() - new Date(b.ts).getTime());

    let signature = null;
    let eseal = null;
    let user = null;
    let company = null;
    let documentNumber = null;
    let filename = null;
    let demo = false;
    let outcome = 'pending';

    for (const e of evs) {
      if (e.event === 'signature.visual') signature = e.outcome;
      if (e.event === 'eseal') eseal = e.outcome;

      if (e.event === 'signature.visual' && e.user != null) user = e.user;

      if (company === null && e.company != null) company = e.company;
      if (documentNumber === null && e.documentNumber != null) documentNumber = e.documentNumber;
      if (filename === null && e.filename != null) filename = e.filename;
      if (e.demo === true) demo = true;

      // Outcome state machine — walked strictly in timestamp order so a
      // retry (failed signature, then a later successful one) can move a
      // document from 'failed' back through 'pending' to 'completed'.
      if (e.event === 'signature.visual' && e.outcome === 'failed') outcome = 'failed';
      else if (e.event === 'eseal' && (e.outcome === 'failed' || e.outcome === 'skipped')) outcome = 'failed';
      else if (e.event === 'signing.failed') outcome = 'failed';
      else if (e.event === 'eseal' && e.outcome === 'ok') outcome = 'completed';
      else if (e.event === 'signing.finalized') outcome = 'completed';
      else if (e.event === 'signature.visual' && e.outcome === 'ok') outcome = 'pending';
      // document.registered and anything else: outcome unchanged.
    }

    // `user` prefers the last signature.visual event's user (the loop above
    // already keeps overwriting it as later ones are seen); fall back to the
    // first event carrying a user at all (e.g. a document with no signature
    // event yet, only document.registered).
    if (user == null) {
      for (const e of evs) {
        if (e.user != null) { user = e.user; break; }
      }
    }

    docs.push({
      docid,
      firstTs: evs[0].ts,
      lastTs: evs[evs.length - 1].ts,
      user,
      company,
      documentNumber,
      filename,
      demo,
      signature,
      eseal,
      outcome,
      events: evs
    });
  }

  docs.sort((a, b) => new Date(b.lastTs).getTime() - new Date(a.lastTs).getTime());
  return docs;
}

// ---------------------------------------------------------------------------
// Filtering / summarizing / listing
// ---------------------------------------------------------------------------

function filterDocuments(docs, { company, user, outcome } = {}) {
  return docs.filter((d) => {
    if (company && (!d.company || d.company.toLowerCase() !== company.toLowerCase())) return false;
    if (user && (!d.user || !d.user.toLowerCase().includes(user.toLowerCase()))) return false;
    if (outcome && d.outcome !== outcome) return false;
    return true;
  });
}

// Callers pass every document in the selected date range, not the
// company/user/outcome-filtered subset, so changing a filter never moves the
// tiles: they stay a stable whole-period reference for the table beneath.
function summarize(docs, now = new Date()) {
  const todayStart = startOfUtcDay(now).getTime();
  const todayEnd = endOfUtcDay(now).getTime();
  const sevenStart = todayStart - 6 * 86400000;
  const thirtyStart = todayStart - 29 * 86400000;

  let completedToday = 0;
  let completed7d = 0;
  let completed30d = 0;
  let failed = 0;

  for (const d of docs) {
    const lastTsMs = new Date(d.lastTs).getTime();
    if (d.outcome === 'completed') {
      if (lastTsMs >= todayStart && lastTsMs <= todayEnd) completedToday += 1;
      if (lastTsMs >= sevenStart && lastTsMs <= todayEnd) completed7d += 1;
      if (lastTsMs >= thirtyStart && lastTsMs <= todayEnd) completed30d += 1;
    }
    if (d.outcome === 'failed') failed += 1;
  }

  return { completedToday, completed7d, completed30d, failed };
}

// Spellings that differ only in case ("Acme", "ACME") are the same company as
// far as the company filter is concerned (it matches case-insensitively), so
// they are listed once, under the spelling seen first.
function listCompanies(docs) {
  const seen = new Map();
  for (const d of docs) {
    if (typeof d.company !== 'string') continue;
    const key = d.company.toLowerCase();
    if (!seen.has(key)) seen.set(key, d.company);
  }
  return Array.from(seen.values()).sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }));
}

// ---------------------------------------------------------------------------
// CSV export
// ---------------------------------------------------------------------------

function formatUtcTimestamp(ts) {
  const d = new Date(ts);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
}

// RFC 4180 quoting, plus a leading apostrophe against CSV formula injection
// (a cell starting with = + - @ tab or CR is evaluated as a formula or command
// by Excel/Sheets). toCsv() output is deliberately BOM-free; the HTTP route
// that serves it as a download adds the byte-order mark Excel needs.
function csvCell(value) {
  let s = value === null || value === undefined ? '' : String(value);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  if (/[",\r\n]/.test(s)) s = `"${s.replace(/"/g, '""')}"`;
  return s;
}

function toCsv(docs) {
  const header = ['last_event_utc', 'docid', 'user', 'company', 'document_number', 'filename', 'signature', 'eseal', 'outcome'];
  const lines = [header.join(',')];

  for (const d of docs) {
    const row = [
      formatUtcTimestamp(d.lastTs),
      d.docid,
      d.user,
      d.company,
      d.documentNumber,
      d.filename,
      d.signature,
      d.eseal,
      d.outcome
    ].map(csvCell);
    lines.push(row.join(','));
  }

  return `${lines.join('\r\n')}\r\n`;
}

// ---------------------------------------------------------------------------
// Top-level pipeline
// ---------------------------------------------------------------------------

function resolvePage(rawPage, totalPages) {
  const parsed = Number.parseInt(rawPage, 10);
  let page = Number.isInteger(parsed) && parsed >= 1 ? parsed : 1;
  if (page > totalPages) page = totalPages;
  return page;
}

const EMPTY_SUMMARY = { completedToday: 0, completed7d: 0, completed30d: 0, failed: 0 };

const queryString = (v) => (typeof v === 'string' ? v : '');

// Express's extended query parser turns a repeated or bracketed key
// (?company=A&company=B, ?user[$ne]=x) into an array or object. Every field
// is therefore read as "absent" unless it is a plain string, and an outcome
// that is not one of the three real outcomes is treated as no filter rather
// than a filter that can never match.
function normalizeQuery(query) {
  const q = query || {};
  const outcome = queryString(q.outcome);
  return {
    from: queryString(q.from),
    to: queryString(q.to),
    company: queryString(q.company),
    user: queryString(q.user),
    outcome: OUTCOME_VALUES.has(outcome) ? outcome : '',
    page: queryString(q.page)
  };
}

// Shared by getActivity and getActivityCsv: parse the range, resolve the log
// location, and — if it is readable — read and group every event in range.
// Each caller applies its own filtering (and paging) on top of `allDocs`.
//
// `deps` overrides { resolveAuditSource, fsImpl }, so tests can supply a fixed
// { status, dir, message } instead of mocking docker and config.js each time.
async function loadDocuments(query, now, deps) {
  const resolveSource = (deps && deps.resolveAuditSource) || resolveAuditSource;
  const fsImpl = (deps && deps.fsImpl) || fs;
  const q = normalizeQuery(query);

  const range = parseRange({ from: q.from, to: q.to }, now);
  if (!range.ok) {
    const err = new Error(range.error);
    err.code = 'BAD_RANGE';
    throw err;
  }
  const rangeOut = { from: formatDateOnly(range.from), to: formatDateOnly(range.to) };

  const source = await resolveSource();
  if (source.status !== 'ok') {
    return { source, range: rangeOut, q, allDocs: [], companies: [], summary: { ...EMPTY_SUMMARY }, skipped: 0 };
  }

  const { events, skipped } = await readEvents({ dir: source.dir, from: range.from, to: range.to, fsImpl });
  const allDocs = groupByDocument(events);
  // Companies and tiles describe the whole selected range, not the filtered
  // table, so changing a filter never moves them.
  return { source, range: rangeOut, q, allDocs, companies: listCompanies(allDocs), summary: summarize(allDocs, now), skipped };
}

async function getActivity({ query = {}, now = new Date(), deps = {} } = {}) {
  const { source, range, q, allDocs, companies, summary, skipped } = await loadDocuments(query, now, deps);

  if (source.status !== 'ok') {
    return { source, range, summary, companies, total: 0, page: 1, pageSize: PAGE_SIZE, documents: [], skipped };
  }

  const filtered = filterDocuments(allDocs, { company: q.company, user: q.user, outcome: q.outcome });
  const total = filtered.length;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const page = resolvePage(q.page, totalPages);
  const startIdx = (page - 1) * PAGE_SIZE;
  const documents = filtered.slice(startIdx, startIdx + PAGE_SIZE);

  return { source, range, summary, companies, total, page, pageSize: PAGE_SIZE, documents, skipped };
}

// Same pipeline as getActivity, minus paging/tiles — CSV export is meant to
// carry every filtered document, not just the current page.
async function getActivityCsv({ query = {}, now = new Date(), deps = {} } = {}) {
  const { source, range, q, allDocs } = await loadDocuments(query, now, deps);

  if (source.status !== 'ok') {
    return { csv: toCsv([]), range };
  }

  const filtered = filterDocuments(allDocs, { company: q.company, user: q.user, outcome: q.outcome });
  return { csv: toCsv(filtered), range };
}

module.exports = {
  readAuditConfig,
  compareTags,
  mapContainerPath,
  resolveAuditSource,
  parseRange,
  readEvents,
  groupByDocument,
  filterDocuments,
  summarize,
  listCompanies,
  toCsv,
  getActivity,
  getActivityCsv
};
