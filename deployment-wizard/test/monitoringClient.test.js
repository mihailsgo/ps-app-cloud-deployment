'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const ejs = require('ejs');

const PUBLIC = path.join(__dirname, '..', 'public');
const VIEWS = path.join(__dirname, '..', 'views');
const COMMON = path.join(PUBLIC, 'monitoring-common.js');
const PAGE_SCRIPT = path.join(PUBLIC, 'monitoring.js');

// The real escapeHtml from wizard-ui.js (a browser script that touches
// `document` on load, so it cannot simply be required).
const uiSource = fs.readFileSync(path.join(PUBLIC, 'wizard-ui.js'), 'utf8');
const escapeSrc = /function escapeHtml\(s\) \{[\s\S]*?\n\}/.exec(uiSource)[0];
globalThis.escapeHtml = vm.runInNewContext(`${escapeSrc}; escapeHtml`);

function loadCommon() {
  delete require.cache[require.resolve(COMMON)];
  return require(COMMON);
}

const c = loadCommon();

// ---------------------------------------------------------------------------
// Formatters
// ---------------------------------------------------------------------------

test('fmtBytes(): B, KiB, MiB, GiB with one decimal; junk is a dash', () => {
  assert.equal(c.fmtBytes(0), '0 B');
  assert.equal(c.fmtBytes(512), '512 B');
  assert.equal(c.fmtBytes(1024), '1.0 KiB');
  assert.equal(c.fmtBytes(1536), '1.5 KiB');
  assert.equal(c.fmtBytes(129394278), '123.4 MiB');
  assert.equal(c.fmtBytes(1610612736), '1.5 GiB');
  assert.equal(c.fmtBytes(null), '–');
  assert.equal(c.fmtBytes(-1), '–');
  assert.equal(c.fmtBytes(NaN), '–');
});

test('fmtDuration(): the two largest units', () => {
  assert.equal(c.fmtDuration(42), '42s');
  assert.equal(c.fmtDuration(60), '1m');
  assert.equal(c.fmtDuration(7 * 60 + 30), '7m');
  assert.equal(c.fmtDuration(5 * 3600 + 12 * 60), '5h 12m');
  assert.equal(c.fmtDuration(3 * 86400 + 4 * 3600 + 59), '3d 4h');
  assert.equal(c.fmtDuration(0), '0s');
  assert.equal(c.fmtDuration(null), '–');
});

test('fmtPct(): one decimal', () => {
  assert.equal(c.fmtPct(12.34), '12.3%');
  assert.equal(c.fmtPct(0), '0.0%');
  assert.equal(c.fmtPct(null), '–');
});

test('fmtTime(): UTC, YYYY-MM-DD HH:MM:SS', () => {
  assert.equal(c.fmtTime('2026-09-29T10:15:02.123Z'), '2026-09-29 10:15:02');
  assert.equal(c.fmtTime('2026-01-05T00:00:00+02:00'), '2026-01-04 22:00:00');
  assert.equal(c.fmtTime('not a date'), '–');
  assert.equal(c.fmtTime(null), '–');
  assert.equal(c.fmtTime(undefined), '–');
});

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

test('statePill()/healthPill(): running and healthy is ok, no health check is not a failure', () => {
  assert.deepEqual(c.statePill({ state: 'running' }), { cls: 'pill-ok', text: 'running', title: '' });
  assert.equal(c.statePill({ state: 'restarting' }).cls, 'pill-warn');
  assert.equal(c.statePill({ state: 'exited' }).cls, 'pill-fail');
  assert.equal(c.statePill({ state: 'missing' }).cls, 'pill-fail');

  assert.equal(c.healthPill({ state: 'running', health: 'healthy' }).cls, 'pill-ok');
  assert.equal(c.healthPill({ state: 'running', health: 'starting' }).cls, 'pill-warn');
  const bad = c.healthPill({ state: 'running', health: 'unhealthy', lastProbe: 'curl: (7) refused' });
  assert.equal(bad.cls, 'pill-fail');
  assert.equal(bad.title, 'curl: (7) refused');
  const none = c.healthPill({ state: 'running', health: 'none' });
  assert.equal(none.cls, 'pill-ok');
  assert.equal(none.text, 'running');
  assert.equal(c.healthPill({ state: 'exited', health: 'none' }).cls, 'pill-muted');
  assert.equal(c.healthPill({ state: 'missing', health: null }).cls, 'pill-muted');
});

test('alertSeverity(): only down/unhealthy are failures, like lib/monitorStatus.js', () => {
  const { alertSeverity } = require('../lib/monitorStatus');
  for (const key of ['service_down', 'service_unhealthy', 'certificate_risk', 'disk_usage', 'stamping_failure', 'anything']) {
    assert.equal(c.alertSeverity(key), alertSeverity(key), key);
  }
});

test('restartImpact(): specific wording for ps-server, keycloak and nginx, a general one otherwise', () => {
  assert.match(c.restartImpact('ps-server'), /interrupts any document being signed/);
  assert.match(c.restartImpact('keycloak'), /sign in again/);
  assert.match(c.restartImpact('nginx'), /unreachable for a few seconds/);
  assert.match(c.restartImpact('dmss-archive-services'), /DMSS services can take several minutes/);
  assert.match(c.restartImpact('constructor'), /DMSS services can take several minutes/);
});

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

test('classifyLogLine(): error, warn and plain lines', () => {
  const table = [
    ['2026-09-29T10:00:00Z INFO started', ''],
    ['2026-09-29T10:00:00Z ERROR could not connect', 'error'],
    ['FATAL: out of memory', 'error'],
    ['SEVERE: something', 'error'],
    ['java.lang.NullPointerException: null', 'error'],
    ['Exception in thread "main"', 'error'],
    ['[error] upstream timed out', 'error'],
    ['time=1 level=error msg=x', 'error'],
    ['WARN slow query', 'warn'],
    ['WARNING deprecated', 'warn'],
    ['[warn] buffer', 'warn'],
    ['ERROR and WARN in one line', 'error'],
    ['terrorism and warnings', ''],
    ['', '']
  ];
  for (const [line, expected] of table) assert.equal(c.classifyLogLine(line), expected, line);
});

test('logStreamUrl()/logDownloadUrl(): since and follow only when set, downloads never follow', () => {
  const base = { service: 'ps-server', tail: 200, since: '', follow: false };
  assert.equal(c.logStreamUrl(base), '/api/monitoring/logs/stream?service=ps-server&tail=200');
  assert.equal(c.logStreamUrl({ ...base, since: '15m', follow: true }), '/api/monitoring/logs/stream?service=ps-server&tail=200&since=15m&follow=1');
  assert.equal(c.logDownloadUrl({ ...base, since: '1h', follow: true }), '/api/monitoring/logs/download?service=ps-server&tail=200&since=1h');
  assert.equal(c.logStreamUrl({ ...base, service: 'a b&c' }), '/api/monitoring/logs/stream?service=a+b%26c&tail=200');
});

test('highlightLine(): escapes first, marks case-insensitive literal matches', () => {
  assert.equal(c.highlightLine('a <b> & "c"', ''), 'a &lt;b&gt; &amp; &quot;c&quot;');
  assert.equal(c.highlightLine('Error: disk ERROR', 'error'), '<mark>Error</mark>: disk <mark>ERROR</mark>');
  assert.equal(c.highlightLine('a.b axb', 'a.b'), '<mark>a.b</mark> axb');
  assert.equal(c.highlightLine('<script>x</script>', 'script'), '&lt;<mark>script</mark>&gt;x&lt;/<mark>script</mark>&gt;');
  assert.equal(c.highlightLine('nothing here', 'zzz'), 'nothing here');
  assert.equal(c.highlightLine('x(y', '('), 'x<mark>(</mark>y');
});

test('logLineVisible(): text filter and errors-only combine', () => {
  assert.equal(c.logLineVisible('GET /health', '', '', false), true);
  assert.equal(c.logLineVisible('GET /health', '', 'HEALTH', false), true);
  assert.equal(c.logLineVisible('GET /health', '', 'login', false), false);
  assert.equal(c.logLineVisible('GET /health', '', '', true), false);
  assert.equal(c.logLineVisible('ERROR login', 'error', 'login', true), true);
  assert.equal(c.logLineVisible('ERROR login', 'error', 'other', true), false);
});

test('nearBottom(): within 40 px of the end counts as at the bottom', () => {
  assert.equal(c.nearBottom(1000, 600, 400), true);
  assert.equal(c.nearBottom(1000, 561, 400), true);
  assert.equal(c.nearBottom(1000, 559, 400), false);
  assert.equal(c.nearBottom(300, 0, 300), true);
});

test('the log viewer keeps at most 10000 lines', () => {
  assert.equal(c.LOG_LINE_CAP, 10000);
});

// ---------------------------------------------------------------------------
// Signing activity
// ---------------------------------------------------------------------------

test('activityDefaults(): to is today (UTC), from is 29 days earlier', () => {
  assert.deepEqual(c.activityDefaults(new Date('2026-09-29T23:59:00Z')), { from: '2026-08-31', to: '2026-09-29' });
  assert.deepEqual(c.activityDefaults(new Date('2026-03-01T00:00:00Z')), { from: '2026-01-31', to: '2026-03-01' });
});

test('activityQuery()/csvHref(): empty filters are omitted, the CSV never carries a page', () => {
  const f = { from: '2026-09-01', to: '2026-09-29', company: '', user: 'ali ce', outcome: 'failed' };
  assert.equal(c.activityQuery(f, 1), 'from=2026-09-01&to=2026-09-29&user=ali+ce&outcome=failed');
  assert.equal(c.activityQuery(f, 3), 'from=2026-09-01&to=2026-09-29&user=ali+ce&outcome=failed&page=3');
  assert.equal(c.csvHref(f), '/api/monitoring/activity.csv?from=2026-09-01&to=2026-09-29&user=ali+ce&outcome=failed');
  assert.equal(c.csvHref({}), '/api/monitoring/activity.csv');
  assert.equal(c.csvHref({ company: 'Ķelmēni & Co' }), '/api/monitoring/activity.csv?company=%C4%B6elm%C4%93ni+%26+Co');
});

test('documentLabel(): number, then file name, then document id', () => {
  assert.equal(c.documentLabel({ documentNumber: '100542', filename: 'a.pdf', docid: 'd1' }), '100542');
  assert.equal(c.documentLabel({ documentNumber: null, filename: 'a.pdf', docid: 'd1' }), 'a.pdf');
  assert.equal(c.documentLabel({ docid: 'd1' }), 'd1');
});

test('resultPill()/eventLabel()/totalPages()', () => {
  assert.deepEqual(c.resultPill('ok'), { cls: 'pill-ok', text: 'OK' });
  assert.equal(c.resultPill('failed').cls, 'pill-fail');
  assert.equal(c.resultPill('skipped').cls, 'pill-warn');
  assert.equal(c.resultPill('completed').text, 'Completed');
  assert.equal(c.resultPill('pending').text, 'Pending');
  assert.equal(c.resultPill(null).cls, 'pill-muted');
  assert.equal(c.eventLabel('signature.visual'), 'Visual signature');
  assert.equal(c.eventLabel('mystery'), 'mystery');
  assert.equal(c.eventLabel('constructor'), 'constructor');
  assert.equal(c.totalPages(0, 50), 1);
  assert.equal(c.totalPages(50, 50), 1);
  assert.equal(c.totalPages(51, 50), 2);
});

test('parseActivityParams(): valid values pre-fill the form, anything else falls back to the defaults', () => {
  const defaults = { from: '2026-08-31', to: '2026-09-29' };
  const full = c.parseActivityParams('?from=2026-09-01&to=2026-09-15&company=Acme+Ltd&user=ali&outcome=failed&page=3', defaults);
  assert.deepEqual(full, { filters: { from: '2026-09-01', to: '2026-09-15', company: 'Acme Ltd', user: 'ali', outcome: 'failed' }, page: 3 });

  const empty = c.parseActivityParams('', defaults);
  assert.deepEqual(empty, { filters: { from: '2026-08-31', to: '2026-09-29', company: '', user: '', outcome: '' }, page: 1 });
  assert.deepEqual(c.parseActivityParams(undefined, defaults), empty);

  // Dates: exactly YYYY-MM-DD and a real calendar day.
  for (const bad of ['2026-9-1', '20260901', '2026-02-30', '2026-13-01', 'yesterday', '2026-09-01T00:00:00Z', '<script>']) {
    const p = c.parseActivityParams('?from=' + encodeURIComponent(bad) + '&to=' + encodeURIComponent(bad), defaults);
    assert.equal(p.filters.from, defaults.from, bad);
    assert.equal(p.filters.to, defaults.to, bad);
  }
  assert.equal(c.parseActivityParams('?from=2024-02-29', defaults).filters.from, '2024-02-29');

  // Outcome is one of the three the form offers; page is a positive integer.
  assert.equal(c.parseActivityParams('?outcome=completed', defaults).filters.outcome, 'completed');
  assert.equal(c.parseActivityParams('?outcome=bogus', defaults).filters.outcome, '');
  for (const bad of ['0', '-2', '1.5', 'abc', '', '99999999999']) {
    assert.equal(c.parseActivityParams('?page=' + bad, defaults).page, 1, bad);
  }
  assert.equal(c.parseActivityParams('?page=12', defaults).page, 12);

  // Free text is trimmed and capped.
  assert.equal(c.parseActivityParams('?user=%20%20bob%20', defaults).filters.user, 'bob');
  assert.equal(c.parseActivityParams('?company=' + 'x'.repeat(500), defaults).filters.company.length, 200);
});

test('activityPageUrl(): the address-bar URL round-trips through parseActivityParams()', () => {
  const defaults = { from: '2026-08-31', to: '2026-09-29' };
  const filters = { from: '2026-09-01', to: '2026-09-15', company: 'Ķelmēni & Co', user: 'ali ce', outcome: 'pending' };
  const url = c.activityPageUrl(filters, 4);
  assert.match(url, /^\/monitoring\/activity\?from=2026-09-01&to=2026-09-15&/);
  assert.deepEqual(c.parseActivityParams(url.slice(url.indexOf('?')), defaults), { filters, page: 4 });
  // No filters and page 1: a clean path, no trailing "?".
  assert.equal(c.activityPageUrl({}, 1), '/monitoring/activity');
  // The CSV link is built from the same filters, so it always matches the address bar.
  const csv = c.csvHref(filters);
  assert.equal(csv.slice(csv.indexOf('?')), url.slice(url.indexOf('?')).replace(/&page=4$/, ''));
});

test('activityLayout(): only a readable log shows tiles, filters and table; a missing one shows the banner and an empty table', () => {
  assert.deepEqual(c.activityLayout('ok'), { banner: false, tiles: true, filters: true, table: true });
  assert.deepEqual(c.activityLayout('missing'), { banner: true, tiles: false, filters: true, table: true });
  for (const status of ['not-configured', 'disabled', 'unsupported-version', 'outside-project', undefined, 'anything']) {
    assert.deepEqual(c.activityLayout(status), { banner: true, tiles: false, filters: false, table: false }, String(status));
  }
});

test('clampPage(): a page number stays within 1..pages', () => {
  assert.equal(c.clampPage(0, 5), 1);
  assert.equal(c.clampPage(-3, 5), 1);
  assert.equal(c.clampPage(3, 5), 3);
  assert.equal(c.clampPage(9, 5), 5);
  assert.equal(c.clampPage(2, 0), 1, 'no pages still means page 1');
  assert.equal(c.clampPage(NaN, 5), 1);
});

test('activityApplyRequest()/activityPageRequest(): paging reuses the APPLIED filters, never what is typed in the form', () => {
  const applied = { from: '2026-09-01', to: '2026-09-29', company: '', user: 'alice', outcome: '' };
  const draft = { ...applied, user: 'bob typed but did not apply', outcome: 'failed' };

  // Apply takes the draft, from page 1.
  const applyReq = c.activityApplyRequest(draft);
  assert.deepEqual(applyReq, { filters: draft, page: 1 });
  applyReq.filters.user = 'mutated';
  assert.equal(draft.user, 'bob typed but did not apply', 'the request holds a copy');

  // Next/Previous take the applied state and move one page; the draft plays no part.
  const next = c.activityPageRequest(applied, 2, 5, +1);
  assert.deepEqual(next, { filters: applied, page: 3 });
  assert.notEqual(next.filters, applied, 'a copy, so later edits cannot leak in');
  assert.deepEqual(c.activityPageRequest(applied, 2, 5, -1), { filters: applied, page: 1 });
  assert.equal(applied.user, 'alice');
});

test('activityPageRequest(): no request when the move would leave the page range', () => {
  const applied = { from: 'a', to: 'b', company: '', user: '', outcome: '' };
  assert.equal(c.activityPageRequest(applied, 1, 5, -1), null);
  assert.equal(c.activityPageRequest(applied, 5, 5, +1), null);
  assert.equal(c.activityPageRequest(applied, 1, 1, +1), null);
  assert.deepEqual(c.activityPageRequest(applied, 4, 5, +1).page, 5);
  // A stale page beyond the range is measured from the last real page.
  assert.equal(c.activityPageRequest(applied, 9, 5, -1).page, 4);
});

// ---------------------------------------------------------------------------
// Log lines and downloads
// ---------------------------------------------------------------------------

test('truncateLogLine(): lines over 16 KiB are cut and say how much was dropped; short lines are untouched', () => {
  assert.equal(c.LOG_LINE_MAX_CHARS, 16384);
  assert.equal(c.truncateLogLine('short'), 'short');
  const exact = 'x'.repeat(16384);
  assert.equal(c.truncateLogLine(exact), exact);
  const long = 'y'.repeat(16384 + 1234);
  const cut = c.truncateLogLine(long);
  assert.equal(cut, 'y'.repeat(16384) + ' … [1234 more characters]');
  assert.ok(cut.length < long.length);
  assert.equal(c.truncateLogLine('z'.repeat(16385)), 'z'.repeat(16384) + ' … [1 more characters]');
  assert.equal(c.truncateLogLine(undefined), '');
});

test('filenameFromDisposition(): the name a download response asks for, else the fallback', () => {
  assert.equal(c.filenameFromDisposition('attachment; filename="padsign-signing-activity-2026-09-01-2026-09-29.csv"', 'x.csv'), 'padsign-signing-activity-2026-09-01-2026-09-29.csv');
  assert.equal(c.filenameFromDisposition('attachment; filename=bundle.tar.gz', 'x'), 'bundle.tar.gz');
  assert.equal(c.filenameFromDisposition("attachment; filename*=UTF-8''a%20b.csv", 'x'), 'a b.csv');
  assert.equal(c.filenameFromDisposition(null, 'fallback.csv'), 'fallback.csv');
  assert.equal(c.filenameFromDisposition('inline', 'fallback.csv'), 'fallback.csv');
  // Never a path: the browser would otherwise be handed "../".
  assert.equal(c.filenameFromDisposition('attachment; filename="../../etc/passwd"', 'f'), 'passwd');
});

// ---------------------------------------------------------------------------
// In-place refresh of the services table
// ---------------------------------------------------------------------------

test('diffRows(): what to add, remove and keep, in the new order', () => {
  assert.deepEqual(c.diffRows(['a', 'b', 'c'], ['b', 'c', 'd']), { add: ['d'], remove: ['a'], keep: ['b', 'c'] });
  assert.deepEqual(c.diffRows([], ['x', 'y']), { add: ['x', 'y'], remove: [], keep: [] });
  assert.deepEqual(c.diffRows(['x', 'y'], []), { add: [], remove: ['x', 'y'], keep: [] });
  assert.deepEqual(c.diffRows(['a', 'b'], ['b', 'a']), { add: [], remove: [], keep: ['b', 'a'] });
  // Service names are data: a prototype name must not look like an existing key.
  assert.deepEqual(c.diffRows([], ['constructor', '__proto__']), { add: ['constructor', '__proto__'], remove: [], keep: [] });
  assert.deepEqual(c.diffRows(['constructor'], ['toString']), { add: ['toString'], remove: ['constructor'], keep: [] });
});

test('changedIndexes(): only cells whose content differs are rewritten', () => {
  assert.deepEqual(c.changedIndexes(['a', 'b', 'c'], ['a', 'x', 'c']), [1]);
  assert.deepEqual(c.changedIndexes(['a', 'b'], ['a', 'b']), []);
  assert.deepEqual(c.changedIndexes([], ['a', 'b']), [0, 1], 'a new row has no previous cells');
  assert.deepEqual(c.changedIndexes(undefined, ['a']), [0]);
});

// ---------------------------------------------------------------------------
// monFetch and session expiry
// ---------------------------------------------------------------------------

function withBrowserStubs(fetchImpl, fn) {
  const banner = { hidden: true };
  const savedFetch = globalThis.fetch;
  const savedDocument = globalThis.document;
  globalThis.fetch = fetchImpl;
  globalThis.document = { getElementById: (id) => (id === 'sessionExpired' ? banner : null) };
  return Promise.resolve(fn(banner)).finally(() => {
    globalThis.fetch = savedFetch;
    globalThis.document = savedDocument;
  });
}

const reply = (status, body) => ({
  status,
  ok: status >= 200 && status < 300,
  json: async () => {
    if (body === undefined) throw new SyntaxError('no body');
    return body;
  }
});

test('monFetch(): sends the session cookie and resolves with the JSON body', async () => {
  const mod = loadCommon();
  let seen;
  await withBrowserStubs(async (url, opts) => { seen = { url, opts }; return reply(200, { a: 1 }); }, async () => {
    assert.deepEqual(await mod.monFetch('/x', { method: 'POST' }), { a: 1 });
    assert.equal(seen.opts.credentials, 'same-origin');
    assert.equal(seen.opts.method, 'POST');
  });
});

test('monFetch(): a 401 shows the banner, runs every stop handler once and rejects as expired', async () => {
  const mod = loadCommon();
  let stops = 0;
  mod.monOnExpire(() => { stops += 1; });
  mod.monOnExpire(() => { throw new Error('one handler failing must not block the others'); });
  mod.monOnExpire(() => { stops += 1; });
  assert.equal(mod.monIsExpired(), false);
  await withBrowserStubs(async () => reply(401, { error: 'unauthorized' }), async (banner) => {
    assert.equal(mod.monIsExpired(), false);
    await assert.rejects(mod.monFetch('/x'), (err) => err.expired === true);
    assert.equal(banner.hidden, false);
    assert.equal(stops, 2);
    assert.equal(mod.monIsExpired(), true, 'pages can ask whether the session is gone (Run all stops its chain on it)');
    await assert.rejects(mod.monFetch('/y'), (err) => err.expired === true);
    assert.equal(stops, 2, 'handlers run once per page, not once per 401');
  });
});

test('monFetch(): a non-2xx answer rejects with the server sentence and status', async () => {
  const mod = loadCommon();
  await withBrowserStubs(async () => reply(409, { error: 'A run is already in progress.' }), async () => {
    await assert.rejects(mod.monFetch('/x'), (err) => err.message === 'A run is already in progress.' && err.status === 409 && !err.expired);
  });
  await withBrowserStubs(async () => reply(502), async () => {
    await assert.rejects(mod.monFetch('/x'), (err) => /HTTP 502/.test(err.message));
  });
});

test('monFetch(): a network failure is one readable sentence', async () => {
  const mod = loadCommon();
  await withBrowserStubs(async () => { throw new TypeError('Failed to fetch'); }, async () => {
    await assert.rejects(mod.monFetch('/x'), /Could not reach the wizard/);
  });
});

test('monJson(): POST with a JSON body', () => {
  const opts = c.monJson({ service: 'nginx' });
  assert.equal(opts.method, 'POST');
  assert.equal(opts.headers['Content-Type'], 'application/json');
  assert.equal(opts.body, '{"service":"nginx"}');
});

// ---------------------------------------------------------------------------
// The page script against the views
// ---------------------------------------------------------------------------

test('monitoring.js and monitoring-common.js load as plain browser scripts and define the four init functions', () => {
  const context = { escapeHtml: globalThis.escapeHtml, console };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(COMMON, 'utf8'), context, { filename: 'monitoring-common.js' });
  vm.runInContext(fs.readFileSync(PAGE_SCRIPT, 'utf8'), context, { filename: 'monitoring.js' });
  for (const name of ['initMonitoringOverview', 'initMonitoringLogs', 'initMonitoringActivity', 'initMonitoringDiagnostics']) {
    assert.equal(typeof context[name], 'function', name);
  }
});

const VIEW_LOCALS = {
  hostname: 'padsign.example.com', version: '3.33/8.40', hasCompletedSetup: true, runActive: false, host: 'padsign.example.com',
  services: ['nginx', 'ps-server'], selected: 'ps-server', TAIL_CHOICES: [200, 1000, 5000],
  checks: [{ id: 'config', label: 'Configuration', description: 'd' }, { id: 'alerts', label: 'Alert thresholds', description: 'd' }],
  bundles: [], SINCE_CHOICES: ['1h', '6h', '24h', '72h', '168h'], bundleRunning: false
};
const PAGES = [
  ['Overview', 'monitoring-overview.ejs', 'overview'],
  ['Logs', 'monitoring-logs.ejs', 'logs'],
  ['Activity', 'monitoring-activity.ejs', 'activity'],
  ['Diagnostics', 'monitoring-diagnostics.ejs', 'diagnostics']
];

// Source of one init function: from its declaration to the next top-level
// declaration (they are separated by banner comments).
function initSource(name) {
  const source = fs.readFileSync(PAGE_SCRIPT, 'utf8');
  const start = source.indexOf(`function initMonitoring${name}(`);
  assert.ok(start >= 0, `initMonitoring${name} exists`);
  const next = source.indexOf('\n// =====', start);
  return source.slice(start, next === -1 ? undefined : next);
}

for (const [name, view, tab] of PAGES) {
  test(`monitoring.js ${name}: every literal element id it looks up exists in the view`, async () => {
    const html = await ejs.renderFile(path.join(VIEWS, view), { ...VIEW_LOCALS, tab });
    const present = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));
    const used = new Set([...initSource(name).matchAll(/byId\('([A-Za-z0-9_-]+)'\)/g)].map((m) => m[1]));
    assert.ok(used.size > 0);
    for (const id of used) assert.ok(present.has(id), `#${id} is used by initMonitoring${name} but not rendered by ${view}`);
  });

  test(`monitoring.js ${name}: reads exactly the keys the view passes in its init payload`, async () => {
    const html = await ejs.renderFile(path.join(VIEWS, view), { ...VIEW_LOCALS, tab });
    const payload = JSON.parse(new RegExp(`initMonitoring${name}\\((\\{[\\s\\S]*?\\})\\);`).exec(html)[1]);
    const read = new Set([...initSource(name).matchAll(/\bdata(?:\s*&&\s*data)?\.(\w+)/g)].map((m) => m[1]));
    assert.deepEqual([...read].sort(), Object.keys(payload).sort());
  });

  test(`${view}: loads the shared helpers before the page script`, async () => {
    const html = await ejs.renderFile(path.join(VIEWS, view), { ...VIEW_LOCALS, tab });
    const common = html.indexOf('<script src="/monitoring-common.js"></script>');
    const page = html.indexOf('<script src="/monitoring.js"></script>');
    const init = html.indexOf(`initMonitoring${name}(`);
    assert.ok(common > 0 && page > common && init > page);
  });
}

test('monitoring.js: attribute selectors it uses match the markup (data-check-run, data-follow)', async () => {
  const diag = await ejs.renderFile(path.join(VIEWS, 'monitoring-diagnostics.ejs'), { ...VIEW_LOCALS, tab: 'diagnostics' });
  assert.match(diag, /data-check-run="config"/);
  const logs = await ejs.renderFile(path.join(VIEWS, 'monitoring-logs.ejs'), { ...VIEW_LOCALS, tab: 'logs' });
  assert.match(logs, /data-follow="on"/);
  assert.match(logs, /data-follow="off" hidden/);
  const source = fs.readFileSync(PAGE_SCRIPT, 'utf8');
  assert.match(source, /\[data-check-run\]/);
  assert.match(source, /\[data-follow\]/);
});

test('monitoring.js: no unescaped interpolation into HTML strings (spot check of the risky sinks)', () => {
  const source = fs.readFileSync(PAGE_SCRIPT, 'utf8');
  // Every innerHTML/insertAdjacentHTML assignment must be fed by an *Html()
  // builder, a literal, or highlightLine(); never by a raw variable.
  const sinks = [...source.matchAll(/(?:innerHTML\s*=|insertAdjacentHTML\([^,]+,)\s*([^;\n]+)/g)].map((m) => m[1].trim());
  assert.ok(sinks.length > 5);
  for (const rhs of sinks) {
    assert.match(rhs, /Html\(|Markup$|'<|"<|highlightLine\(|\.map\(|\.join\(|checklist\(|rowsHtml\(|items \|\||^''$/, rhs);
  }
});
