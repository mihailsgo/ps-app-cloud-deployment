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
    ids: ['svcTable', 'svcRefresh', 'svcUpdated', 'statusRerun', 'alertsBody', 'certBody', 'diskBody', 'bufferBody', 'restart-modal', 'restartConfirm', 'sessionExpired']
  },
  logs: {
    view: 'monitoring-logs.ejs',
    locals: { tab: 'logs', host: 'padsign.example.com', services: SERVICES, selected: 'ps-server', TAIL_CHOICES: [200, 1000, 5000] },
    init: 'initMonitoringLogs',
    ids: ['logService', 'logTail', 'logSince', 'logFollow', 'logFilter', 'logErrorsOnly', 'logCopy', 'logDownload', 'logStatus', 'logView', 'sessionExpired']
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
  assert.match(html, /id="svcUpdated" class="hint" role="status"/);
});

test('monitoring view logs: the log viewer is focusable and named, the follow button reports its state', async () => {
  const html = await render(PAGES.logs.view, PAGES.logs.locals);
  assert.match(html, /<pre id="logView" class="log log-viewer" tabindex="0" aria-label="Log output">/);
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
  assert.doesNotMatch(monitoring, /var\(--(?!tlx-|color-|font-|fs-|fw-|space-|radius-|shadow-|lh-|field-border|focus|danger|gold-ink)[a-z0-9-]+\)/);
});
