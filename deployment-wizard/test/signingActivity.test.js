'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const os = require('os');

const {
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
} = require('../lib/signingActivity');

const FIXTURE_ROOT = path.join(__dirname, 'fixtures', 'monitoring');
const FIXTURE_AUDIT_DIR = path.join(FIXTURE_ROOT, 'audit');
const ENABLED_CONFIG_DIR = path.join(FIXTURE_ROOT, 'audit-config', 'enabled');
const DISABLED_CONFIG_DIR = path.join(FIXTURE_ROOT, 'audit-config', 'disabled');
const ABSENT_CONFIG_DIR = path.join(FIXTURE_ROOT, 'audit-config', 'absent');

const tempDirs = [];
test.after(() => {
  for (const dir of tempDirs) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (err) { /* best effort */ }
  }
});

// os.tmpdir() can be an 8.3 short path on Windows (C:\Users\NAME~1\...), which
// fs.realpathSync expands. Building every temp dir from the resolved base keeps
// paths canonical, so a realpath'd result compares equal to a path.join() one.
const TMP_BASE = fs.realpathSync(os.tmpdir());

function makeTempDir(prefix) {
  const dir = fs.mkdtempSync(path.join(TMP_BASE, prefix));
  tempDirs.push(dir);
  return dir;
}

// Writes one audit JSONL file into a fresh temp dir and returns the dir.
function makeAuditDir(fileName, lines) {
  const dir = makeTempDir('signing-activity-audit-');
  fs.writeFileSync(path.join(dir, fileName), lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))).join('\n') + '\n');
  return dir;
}

const SEPT = { from: new Date('2026-09-01T00:00:00.000Z'), to: new Date('2026-09-30T23:59:59.999Z') };

function auditEvent(overrides) {
  return {
    padsignAudit: 1, ts: '2026-09-05T00:00:00.000Z', event: 'document.registered', outcome: 'ok',
    docid: 'x', user: null, userId: null, company: null, documentNumber: null, filename: null,
    profile: null, mode: null, demo: false, correlationId: null, status: 200, error: null,
    ...overrides
  };
}

// A fresh real temp project dir (config/config.js = the "enabled" fixture)
// for resolveAuditSource cases that need to create/omit a real signed-output
// directory on disk. Never reuses the checked-in fixture dirs for this —
// those must stay pristine in git.
function makeTempProjectDir() {
  const dir = makeTempDir('signing-activity-');
  fs.mkdirSync(path.join(dir, 'config'), { recursive: true });
  fs.copyFileSync(path.join(ENABLED_CONFIG_DIR, 'config', 'config.js'), path.join(dir, 'config', 'config.js'));
  return dir;
}

function makeSpyFs() {
  const createReadStreamCalls = [];
  const readdirSyncCalls = [];
  return {
    readdirSync: (...args) => { readdirSyncCalls.push(args[0]); return fs.readdirSync(...args); },
    lstatSync: (...args) => fs.lstatSync(...args),
    createReadStream: (...args) => { createReadStreamCalls.push(args[0]); return fs.createReadStream(...args); },
    createReadStreamCalls,
    readdirSyncCalls
  };
}

async function loadAllFixtureDocs() {
  const from = new Date('2026-08-01T00:00:00.000Z');
  const to = new Date('2026-09-30T23:59:59.999Z');
  const { events } = await readEvents({ dir: FIXTURE_AUDIT_DIR, from, to });
  return groupByDocument(events);
}

// ---------------------------------------------------------------------------
// readAuditConfig
// ---------------------------------------------------------------------------

test('readAuditConfig: enabled block with explicit dir', () => {
  const cfg = readAuditConfig('module.exports = { AUDIT_LOG: { enabled: true, dir: "/signed-output/.padsign-audit", retentionMonths: 12 } };');
  assert.deepEqual(cfg, { present: true, enabled: true, dir: '/signed-output/.padsign-audit' });
});

test('readAuditConfig: disabled block', () => {
  const cfg = readAuditConfig('module.exports = { AUDIT_LOG: { enabled: false, dir: "/signed-output/.padsign-audit" } };');
  assert.deepEqual(cfg, { present: true, enabled: false, dir: '/signed-output/.padsign-audit' });
});

test('readAuditConfig: no AUDIT_LOG block at all', () => {
  const cfg = readAuditConfig('module.exports = { STAMP_MODE: "external" };');
  assert.deepEqual(cfg, { present: false, enabled: false, dir: null });
});

test('readAuditConfig: dir defaults to /signed-output/.padsign-audit when omitted', () => {
  const cfg = readAuditConfig('module.exports = { AUDIT_LOG: { enabled: true } };');
  assert.equal(cfg.present, true);
  assert.equal(cfg.dir, '/signed-output/.padsign-audit');
});

test('readAuditConfig: non-string input degrades to absent rather than throwing', () => {
  assert.deepEqual(readAuditConfig(undefined), { present: false, enabled: false, dir: null });
});

test('readAuditConfig: against the checked-in fixture config.js variants', () => {
  const enabledText = fs.readFileSync(path.join(ENABLED_CONFIG_DIR, 'config', 'config.js'), 'utf8');
  const disabledText = fs.readFileSync(path.join(DISABLED_CONFIG_DIR, 'config', 'config.js'), 'utf8');
  const absentText = fs.readFileSync(path.join(ABSENT_CONFIG_DIR, 'config', 'config.js'), 'utf8');

  assert.equal(readAuditConfig(enabledText).enabled, true);
  assert.equal(readAuditConfig(disabledText).present, true);
  assert.equal(readAuditConfig(disabledText).enabled, false);
  assert.equal(readAuditConfig(absentText).present, false);
});

// ---------------------------------------------------------------------------
// compareTags
// ---------------------------------------------------------------------------

test('compareTags: newer > older', () => {
  assert.equal(compareTags('3.33', '3.32'), 1);
});

test('compareTags: numeric segment compare, not lexical ("3.9" < "3.10")', () => {
  assert.equal(compareTags('3.9', '3.10'), -1);
});

test('compareTags: equal tags', () => {
  assert.equal(compareTags('3.33', '3.33'), 0);
});

test('compareTags: non-numeric segments -> null', () => {
  assert.equal(compareTags('3.x', '3.10'), null);
  assert.equal(compareTags('abc', '1.0'), null);
  assert.equal(compareTags('3.33', null), null);
});

// ---------------------------------------------------------------------------
// mapContainerPath
// ---------------------------------------------------------------------------

test('mapContainerPath: exact destination match', () => {
  const mounts = [{ Source: '/host/data', Destination: '/signed-output' }];
  assert.equal(mapContainerPath('/signed-output', mounts), '/host/data');
});

test('mapContainerPath: parent destination match appends the remainder', () => {
  const mounts = [{ Source: '/host/data', Destination: '/signed-output' }];
  assert.equal(mapContainerPath('/signed-output/.padsign-audit', mounts), '/host/data/.padsign-audit');
});

test('mapContainerPath: no mount matches -> null', () => {
  const mounts = [{ Source: '/host/other', Destination: '/var/lib/other' }];
  assert.equal(mapContainerPath('/signed-output/.padsign-audit', mounts), null);
});

test('mapContainerPath: longest destination wins', () => {
  const mounts = [
    { Source: '/host/a', Destination: '/signed-output' },
    { Source: '/host/b', Destination: '/signed-output/.padsign-audit' }
  ];
  assert.equal(mapContainerPath('/signed-output/.padsign-audit', mounts), '/host/b');
});

test('mapContainerPath: "/signed" is not a parent of "/signed-output" (path-segment aware)', () => {
  const mounts = [{ Source: '/host/a', Destination: '/signed' }];
  assert.equal(mapContainerPath('/signed-output/.padsign-audit', mounts), null);
});

// ---------------------------------------------------------------------------
// resolveAuditSource
// ---------------------------------------------------------------------------

test('resolveAuditSource: not-configured when config.js has no AUDIT_LOG block', async () => {
  const result = await resolveAuditSource({
    projectDir: ABSENT_CONFIG_DIR,
    exec: async () => { throw new Error('docker must not be called before the config gate'); }
  });
  assert.equal(result.status, 'not-configured');
  assert.equal(result.dir, null);
  assert.equal(
    result.message,
    'config/config.js has no AUDIT_LOG block; run an upgrade (Dashboard > Upgrade) to add it, then restart ps-server.'
  );
});

test('resolveAuditSource: not-configured (with a distinct message) when config.js itself is unreadable', async () => {
  const result = await resolveAuditSource({
    projectDir: path.join(TMP_BASE, 'nonexistent-project-dir-xyz'),
    exec: async () => { throw new Error('docker must not be called'); }
  });
  assert.equal(result.status, 'not-configured');
  assert.equal(
    result.message,
    'config/config.js could not be read, so the signing activity log settings are unknown.'
  );
});

test('resolveAuditSource: disabled when AUDIT_LOG.enabled is false', async () => {
  const result = await resolveAuditSource({
    projectDir: DISABLED_CONFIG_DIR,
    exec: async () => { throw new Error('docker must not be called before the enabled gate'); }
  });
  assert.equal(result.status, 'disabled');
  assert.equal(result.dir, null);
  assert.equal(
    result.message,
    'The signing activity log is switched off; set AUDIT_LOG.enabled to true in config/config.js and run docker compose restart ps-server.'
  );
});

test('resolveAuditSource (M1): default capabilities are read from the injected projectDir', async () => {
  const dir = makeTempProjectDir();
  fs.mkdirSync(path.join(dir, 'release'), { recursive: true });
  fs.writeFileSync(
    path.join(dir, 'release', 'capabilities.json'),
    JSON.stringify({ capabilities: { 'signing-audit': { min: { 'ps-server': '9.99' } } } })
  );

  // `capabilities` deliberately omitted: it must come from <projectDir>/release,
  // not from the process-wide HOST_PROJECT_DIR.
  const result = await resolveAuditSource({
    projectDir: dir,
    serverTag: '1.0',
    exec: async () => { throw new Error('docker must not be called before the version gate'); }
  });
  assert.equal(result.status, 'unsupported-version');
});

test('resolveAuditSource (M4): inspects the ps-server container explicitly', async () => {
  const dir = makeTempProjectDir();
  let seen = null;
  await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async (cmd, args) => { seen = { cmd, args }; return { stdout: '[]' }; }
  });
  assert.equal(seen.cmd, 'docker');
  assert.deepEqual(seen.args, ['inspect', '--type', 'container', '--format', '{{json .Mounts}}', 'ps-server']);
});

test('resolveAuditSource: unsupported-version when serverTag is below the capability minimum', async () => {
  const result = await resolveAuditSource({
    projectDir: ENABLED_CONFIG_DIR,
    capabilities: { capabilities: { 'signing-audit': { min: { 'ps-server': '3.33' } } } },
    serverTag: '3.30',
    exec: async () => { throw new Error('docker must not be called before the version gate'); }
  });
  assert.equal(result.status, 'unsupported-version');
  assert.match(result.message, /3\.30/);
  assert.match(result.message, /3\.33/);
});

test('resolveAuditSource: a serverTag at or above the minimum passes the version gate', async () => {
  const result = await resolveAuditSource({
    projectDir: ENABLED_CONFIG_DIR,
    capabilities: { capabilities: { 'signing-audit': { min: { 'ps-server': '3.33' } } } },
    serverTag: '3.33',
    exec: async () => { throw new Error('docker unreachable in test'); }
  });
  // Past the version gate it falls through to the fallback mount; the
  // checked-in fixture dir has no signed-output/ of its own, so this is a
  // real (and harmless) 'missing' rather than something injected.
  assert.equal(result.status, 'missing');
});

test('resolveAuditSource: docker inspect failure falls back to <projectDir>/signed-output, status ok', async () => {
  const dir = makeTempProjectDir();
  fs.mkdirSync(path.join(dir, 'signed-output', '.padsign-audit'), { recursive: true });

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => { throw new Error('docker not available'); }
  });

  assert.equal(result.status, 'ok');
  assert.equal(result.dir, path.join(dir, 'signed-output', '.padsign-audit'));
  assert.equal(result.message, '');
});

test('resolveAuditSource: fallback mount but nothing signed yet -> missing', async () => {
  const dir = makeTempProjectDir();

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => { throw new Error('docker not available'); }
  });

  assert.equal(result.status, 'missing');
  assert.equal(result.dir, path.join(dir, 'signed-output', '.padsign-audit'));
});

test('resolveAuditSource: ok via a real docker mounts match', async () => {
  const dir = makeTempProjectDir();
  const hostSignedOutput = path.join(dir, 'signed-output');
  fs.mkdirSync(path.join(hostSignedOutput, '.padsign-audit'), { recursive: true });
  const mounts = [{ Source: hostSignedOutput, Destination: '/signed-output' }];

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => ({ stdout: JSON.stringify(mounts) })
  });

  assert.equal(result.status, 'ok');
  assert.equal(result.dir, path.join(hostSignedOutput, '.padsign-audit'));
});

test('resolveAuditSource: outside-project when the mounted host dir is not under projectDir, naming where it is', async () => {
  const dir = makeTempProjectDir();
  const outsideDir = makeTempDir('signing-activity-outside-');
  const mounts = [{ Source: outsideDir, Destination: '/signed-output' }];

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => ({ stdout: JSON.stringify(mounts) })
  });

  assert.equal(result.status, 'outside-project');
  assert.equal(result.dir, null);
  assert.match(result.message, /^The signing activity log is written to /);
  assert.ok(result.message.includes(path.normalize(path.join(outsideDir, '.padsign-audit'))), result.message);
  assert.match(result.message, /outside the deployment directory the wizard can read; keep AUDIT_LOG\.dir under \/signed-output\.$/);
});

test('resolveAuditSource (M5): docker inspect works but no mount covers AUDIT_LOG.dir -> outside-project, no default-mount guess', async () => {
  const dir = makeTempProjectDir();
  // The default ./signed-output exists on disk; the old fallback would have
  // wrongly reported it as 'ok' even though ps-server writes elsewhere.
  fs.mkdirSync(path.join(dir, 'signed-output', '.padsign-audit'), { recursive: true });
  const mounts = [{ Source: '/srv/unrelated', Destination: '/var/unrelated' }];

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => ({ stdout: JSON.stringify(mounts) })
  });

  assert.equal(result.status, 'outside-project');
  assert.equal(result.dir, null);
  assert.equal(
    result.message,
    'ps-server writes the signing activity log inside its container (AUDIT_LOG.dir is not on a mounted volume); keep AUDIT_LOG.dir under /signed-output.'
  );
});

test('resolveAuditSource: docker inspect returning non-JSON is treated as a failed inspect (falls back to the default mount)', async () => {
  const dir = makeTempProjectDir();
  fs.mkdirSync(path.join(dir, 'signed-output', '.padsign-audit'), { recursive: true });

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => ({ stdout: 'Error: No such container: ps-server' })
  });

  assert.equal(result.status, 'ok');
  assert.equal(result.dir, path.join(dir, 'signed-output', '.padsign-audit'));
});

test('resolveAuditSource (M2): a symlink inside the project pointing outside it is outside-project', async (t) => {
  const dir = makeTempProjectDir();
  const outsideDir = makeTempDir('signing-activity-symlink-target-');
  fs.mkdirSync(path.join(outsideDir, '.padsign-audit'));
  try {
    // 'junction' needs no privilege on Windows and is ignored on POSIX.
    fs.symlinkSync(outsideDir, path.join(dir, 'signed-output'), 'junction');
  } catch (err) {
    t.skip(`cannot create a symlink here: ${err.code}`);
    return;
  }

  const result = await resolveAuditSource({
    projectDir: dir,
    capabilities: null,
    serverTag: null,
    exec: async () => { throw new Error('docker not available'); }
  });

  assert.equal(result.status, 'outside-project');
});

test('resolveAuditSource (M3): a sibling directory whose name merely starts with ".." is not treated as outside', async () => {
  const dir = makeTempProjectDir();
  // <projectDir>/..data/audit is inside the project even though its relative
  // path begins with two dots.
  fs.mkdirSync(path.join(dir, '..data', 'audit'), { recursive: true });
  const mounts = [{ Source: path.join(dir, '..data'), Destination: '/signed-output' }];
  const customConfig = 'module.exports = { AUDIT_LOG: { enabled: true, dir: "/signed-output/audit" } };';

  const result = await resolveAuditSource({
    projectDir: dir,
    readFile: () => customConfig,
    capabilities: null,
    serverTag: null,
    exec: async () => ({ stdout: JSON.stringify(mounts) })
  });

  assert.equal(result.status, 'ok');
});

test('resolveAuditSource: outside-project when AUDIT_LOG.dir is not under /signed-output and docker cannot resolve it', async () => {
  const dir = makeTempProjectDir();
  const customConfig = 'module.exports = { AUDIT_LOG: { enabled: true, dir: "/var/lib/other-audit" } };';

  const result = await resolveAuditSource({
    projectDir: dir,
    readFile: () => customConfig,
    capabilities: null,
    serverTag: null,
    exec: async () => { throw new Error('docker unreachable'); }
  });

  assert.equal(result.status, 'outside-project');
  assert.match(result.message, /\/var\/lib\/other-audit/);
  assert.match(result.message, /keep AUDIT_LOG\.dir under \/signed-output\.$/);
});

// ---------------------------------------------------------------------------
// parseRange
// ---------------------------------------------------------------------------

test('parseRange: defaults to a trailing 30-day UTC window ending today', () => {
  const now = new Date('2026-09-29T15:30:00.000Z');
  const r = parseRange({}, now);
  assert.equal(r.ok, true);
  assert.equal(r.from.toISOString(), '2026-08-31T00:00:00.000Z');
  assert.equal(r.to.toISOString(), '2026-09-29T23:59:59.999Z');
});

test('parseRange: "from" given, "to" still defaults to today', () => {
  const now = new Date('2026-09-29T15:30:00.000Z');
  const r = parseRange({ from: '2026-09-01' }, now);
  assert.equal(r.ok, true);
  assert.equal(r.from.toISOString(), '2026-09-01T00:00:00.000Z');
  assert.equal(r.to.toISOString(), '2026-09-29T23:59:59.999Z');
});

test('parseRange: both given, both parsed as UTC day boundaries', () => {
  const r = parseRange({ from: '2026-09-05', to: '2026-09-10' }, new Date());
  assert.equal(r.ok, true);
  assert.equal(r.from.toISOString(), '2026-09-05T00:00:00.000Z');
  assert.equal(r.to.toISOString(), '2026-09-10T23:59:59.999Z');
});

test('parseRange: rejects a malformed date string', () => {
  const r = parseRange({ from: '09/01/2026' }, new Date());
  assert.equal(r.ok, false);
  assert.ok(r.error);
});

test('parseRange: rejects a calendar date that does not exist', () => {
  const r = parseRange({ to: '2026-02-30' }, new Date());
  assert.equal(r.ok, false);
});

test('parseRange: rejects from > to', () => {
  const r = parseRange({ from: '2026-09-20', to: '2026-09-10' }, new Date());
  assert.equal(r.ok, false);
});

test('parseRange: rejects a span over 366 days', () => {
  const r = parseRange({ from: '2025-01-01', to: '2026-09-29' }, new Date());
  assert.equal(r.ok, false);
});

test('parseRange: a 366-day span is allowed', () => {
  const r = parseRange({ from: '2025-09-29', to: '2026-09-29' }, new Date());
  assert.equal(r.ok, true);
});

// ---------------------------------------------------------------------------
// readEvents
// ---------------------------------------------------------------------------

test('readEvents: a September-only range never opens the August file, and counts malformed/non-audit lines as skipped', async () => {
  const spy = makeSpyFs();
  const from = new Date('2026-09-01T00:00:00.000Z');
  const to = new Date('2026-09-30T23:59:59.999Z');

  const { events, skipped } = await readEvents({ dir: FIXTURE_AUDIT_DIR, from, to, fsImpl: spy });

  assert.equal(skipped, 2);
  assert.equal(events.length, 14);
  assert.ok(spy.createReadStreamCalls.some((p) => p.endsWith('audit-2026-09.jsonl')));
  assert.ok(
    !spy.createReadStreamCalls.some((p) => p.endsWith('audit-2026-08.jsonl')),
    'the August file must never be opened for a September-only range'
  );
});

test('readEvents: a range spanning both fixture months reads both files', async () => {
  const from = new Date('2026-08-01T00:00:00.000Z');
  const to = new Date('2026-09-30T23:59:59.999Z');
  const { events, skipped } = await readEvents({ dir: FIXTURE_AUDIT_DIR, from, to });

  assert.equal(skipped, 2);
  assert.equal(events.length, 17); // 14 (Sept) + 3 (Aug, d4's full chain)
});

test('readEvents: a missing directory degrades to empty, not a throw', async () => {
  const missingDir = path.join(os.tmpdir(), `signing-activity-missing-${Date.now()}`);
  const result = await readEvents({ dir: missingDir, from: new Date(0), to: new Date() });
  assert.deepEqual(result, { events: [], skipped: 0 });
});

test('readEvents: no dir -> empty', async () => {
  const result = await readEvents({ dir: null, from: new Date(0), to: new Date() });
  assert.deepEqual(result, { events: [], skipped: 0 });
});

test('readEvents (C1): a DIRECTORY named audit-YYYY-MM.jsonl neither crashes nor yields events', async () => {
  const dir = makeTempDir('signing-activity-c1-');
  fs.mkdirSync(path.join(dir, 'audit-2026-09.jsonl'));
  fs.writeFileSync(path.join(dir, 'audit-2026-08.jsonl'), `${JSON.stringify(auditEvent({ docid: 'aug', ts: '2026-08-20T00:00:00.000Z' }))}\n`);

  const from = new Date('2026-08-01T00:00:00.000Z');
  const { events } = await readEvents({ dir, from, to: SEPT.to });

  // The directory is ignored; the readable month is still read.
  assert.deepEqual(events.map((e) => e.docid), ['aug']);
});

test('readEvents (C1): a stream error on an entry that passed the isFile check settles instead of crashing', async () => {
  const { Readable } = require('stream');
  const fsImpl = {
    readdirSync: () => ['audit-2026-09.jsonl'],
    lstatSync: () => ({ isFile: () => true }),
    // Simulates a file removed between readdirSync and open: the error is
    // emitted asynchronously, after the caller has had a chance to attach.
    createReadStream: () => {
      const s = new Readable({ read() {} });
      setImmediate(() => s.destroy(new Error('ENOENT: removed after listing')));
      return s;
    }
  };

  const result = await readEvents({ dir: 'unused', from: SEPT.from, to: SEPT.to, fsImpl });
  assert.deepEqual(result.events, []);
  assert.equal(result.skipped, 1, 'an unreadable month file is counted as one skipped unit');
});

test('readEvents (C1): only regular files are opened', async () => {
  const spy = makeSpyFs();
  const dir = makeTempDir('signing-activity-c1b-');
  fs.mkdirSync(path.join(dir, 'audit-2026-09.jsonl'));

  await readEvents({ dir, ...SEPT, fsImpl: spy });
  assert.deepEqual(spy.createReadStreamCalls, []);
});

test('readEvents (I1): well over 125k events in one file do not overflow the call stack', async () => {
  const N = 150000;
  const lines = new Array(N);
  for (let i = 0; i < N; i += 1) lines[i] = JSON.stringify(auditEvent({ docid: `bulk-${i}` }));
  const dir = makeAuditDir('audit-2026-09.jsonl', lines);

  const { events, skipped } = await readEvents({ dir, ...SEPT });
  assert.equal(events.length, N);
  assert.equal(skipped, 0);
});

test('readEvents (I2): an object docid is skipped, not grouped', async () => {
  const dir = makeAuditDir('audit-2026-09.jsonl', [auditEvent({ docid: { not: 'a string' } })]);
  const { events, skipped } = await readEvents({ dir, ...SEPT });
  assert.equal(events.length, 0);
  assert.equal(skipped, 1);
});

test('readEvents (I2): a missing or non-string event/outcome is skipped', async () => {
  const dir = makeAuditDir('audit-2026-09.jsonl', [
    auditEvent({ docid: 'a', event: 42 }),
    auditEvent({ docid: 'b', outcome: '' }),
    auditEvent({ docid: 'c', event: undefined })
  ]);
  const { events, skipped } = await readEvents({ dir, ...SEPT });
  assert.equal(events.length, 0);
  assert.equal(skipped, 3);
});

test('readEvents (I2): optional fields are normalised to string-or-null / number-or-null / boolean', async () => {
  const dir = makeAuditDir('audit-2026-09.jsonl', [auditEvent({
    docid: 'n1', user: 12345, userId: {}, company: ['x'], documentNumber: 7, filename: false,
    profile: 1, mode: 2, correlationId: 3, error: { message: 'boom' }, status: '200', demo: 'yes'
  })]);
  const { events } = await readEvents({ dir, ...SEPT });
  assert.equal(events.length, 1);
  const e = events[0];
  for (const k of ['user', 'userId', 'company', 'documentNumber', 'filename', 'profile', 'mode', 'correlationId', 'error', 'status']) {
    assert.equal(e[k], null, `${k} should be null`);
  }
  assert.equal(e.demo, false);
});

test('I2: a non-string user is safe for the user filter', async () => {
  const dir = makeAuditDir('audit-2026-09.jsonl', [auditEvent({ docid: 'u1', user: 12345 })]);
  const { events } = await readEvents({ dir, ...SEPT });
  const docs = groupByDocument(events);
  assert.equal(docs[0].user, null);
  assert.deepEqual(filterDocuments(docs, { user: 'someone' }), []);
});

test('I2: a non-string company is excluded from listCompanies', async () => {
  const dir = makeAuditDir('audit-2026-09.jsonl', [
    auditEvent({ docid: 'c1', company: { not: 'a string' } }),
    auditEvent({ docid: 'c2', company: 'Real Co' })
  ]);
  const { events } = await readEvents({ dir, ...SEPT });
  assert.deepEqual(listCompanies(groupByDocument(events)), ['Real Co']);
});

test('readEvents: a December-to-January range opens both year-crossing month files', async () => {
  const dir = makeTempDir('signing-activity-decjan-');
  fs.writeFileSync(path.join(dir, 'audit-2026-12.jsonl'), `${JSON.stringify(auditEvent({ docid: 'dec', ts: '2026-12-20T00:00:00.000Z' }))}\n`);
  fs.writeFileSync(path.join(dir, 'audit-2027-01.jsonl'), `${JSON.stringify(auditEvent({ docid: 'jan', ts: '2027-01-05T00:00:00.000Z' }))}\n`);
  fs.writeFileSync(path.join(dir, 'audit-2027-02.jsonl'), `${JSON.stringify(auditEvent({ docid: 'feb', ts: '2027-02-05T00:00:00.000Z' }))}\n`);

  const { events } = await readEvents({
    dir, from: new Date('2026-12-15T00:00:00.000Z'), to: new Date('2027-01-10T23:59:59.999Z')
  });
  assert.deepEqual(events.map((e) => e.docid).sort(), ['dec', 'jan']);
});

// ---------------------------------------------------------------------------
// groupByDocument
// ---------------------------------------------------------------------------

test('groupByDocument: outcomes across all six fixture documents', async () => {
  const docs = await loadAllFixtureDocs();
  const byId = Object.fromEntries(docs.map((d) => [d.docid, d]));

  assert.equal(docs.length, 6);

  assert.equal(byId.d1.outcome, 'completed');
  assert.equal(byId.d1.signature, 'ok');
  assert.equal(byId.d1.eseal, 'ok');
  assert.equal(byId.d1.user, 'alice@example.com', 'user of d1 is alice');

  assert.equal(byId.d2.outcome, 'failed');
  assert.equal(byId.d2.signature, 'failed');
  assert.equal(byId.d2.eseal, null);

  assert.equal(byId.d3.outcome, 'pending');
  assert.equal(byId.d3.signature, null);
  assert.equal(byId.d3.eseal, null);
  assert.equal(byId.d3.user, 'carol@example.com', 'falls back to the only event carrying a user');

  assert.equal(byId.d4.outcome, 'completed');
  assert.equal(byId.d4.signature, 'ok');
  assert.equal(byId.d4.eseal, null, 'd4 completes via signing.finalized, never had an eseal event');

  assert.equal(byId.d5.outcome, 'failed');
  assert.equal(byId.d5.signature, 'ok');
  assert.equal(byId.d5.eseal, 'skipped');

  assert.equal(byId.d6.outcome, 'completed', 'a later successful signature retries past an earlier failure');
  assert.equal(byId.d6.signature, 'ok');
  assert.equal(byId.d6.eseal, 'ok');
});

test('groupByDocument: sorted by lastTs descending', async () => {
  const docs = await loadAllFixtureDocs();
  assert.equal(docs[0].docid, 'd6');
  assert.equal(docs[docs.length - 1].docid, 'd4');
  for (let i = 1; i < docs.length; i += 1) {
    assert.ok(new Date(docs[i - 1].lastTs).getTime() >= new Date(docs[i].lastTs).getTime());
  }
});

test('groupByDocument: events without a docid are ignored', () => {
  const docs = groupByDocument([
    { padsignAudit: 1, ts: '2026-09-01T00:00:00.000Z', event: 'document.registered', outcome: 'ok' }
  ]);
  assert.equal(docs.length, 0);
});

// ---------------------------------------------------------------------------
// filterDocuments
// ---------------------------------------------------------------------------

test('filterDocuments: company filter is exact and case-insensitive', async () => {
  const docs = await loadAllFixtureDocs();
  const filtered = filterDocuments(docs, { company: 'acme' });
  assert.deepEqual(filtered.map((d) => d.docid).sort(), ['d1', 'd2']);
});

test('filterDocuments: user filter is a case-insensitive substring match', async () => {
  const docs = await loadAllFixtureDocs();
  const filtered = filterDocuments(docs, { user: 'ALICE' });
  assert.deepEqual(filtered.map((d) => d.docid), ['d1']);
});

test('filterDocuments: outcome filter', async () => {
  const docs = await loadAllFixtureDocs();
  const filtered = filterDocuments(docs, { outcome: 'completed' });
  assert.deepEqual(filtered.map((d) => d.docid).sort(), ['d1', 'd4', 'd6']);
});

test('filterDocuments: empty filters mean no filtering', async () => {
  const docs = await loadAllFixtureDocs();
  assert.equal(filterDocuments(docs, {}).length, docs.length);
  assert.equal(filterDocuments(docs, { company: '', user: '', outcome: '' }).length, docs.length);
});

// ---------------------------------------------------------------------------
// summarize / listCompanies
// ---------------------------------------------------------------------------

test('summarize: tiles over a fixed "now"', async () => {
  const docs = await loadAllFixtureDocs();
  const now = new Date('2026-09-29T12:00:00.000Z');
  const summary = summarize(docs, now);

  assert.deepEqual(summary, { completedToday: 0, completed7d: 1, completed30d: 2, failed: 2 });
});

test('listCompanies: sorted unique non-null companies', async () => {
  const docs = await loadAllFixtureDocs();
  assert.deepEqual(listCompanies(docs), ['ACME', 'Beta Ltd', 'Globex']);
});

// ---------------------------------------------------------------------------
// toCsv
// ---------------------------------------------------------------------------

test('toCsv: header row', () => {
  const csv = toCsv([]);
  assert.equal(csv, 'last_event_utc,docid,user,company,document_number,filename,signature,eseal,outcome\r\n');
});

test('toCsv: quotes a filename containing a comma', () => {
  const csv = toCsv([{
    docid: 'd3', lastTs: '2026-09-15T11:00:00.000Z', user: 'carol@example.com', company: 'Beta Ltd',
    documentNumber: '100777', filename: 'contract, final.pdf', signature: null, eseal: null, outcome: 'pending'
  }]);
  assert.ok(csv.includes('"contract, final.pdf"'));
});

test('toCsv: a documentNumber starting with "=" is prefixed with an apostrophe (formula-injection guard)', () => {
  const csv = toCsv([{
    docid: 'd3', lastTs: '2026-09-15T11:00:00.000Z', user: 'carol@example.com', company: 'Beta Ltd',
    documentNumber: '=100777', filename: 'plain.pdf', signature: null, eseal: null, outcome: 'pending'
  }]);
  const row = csv.split('\r\n')[1];
  assert.ok(row.includes(",'=100777,"), `expected a quote-prefixed =100777 cell, got: ${row}`);
});

test('toCsv: uses CRLF line endings with a trailing CRLF', () => {
  const csv = toCsv([{
    docid: 'd1', lastTs: '2026-09-10T08:06:00.000Z', user: 'alice@example.com', company: 'ACME',
    documentNumber: '100501', filename: 'agreement-d1.pdf', signature: 'ok', eseal: 'ok', outcome: 'completed'
  }]);
  const lines = csv.split('\r\n');
  assert.equal(lines.length, 3); // header + 1 row + trailing empty from the final \r\n
  assert.equal(lines[2], '');
  assert.ok(!csv.includes('\n\n'.replace('\r', '')), 'sanity: no bare LF-only blank lines');
  assert.equal(lines[1], '2026-09-10 08:06:00,d1,alice@example.com,ACME,100501,agreement-d1.pdf,ok,ok,completed');
});

test('toCsv: null fields render as empty cells', () => {
  const csv = toCsv([{
    docid: 'd9', lastTs: '2026-01-01T00:00:00.000Z', user: null, company: null,
    documentNumber: null, filename: null, signature: null, eseal: null, outcome: 'pending'
  }]);
  const row = csv.split('\r\n')[1];
  assert.equal(row, '2026-01-01 00:00:00,d9,,,,,,,pending');
});

test('toCsv: embedded double quotes are doubled and the cell quoted', () => {
  const csv = toCsv([{
    docid: 'd1', lastTs: '2026-09-10T08:06:00.000Z', user: null, company: 'ACME "Group"',
    documentNumber: '1', filename: 'f.pdf', signature: 'ok', eseal: 'ok', outcome: 'completed'
  }]);
  assert.ok(csv.includes('"ACME ""Group"""'));
});

// ---------------------------------------------------------------------------
// getActivity / getActivityCsv
// ---------------------------------------------------------------------------

test('getActivity: paginates at 50 per page', async () => {
  const dir = makeTempDir('signing-activity-page-');

  const lines = [];
  const total = 63;
  for (let i = 0; i < total; i += 1) {
    const docid = `synthetic-${String(i).padStart(3, '0')}`;
    const ts = `2026-09-05T${String(i % 24).padStart(2, '0')}:00:00.000Z`;
    const base = {
      padsignAudit: 1, ts, docid, user: 'page-user@example.com', userId: 'u-page',
      company: 'PageCo', documentNumber: String(1000 + i), filename: `doc-${i}.pdf`,
      profile: 'B', mode: null, demo: false, correlationId: `c-${i}`, status: 200, error: null
    };
    lines.push(JSON.stringify({ ...base, event: 'document.registered', outcome: 'ok' }));
    lines.push(JSON.stringify({ ...base, event: 'signature.visual', outcome: 'ok' }));
    lines.push(JSON.stringify({ ...base, event: 'eseal', outcome: 'ok' }));
  }
  fs.writeFileSync(path.join(dir, 'audit-2026-09.jsonl'), `${lines.join('\n')}\n`);

  const now = new Date('2026-09-29T12:00:00.000Z');
  const deps = { resolveAuditSource: async () => ({ status: 'ok', dir, message: '' }) };

  const page1 = await getActivity({ query: {}, now, deps });
  assert.equal(page1.total, total);
  assert.equal(page1.pageSize, 50);
  assert.equal(page1.page, 1);
  assert.equal(page1.documents.length, 50);

  const page2 = await getActivity({ query: { page: '2' }, now, deps });
  assert.equal(page2.page, 2);
  assert.equal(page2.documents.length, 13);

  const clamped = await getActivity({ query: { page: '99' }, now, deps });
  assert.equal(clamped.page, 2, 'a page beyond the last is clamped to the last page');

  const invalidPage = await getActivity({ query: { page: 'not-a-number' }, now, deps });
  assert.equal(invalidPage.page, 1);

  assert.equal(page1.summary.completed30d, total);
  assert.deepEqual(page1.companies, ['PageCo']);
});

test('getActivity: a non-ok source returns an empty result with the source passed through', async () => {
  const stubSource = { status: 'disabled', dir: null, message: 'The signing activity log is switched off (AUDIT_LOG.enabled is false in config/config.js).' };
  const result = await getActivity({
    query: {},
    now: new Date('2026-09-29T12:00:00.000Z'),
    deps: { resolveAuditSource: async () => stubSource }
  });

  assert.deepEqual(result.source, stubSource);
  assert.deepEqual(result.documents, []);
  assert.equal(result.total, 0);
  assert.equal(result.page, 1);
  assert.equal(result.pageSize, 50);
  assert.deepEqual(result.companies, []);
  assert.deepEqual(result.summary, { completedToday: 0, completed7d: 0, completed30d: 0, failed: 0 });
  assert.equal(result.skipped, 0);
});

test('getActivity: an invalid range rejects with code BAD_RANGE', async () => {
  await assert.rejects(
    () => getActivity({ query: { from: 'not-a-date' }, now: new Date('2026-09-29T12:00:00.000Z') }),
    (err) => {
      assert.equal(err.code, 'BAD_RANGE');
      assert.ok(err.message);
      return true;
    }
  );
});

const FIXTURE_DEPS = { resolveAuditSource: async () => ({ status: 'ok', dir: FIXTURE_AUDIT_DIR, message: '' }) };
const FIXTURE_NOW = new Date('2026-09-29T12:00:00.000Z');
const FIXTURE_RANGE = { from: '2026-08-01', to: '2026-09-30' };

test('getActivity (I3): array and object query values are treated as absent, not thrown on', async () => {
  const baseline = await getActivity({ query: { ...FIXTURE_RANGE }, now: FIXTURE_NOW, deps: FIXTURE_DEPS });
  const result = await getActivity({
    query: {
      from: [FIXTURE_RANGE.from, '2020-01-01'], to: { x: 1 },
      company: ['ACME', 'Globex'], user: { $ne: '' }, outcome: ['completed'], page: ['2']
    },
    now: FIXTURE_NOW,
    deps: FIXTURE_DEPS
  });

  // from/to fell back to the default window; nothing else filtered or paged.
  assert.equal(result.page, 1);
  assert.equal(result.total, result.documents.length);
  assert.ok(result.total > 0);
  assert.ok(result.total <= baseline.total);
});

test('getActivityCsv (I3): array and object query values do not throw', async () => {
  const result = await getActivityCsv({
    query: { from: ['x'], to: {}, company: ['ACME'], user: {}, outcome: ['failed'] },
    now: FIXTURE_NOW,
    deps: FIXTURE_DEPS
  });
  assert.ok(result.csv.startsWith('last_event_utc,'));
});

test('getActivity (I3): an unrecognised outcome value means no outcome filter', async () => {
  const bogus = await getActivity({ query: { ...FIXTURE_RANGE, outcome: 'not-a-real-outcome' }, now: FIXTURE_NOW, deps: FIXTURE_DEPS });
  const none = await getActivity({ query: { ...FIXTURE_RANGE }, now: FIXTURE_NOW, deps: FIXTURE_DEPS });
  assert.equal(bogus.total, none.total);
  assert.ok(none.total > 0);
});

test('getActivity: filtering the table leaves the tiles and the company list unchanged', async () => {
  const all = await getActivity({ query: { ...FIXTURE_RANGE }, now: FIXTURE_NOW, deps: FIXTURE_DEPS });
  const filtered = await getActivity({ query: { ...FIXTURE_RANGE, company: 'ACME', outcome: 'failed' }, now: FIXTURE_NOW, deps: FIXTURE_DEPS });

  assert.ok(filtered.total < all.total);
  assert.deepEqual(filtered.summary, all.summary);
  assert.deepEqual(filtered.companies, all.companies);
});

test('getActivityCsv: BAD_RANGE propagates the same way as getActivity', async () => {
  await assert.rejects(
    () => getActivityCsv({ query: { to: '2026-13-40' }, now: new Date('2026-09-29T12:00:00.000Z') }),
    (err) => {
      assert.equal(err.code, 'BAD_RANGE');
      return true;
    }
  );
});

test('getActivityCsv: exports every filtered document (no paging), driven off the shared fixtures', async () => {
  const deps = { resolveAuditSource: async () => ({ status: 'ok', dir: FIXTURE_AUDIT_DIR, message: '' }) };
  const now = new Date('2026-09-29T12:00:00.000Z');

  const result = await getActivityCsv({
    query: { from: '2026-08-01', to: '2026-09-30', outcome: 'completed' },
    now,
    deps
  });

  const rows = result.csv.trim().split('\r\n');
  assert.equal(rows[0], 'last_event_utc,docid,user,company,document_number,filename,signature,eseal,outcome');
  // completed: d1, d4, d6 - all three, unpaged.
  assert.equal(rows.length, 4);
  assert.deepEqual(result.range, { from: '2026-08-01', to: '2026-09-30' });
});
