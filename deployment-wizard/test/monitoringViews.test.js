'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const ejs = require('ejs');

const VIEWS = path.join(__dirname, '..', 'views');

const topbar = { hostname: 'padsign.example.com', version: '3.33/8.40', hasCompletedSetup: true, runActive: false };

const SERVICES = ['nginx', 'ps-server'];
const CHECKS = [
  { id: 'config', label: 'Configuration', description: 'Runs validate-config.sh.' },
  { id: 'keycloak', label: 'Keycloak realm and clients', description: 'Runs verify-keycloak.sh.' }
];

const PAGES = {
  overview: {
    view: 'monitoring-overview.ejs',
    locals: { tab: 'overview', host: 'padsign.example.com' },
    init: 'initMonitoringOverview',
    ids: ['svcTable', 'svcRefresh', 'svcUpdated', 'svcTime', 'statusRerun', 'alertsBody', 'certBody', 'diskBody', 'bufferBody', 'restart-modal', 'restartConfirm', 'sessionExpired']
  },
  logs: {
    view: 'monitoring-logs.ejs',
    locals: { tab: 'logs', host: 'padsign.example.com', services: SERVICES, selected: 'ps-server', TAIL_CHOICES: [200, 1000, 5000] },
    init: 'initMonitoringLogs',
    ids: ['logService', 'logTail', 'logSince', 'logFollow', 'logFilter', 'logErrorsOnly', 'logCopy', 'logDownload', 'logStatus', 'logCounts', 'logView', 'sessionExpired']
  },
  activity: {
    view: 'monitoring-activity.ejs',
    locals: { tab: 'activity', host: 'padsign.example.com' },
    init: 'initMonitoringActivity',
    ids: ['activityTable', 'activityFilters', 'actFrom', 'actTo', 'actCompany', 'actUser', 'actOutcome', 'actCsv', 'actError', 'activitySource', 'actPrev', 'actNext', 'tileToday', 'sessionExpired']
  },
  diagnostics: {
    view: 'monitoring-diagnostics.ejs',
    locals: {
      tab: 'diagnostics',
      host: 'padsign.example.com',
      checks: CHECKS,
      bundles: [{ name: 'padsign-support-host-20260929T100000Z.tar.gz', sizeBytes: 2048, createdAt: '2026-09-29T10:00:00.000Z' }],
      SINCE_CHOICES: ['1h', '6h', '24h', '72h', '168h'],
      bundleRunning: false
    },
    init: 'initMonitoringDiagnostics',
    ids: ['runAll', 'bundleGenerate', 'bundleSince', 'bundleStatus', 'bundleList', 'chk-result-config', 'chk-result-keycloak', 'sessionExpired']
  }
};

const render = (view, locals) => ejs.renderFile(path.join(VIEWS, view), { ...topbar, ...locals });

for (const [name, page] of Object.entries(PAGES)) {
  test(`monitoring view ${name}: tab nav, key ids and no literal "undefined"`, async () => {
    const html = await render(page.view, page.locals);
    assert.match(html, /<nav class="mon-tabs" aria-label="Monitoring">/);
    for (const id of page.ids) {
      assert.match(html, new RegExp(`id="${id}"`), `missing #${id}`);
    }
    assert.doesNotMatch(html, /undefined/);
    assert.match(html, /<script src="\/monitoring\.js"><\/script>/);
    assert.match(html, new RegExp(`${page.init}\\(\\{`));
    assert.match(html, /<h1 class="visually-hidden">Monitoring<\/h1>/);
    assert.match(html, /<title>[^<]+ — Monitoring — PadSign Deployment Wizard<\/title>/);
  });

  test(`monitoring view ${name}: only this tab is marked current`, async () => {
    const html = await render(page.view, page.locals);
    const nav = html.slice(html.indexOf('<nav class="mon-tabs"'), html.indexOf('</nav>', html.indexOf('<nav class="mon-tabs"')));
    assert.equal((nav.match(/aria-current="page"/g) || []).length, 1);
    const hrefs = { overview: '/monitoring', logs: '/monitoring/logs', activity: '/monitoring/activity', diagnostics: '/monitoring/diagnostics' };
    assert.match(nav, new RegExp(`href="${hrefs[name]}" aria-current="page"`));
  });

  test(`monitoring view ${name}: the init payload is valid JSON and cannot close the script tag`, async () => {
    const html = await render(page.view, page.locals);
    const m = new RegExp(`${page.init}\\((\\{[\\s\\S]*?\\})\\);`).exec(html);
    assert.ok(m, 'init call found');
    assert.doesNotThrow(() => JSON.parse(m[1]));
    assert.doesNotMatch(m[1], /</);
  });
}

test('monitoring view overview: the services table has scoped headers and a labelled scroll region', async () => {
  const html = await render(PAGES.overview.view, PAGES.overview.locals);
  const heads = html.match(/<th scope="col"[^>]*>/g) || [];
  assert.equal(heads.length, 9);
  assert.match(html, /<div class="table-wrap" tabindex="0" role="region" aria-labelledby="svc-title">/);
  assert.match(html, /id="svcUpdated" role="status"/);
});

test('monitoring view overview: the four cards start in a busy "Checking…" state with a decorative progress bar', async () => {
  const html = await render(PAGES.overview.view, PAGES.overview.locals);
  for (const id of ['alertsBody', 'certBody', 'diskBody', 'bufferBody']) {
    assert.match(html, new RegExp(
      `<div id="${id}" aria-busy="true">\\s*` +
      '<p class="mon-loading">Checking… this can take up to a minute\\.</p>\\s*' +
      '<div class="mon-progress" aria-hidden="true"></div>\\s*</div>'
    ), `#${id}`);
  }
  assert.doesNotMatch(html, /Body"[^>]*>\s*Loading…/);
});

test('monitoring view overview: the services table can be updated in place (keyed rows, hideable Version column)', async () => {
  const html = await render(PAGES.overview.view, PAGES.overview.locals);
  assert.match(html, /<table class="data-table mon-svc-table" id="svcTable" role="table">/);
  assert.match(html, /<th scope="col" class="col-version" role="columnheader">Version<\/th>/);
  // The placeholder is the one row without a data-service key.
  assert.match(html, /<tr class="mon-empty-row" role="row"><td colspan="9" class="cell-empty" role="cell">Loading…<\/td><\/tr>/);
  const source = fs.readFileSync(path.join(__dirname, '..', 'public', 'monitoring.js'), 'utf8');
  assert.match(source, /setAttribute\('data-service', row\.service\)/);
  for (const label of ['State', 'Health', 'Uptime', 'Restarts', 'Version', 'CPU', 'Memory']) {
    assert.ok(source.includes(`data-label="${label}"`), `data-label="${label}"`);
  }
  // The refresh must never rebuild the whole tbody from the service list.
  assert.doesNotMatch(source, /tbody\.innerHTML = payload\.services/);
  assert.match(source, /diffRows\(/);
  assert.match(source, /changedIndexes\(/);
});

test('monitoring view activity: tiles, table and pager have ids so the page can hide them; the banner stays a status region', async () => {
  const html = await render(PAGES.activity.view, PAGES.activity.locals);
  for (const id of ['actTiles', 'actTableWrap', 'actPager', 'actSummary']) assert.match(html, new RegExp(`id="${id}"`), id);
  assert.match(html, /<div id="activitySource" class="alert alert-warning" role="status" hidden><\/div>/);
  const source = fs.readFileSync(path.join(__dirname, '..', 'public', 'monitoring.js'), 'utf8');
  assert.match(source, /parseActivityParams\(location\.search/);
  assert.match(source, /history\.replaceState\(null, '', activityPageUrl\(/);
});

test('monitoring view logs: the log viewer is focusable and named, the follow button reports its state', async () => {
  const html = await render(PAGES.logs.view, PAGES.logs.locals);
  // A region, not role="log": a log role is a live region and would announce every line.
  assert.match(html, /<pre id="logView" class="log log-viewer" tabindex="0" role="region" aria-label="Log output">/);
  assert.match(html, /id="logReconnect"[^>]*hidden>Reconnect<\/button>/);
  assert.match(html, /id="logFollow" aria-pressed="true"/);
  assert.match(html, /<option value="ps-server" selected>/);
  assert.match(html, /href="\/api\/monitoring\/logs\/download\?service=ps-server&amp;tail=200"/);
  assert.match(html, /<label for="logService">/);
});

test('monitoring view logs: with no services it explains why and disables the picker', async () => {
  const html = await render(PAGES.logs.view, { ...PAGES.logs.locals, services: [], selected: null });
  assert.match(html, /id="logNoServices"/);
  assert.match(html, /<select id="logService" disabled>/);
  assert.doesNotMatch(html, /undefined/);
});

test('monitoring view logs: a compose failure shows its message (escaped) instead of "no services"', async () => {
  const html = await render(PAGES.logs.view, {
    ...PAGES.logs.locals, services: [], selected: null, servicesError: 'docker compose failed: <stat> /srv/x: no such file'
  });
  assert.match(html, /id="logComposeError" role="alert">docker compose failed: &lt;stat&gt; \/srv\/x: no such file</);
  assert.doesNotMatch(html, /id="logNoServices"/);
  assert.doesNotMatch(html, /undefined/);
});

test('monitoring view diagnostics: one card per check and a linked list of existing bundles', async () => {
  const html = await render(PAGES.diagnostics.view, PAGES.diagnostics.locals);
  assert.match(html, /data-check-run="config"/);
  assert.match(html, /data-check-run="keycloak"/);
  assert.match(html, /href="\/api\/monitoring\/support-bundle\/padsign-support-host-20260929T100000Z\.tar\.gz"/);
  assert.match(html, /<option value="24h" selected>Last 24 hours<\/option>/);
  assert.match(html, /<option value="168h">Last 7 days<\/option>/);
  assert.match(html, /2 KiB · 2026-09-29 10:00 UTC/);
});

test('monitoring view diagnostics: an empty bundle list says so', async () => {
  const html = await render(PAGES.diagnostics.view, { ...PAGES.diagnostics.locals, bundles: [] });
  assert.match(html, /id="bundleEmpty"/);
});

test('monitoring view diagnostics: HTML in a check label is escaped', async () => {
  const html = await render(PAGES.diagnostics.view, {
    ...PAGES.diagnostics.locals,
    checks: [{ id: 'x', label: '<img src=x onerror=alert(1)>', description: 'd' }]
  });
  assert.doesNotMatch(html, /<img src=x/);
});

test('monitoring views: no chatty live regions (cards, check results, stat values); status elements carry the summaries', async () => {
  const overview = await render(PAGES.overview.view, PAGES.overview.locals);
  for (const id of ['alertsBody', 'certBody', 'diskBody', 'bufferBody']) {
    assert.doesNotMatch(overview, new RegExp(`id="${id}"[^>]*(role="status"|aria-live)`), id);
  }
  assert.match(overview, /id="statusUpdated" class="hint" role="status"/);
  const diag = await render(PAGES.diagnostics.view, PAGES.diagnostics.locals);
  assert.doesNotMatch(diag, /id="chk-result-config"[^>]*aria-live/);
  assert.doesNotMatch(diag, /id="chk-meta-config"[^>]*role=/);
  assert.match(diag, /id="runAllStatus" role="status"/);
  const activity = await render(PAGES.activity.view, PAGES.activity.locals);
  assert.doesNotMatch(activity, /stat-tile__value[^>]*aria-labelledby/);
});

test('monitoring view overview: the services table sets its table roles explicitly (CSS stacks the cards on phones)', async () => {
  const html = await render(PAGES.overview.view, PAGES.overview.locals);
  assert.match(html, /<thead role="rowgroup">\s*<tr role="row">/);
  assert.match(html, /<tbody role="rowgroup">/);
  assert.equal((html.match(/role="columnheader"/g) || []).length, 9);
  const source = fs.readFileSync(path.join(__dirname, '..', 'public', 'monitoring.js'), 'utf8');
  assert.match(source, /setAttribute\('role', 'row'\)/);
  assert.match(source, /<th scope="row" role="rowheader">/);
  assert.match(source, /<td role="cell" data-label="State">/);
  assert.match(source, /<td class="cell-actions" role="cell">/);
});

test('monitoring view diagnostics: a bundle with an odd size or date still renders ("0 B", no throw)', async () => {
  const html = await render(PAGES.diagnostics.view, {
    ...PAGES.diagnostics.locals,
    bundles: [
      { name: 'zero.tar.gz', sizeBytes: 0, createdAt: 'not a date' },
      { name: 'small.tar.gz', sizeBytes: 300, createdAt: null },
      { name: 'big.tar.gz', sizeBytes: 3 * 1048576, createdAt: '2026-09-29T10:00:00.000Z' },
      { name: 'unknown.tar.gz', sizeBytes: undefined, createdAt: undefined }
    ]
  });
  assert.match(html, /zero\.tar\.gz<\/a>\s*<span class="hint">0 B · <\/span>/);
  assert.match(html, /300 B/);
  assert.doesNotMatch(html, /\b1 KiB/);
  assert.match(html, /3\.0 MiB · 2026-09-29 10:00 UTC/);
  assert.doesNotMatch(html, /Invalid|NaN|undefined/);
});

test('monitoring.js: review fixes stay wired (log stream, downloads, paging, Run all)', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'public', 'monitoring.js'), 'utf8');
  // Logs: generic closed-stream message, Reconnect button + one automatic retry, bfcache restore.
  assert.match(source, /Could not open the log stream - reload the page \(the service may have been removed, or too many Logs tabs are open\)\./);
  assert.match(source, /Reconnecting in 3 seconds/);
  assert.match(source, /setTimeout\(function \(\) \{ connect\(true\); \}, 3000\)/);
  assert.match(source, /addEventListener\('pageshow', function \(ev\) \{\s*if \(ev\.persisted/);
  // Follow off keeps the lines: it must not call connect() (which clears the view).
  const followHandler = /followBtn\.addEventListener\('click', function \(\) \{[\s\S]*?\n  \}\);/.exec(source)[0];
  assert.match(followHandler, /Stopped following\. /);
  assert.match(followHandler, /if \(follow\) \{ connect\(\); return; \}/);
  assert.equal((followHandler.match(/\bconnect\(/g) || []).length, 1, 'only turning Follow ON reconnects');
  // Long lines are cut before they reach the DOM.
  assert.match(source, /var line = truncateLogLine\(rawLine\)/);
  // Downloads never save an error body as a file.
  assert.match(source, /guardDownload\(downloadLink, 'follow'/);
  assert.match(source, /guardDownload\(csvLink, 'blob'/);
  assert.match(source, /bundleList\.addEventListener\('click'/);
  // Signing activity paging uses the applied filters, and stale responses are dropped.
  assert.match(source, /activityPageRequest\(applied, page, pages, -1\)/);
  assert.match(source, /activityPageRequest\(applied, page, pages, \+1\)/);
  assert.match(source, /if \(seq !== reqSeq\) return;/);
  // Run all stops at an expired session.
  assert.match(source, /if \(monIsExpired\(\)\) return null;/);
  // Own-property badge lookup.
  assert.match(source, /Object\.prototype\.hasOwnProperty\.call\(BADGE_FOR, status\)/);
  assert.doesNotMatch(source, /data\.selected/);
});

test('monitoring view restart-progress: the run id is escaped like every other init payload', async () => {
  const html = await render('monitoring-restart-progress.ejs', { service: 'nginx', runId: '</script><b>' });
  assert.doesNotMatch(html, /<\/script><b>/);
  assert.match(html, /runId: "\\u003c\/script>/);
});

test('monitoring view restart-progress: names the service and starts the run progress script', async () => {
  const html = await render('monitoring-restart-progress.ejs', { service: 'nginx', runId: 'run-1' });
  assert.match(html, /<h1>Restarting nginx<\/h1>/);
  assert.match(html, /initRunProgress\(/);
  assert.match(html, /retryRedirect: '\/monitoring\/restart-progress'/);
  assert.match(html, /id="deploySteps"/);
  assert.doesNotMatch(html, /undefined/);
});

test('topbar: both variants link to Monitoring between Dashboard and Settings', async () => {
  for (const variant of [undefined, 'onboarding']) {
    const html = await ejs.renderFile(path.join(VIEWS, 'partials', 'topbar.ejs'), { ...topbar, variant, current: 2 });
    const d = html.indexOf('>Dashboard<');
    const m = html.indexOf('>Monitoring<');
    const s = html.indexOf('>Settings<');
    assert.ok(d > 0 && m > d && s > m, `order in ${variant || 'default'} variant`);
    assert.match(html, /href="\/monitoring"/);
  }
});

test('topbar: Monitoring is current on a monitoring page and locked while a run is active', async () => {
  const current = await ejs.renderFile(path.join(VIEWS, 'partials', 'topbar.ejs'), { ...topbar, activeNav: 'monitoring' });
  assert.match(current, /href="\/monitoring" class="btn btn-outline "\s+aria-current="page"/);
  const locked = await ejs.renderFile(path.join(VIEWS, 'partials', 'topbar.ejs'), { ...topbar, runActive: true });
  assert.match(locked, /href="\/monitoring" class="btn btn-outline is-disabled"\s+ aria-disabled="true"/);
});

test('icons: every Monitoring icon renders geometry (no "undefined" from a missing entry)', async () => {
  const names = ['activity', 'scroll-text', 'pen-line', 'stethoscope', 'refresh-cw', 'rotate-ccw', 'download', 'play', 'pause',
    'search', 'package', 'hard-drive', 'bell', 'inbox', 'server', 'shield-check', 'clipboard-check'];
  for (const name of names) {
    const svg = await ejs.renderFile(path.join(VIEWS, 'partials', 'icon.ejs'), { name });
    assert.match(svg, /<(path|circle|polygon|polyline|line|rect)\b/, name);
    assert.doesNotMatch(svg, /undefined/, name);
  }
});

test('stylesheet: the Monitoring classes the views use are defined', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', 'public', 'styles.css'), 'utf8');
  const monitoring = css.slice(css.indexOf('/* ---------- Monitoring ---------- */'), css.indexOf('/* ---------- 9. Responsive ---------- */'));
  assert.ok(monitoring.length > 500, 'Monitoring section sits before the responsive rules');
  for (const cls of ['.wizard-shell--wide', '.mon-tabs', '.mon-toolbar', '.table-wrap', '.data-table', '.pill-ok', '.pill-warn', '.pill-fail', '.pill-muted',
    '.mon-grid', '.stat-tiles', '.stat-tile__value', '.log-viewer', '.log-line--error', '.log-line--warn', '.event-list']) {
    assert.ok(monitoring.includes(cls), `${cls} defined`);
  }
  // Design tokens only: no raw hex colours other than the two log-line tints
  // (drawn on the dark log background) and the pill/text colours shared with .badge-*.
  // The defects found in the running UI stay fixed. Each is a string check on
  // the rule, so a refactor that drops one fails here.
  const rule = (selector) => {
    const at = monitoring.indexOf(selector + ' {');
    assert.ok(at >= 0, `${selector} rule exists`);
    return monitoring.slice(at, monitoring.indexOf('}', at));
  };
  assert.match(rule('.mon-page .checklist li > :not(.badge)'), /overflow-wrap: anywhere/);
  assert.match(rule('.mon-page .checklist li > :not(.badge)'), /min-width: 0/);
  assert.match(rule('.mon-sample'), /font-family: var\(--font-mono\)/);
  assert.match(rule('.mon-sample'), /overflow-wrap: anywhere/);
  assert.match(rule('.pill'), /overflow-wrap: anywhere/);
  assert.match(rule('.data-table .pill'), /white-space: nowrap/);
  // Filter icon: 16px wide at 12px from the left, so the text starts at >= 38px.
  const padLeft = /padding-left: ([\d.]+)rem/.exec(rule('.mon-toolbar .mon-search input[type="search"]'));
  assert.ok(padLeft && Number(padLeft[1]) * 16 >= 38, 'search input leaves room for its icon');
  // Services table: version folds into the Service cell at <= 1100px, cards at <= 720px.
  assert.match(monitoring, /@media \(max-width: 1100px\) \{[^@]*\.mon-svc-table \.col-version \{ display: none; \}/);
  assert.match(monitoring, /@media \(max-width: 1100px\) \{[^@]*\.mon-svc-table \.svc-version \{ display: block; \}/);
  assert.match(monitoring, /\.mon-svc-table td\[data-label\]::before \{[^}]*content: attr\(data-label\)/);
  assert.match(monitoring, /\.mon-svc-table tbody tr \{\s*display: grid/);
  assert.match(monitoring, /\.mon-svc-table thead \{\s*position: absolute/, 'header row is visually hidden, not display: none');
  assert.match(rule('.mon-svc-table .cell-actions .btn'), /white-space: nowrap/);
  // Loading bar: animated, and static for people who ask for reduced motion.
  assert.match(monitoring, /@keyframes mon-indeterminate/);
  assert.match(monitoring, /@media \(prefers-reduced-motion: reduce\) \{\s*\.mon-progress::after \{ animation: none;/);
  assert.doesNotMatch(monitoring, /var\(--(?!tlx-|color-|font-|fs-|fw-|space-|radius-|shadow-|lh-|field-border|focus|danger|gold-ink)[a-z0-9-]+\)/);
});
