'use strict';

// The overlay rule (lib/overlayGuard.js): on a checkout with
// .overlay-applied.json every wizard route that rewrites the checkout answers
// 409 before its handler, and nothing is spawned; without the marker the
// same requests behave as before.
//
// The routes are the real ones, against a temporary project directory, with
// child_process stubbed so that "nothing spawned" is observable and no real
// script ever runs. Both have to be in place before any wizard module loads
// (paths.js reads HOST_PROJECT_DIR once; scriptRunner/certValidator
// destructure spawn/execFile at require time), and node --test runs each
// file in its own process.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const util = require('util');
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');
const childProcess = require('child_process');

const PROJECT = fs.mkdtempSync(path.join(os.tmpdir(), 'wizard-overlay-'));
process.env.HOST_PROJECT_DIR = PROJECT;

const spawned = [];
const execed = [];
childProcess.spawn = (cmd, args) => {
  spawned.push({ cmd, script: path.basename(String(args[0] || '')), args: args.slice(1) });
  const proc = new EventEmitter();
  proc.stdout = new PassThrough();
  proc.stderr = new PassThrough();
  setImmediate(() => {
    proc.stdout.end();
    proc.stderr.end();
    proc.emit('close', 0);
  });
  return proc;
};
function fakeExecFile(cmd, args, opts, cb) {
  execed.push({ cmd, args });
  const done = typeof opts === 'function' ? opts : cb;
  if (done) setImmediate(() => done(new Error('execFile is stubbed in this test')));
}
fakeExecFile[util.promisify.custom] = (cmd, args) => {
  execed.push({ cmd, args });
  return Promise.reject(new Error('execFile is stubbed in this test'));
};
childProcess.execFile = fakeExecFile;

const express = require('express');
const {
  OVERLAY_MARKER,
  OVERLAY_DOC,
  WRITE_ROUTES,
  readOverlayState,
  isOverlayManaged,
  isWriteScript,
  createOverlayGuard
} = require('../lib/overlayGuard');
const scriptRunner = require('../lib/scriptRunner');
const { savePlan } = require('../lib/planStore');
const { createApp } = require('../app');

const HOST = 'padsign.example.com';
const NEW_HOST = 'padsign2.example.com';
const SESSION_ID = 'overlay-test-session';
const MARKER = path.join(PROJECT, OVERLAY_MARKER);
const STAGED = path.join(PROJECT, 'installation-scripts', 'certs');

// A project in which every write route would get as far as spawning its
// script: a configured hostname, and certificates staged for it and for the
// new hostname.
fs.mkdirSync(path.join(PROJECT, 'nginx'), { recursive: true });
fs.writeFileSync(path.join(PROJECT, 'nginx', 'nginx.conf'), `server { server_name ${HOST}; }\n`);
fs.mkdirSync(STAGED, { recursive: true });
for (const h of [HOST, NEW_HOST]) {
  fs.writeFileSync(path.join(STAGED, `${h}.crt`), 'crt');
  fs.writeFileSync(path.join(STAGED, `${h}.key`), 'key');
}

function setOverlay(present, content = JSON.stringify({ overlay_dir: '/etc/padsign/overlay/20260101-initial' })) {
  if (present) fs.writeFileSync(MARKER, content);
  else fs.rmSync(MARKER, { force: true });
}

// The real routers behind the real guard. app.js's session, auth and
// same-origin layers are replaced by a fixed, authenticated session with a
// completed onboarding (so POST /api/deploy would start bootstrap.sh);
// guardIsMountedBeforeEveryRouter below checks app.js wires the guard itself.
function makeApp() {
  const session = {
    authenticated: true,
    wizard: {
      host: HOST,
      companyRole: 'Example',
      adminUser: 'admin',
      adminPass: 'example-password',
      realm: 'padsign',
      features: {},
      cert: { validated: true },
      allowSelfSigned: false,
      furthestStepReached: 5
    }
  };
  const app = express();
  app.set('view engine', 'ejs');
  app.set('views', path.join(__dirname, '..', 'views'));
  app.use(express.json());
  app.use((req, res, next) => {
    req.session = session;
    req.sessionID = SESSION_ID;
    next();
  });
  app.use(createOverlayGuard());
  for (const r of ['certRoutes', 'deploy', 'upgradeRoutes', 'settingsRoutes', 'wizardSteps']) {
    app.use(require(`../routes/${r}`));
  }
  return app;
}

let server;
let baseUrl;
test.before(async () => {
  server = http.createServer(makeApp());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});
test.after(() => {
  server.close();
  fs.rmSync(PROJECT, { recursive: true, force: true });
});

function post(urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify(body || {});
    const req = http.request(`${baseUrl}${urlPath}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
    }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch (err) { /* not JSON */ }
        resolve({ status: res.statusCode, json });
      });
    });
    req.on('error', reject);
    req.end(payload);
  });
}

// Each write route with a body its handler would accept.
function writeRequests() {
  return [
    ['/api/deploy', { mode: 'bootstrap' }],
    ['/api/wizard/cert-upload', { crtText: 'crt', keyText: 'key' }],
    ['/api/upgrade/plan', { serverTag: '9.99' }],
    ['/api/upgrade/apply', { previewId: savePlan({ plan: { pendingCount: 0 }, args: ['--server-tag', '9.99'], sessionId: SESSION_ID }) }],
    ['/api/settings/hostname/cert-upload', { newHost: NEW_HOST, crtText: 'crt', keyText: 'key' }],
    ['/api/settings/hostname', { newHost: NEW_HOST, adminPass: 'example-password' }],
    ['/api/settings/cert/upload', { crtText: 'crt', keyText: 'key' }],
    ['/api/settings/cert/renew', {}],
    ['/api/settings/features/toggle', { demo: true }]
  ];
}

async function untilIdle() {
  while (scriptRunner.isRunActive()) await new Promise((r) => setImmediate(r));
}

function stagedListing() {
  return fs.readdirSync(STAGED).sort().join(',');
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

test('readOverlayState(): null without the marker; the overlay directory from it when present', () => {
  setOverlay(false);
  assert.equal(readOverlayState(), null);
  assert.equal(isOverlayManaged(), false);
  setOverlay(true);
  assert.deepEqual(readOverlayState(), { overlayDir: '/etc/padsign/overlay/20260101-initial' });
  assert.equal(isOverlayManaged(), true);
});

test('readOverlayState(): an unparseable marker still marks the host as overlay-managed', () => {
  setOverlay(true, 'not json');
  assert.deepEqual(readOverlayState(), { overlayDir: null });
  setOverlay(false);
});

test('isWriteScript(): the scripts that rewrite the checkout, not restart-service.sh', () => {
  for (const s of ['bootstrap.sh', 'upgrade.sh', 'rollback.sh', 'update-hostname.sh', 'renew-cert.sh', 'toggle-features.sh']) {
    assert.equal(isWriteScript(s), true, s);
  }
  assert.equal(isWriteScript('restart-service.sh'), false);
  assert.equal(isWriteScript(undefined), false);
});

test('every write route the routers define is in WRITE_ROUTES, and every entry is tested here', () => {
  assert.deepEqual(writeRequests().map(([p]) => p).sort(), Array.from(WRITE_ROUTES).sort());
});

test('app.js mounts the overlay guard before every router', () => {
  const stack = createApp()._router.stack;
  const guard = stack.findIndex((l) => l.name === 'overlayGuard');
  const firstRouter = stack.findIndex((l) => l.name === 'router');
  assert.ok(guard !== -1, 'overlayGuard is mounted');
  assert.ok(guard < firstRouter, 'overlayGuard comes before the first router');
});

// ---------------------------------------------------------------------------
// Overlay present: refused, nothing spawned, nothing staged
// ---------------------------------------------------------------------------

test('overlay present: every write route answers 409 OVERLAY_MANAGED pointing to 9.11, and nothing runs', async () => {
  setOverlay(true);
  const before = stagedListing();
  spawned.length = 0;
  execed.length = 0;
  for (const [urlPath, body] of writeRequests()) {
    const res = await post(urlPath, body);
    assert.equal(res.status, 409, urlPath);
    assert.equal(res.json.code, 'OVERLAY_MANAGED', urlPath);
    assert.equal(res.json.documentation, OVERLAY_DOC, urlPath);
    assert.match(res.json.error, /overlay-managed/, urlPath);
    assert.match(res.json.error, /09-11-start-at-boot-backups-and-customized-hosts\.md/, urlPath);
  }
  assert.deepEqual(spawned, [], 'no script spawned');
  assert.deepEqual(execed, [], 'nothing executed (no plan, no certificate validation)');
  assert.equal(stagedListing(), before, 'no certificate staged');
  setOverlay(false);
});

test('overlay present: retrying a finished write run is refused, a restart run can be retried', async () => {
  setOverlay(false);
  const toggle = await post('/api/settings/features/toggle', { demo: true });
  assert.equal(toggle.status, 200);
  await untilIdle();
  const restartRun = scriptRunner.startRun({ scriptName: 'restart-service.sh', args: ['--service', 'nginx'] });
  await untilIdle();

  setOverlay(true);
  spawned.length = 0;
  const refused = await post('/api/deploy/retry', { runId: toggle.json.runId });
  assert.equal(refused.status, 409);
  assert.equal(refused.json.code, 'OVERLAY_MANAGED');
  assert.deepEqual(spawned, []);

  const allowed = await post('/api/deploy/retry', { runId: restartRun });
  assert.equal(allowed.status, 200);
  assert.deepEqual(spawned.map((s) => s.script), ['restart-service.sh']);
  await untilIdle();
  setOverlay(false);
});

test('overlay present: startRun() itself refuses the write scripts, and allows restart-service.sh', async () => {
  setOverlay(true);
  spawned.length = 0;
  for (const scriptName of ['bootstrap.sh', 'upgrade.sh', 'rollback.sh', 'update-hostname.sh', 'renew-cert.sh', 'toggle-features.sh']) {
    assert.throws(() => scriptRunner.startRun({ scriptName, args: [] }), { code: 'OVERLAY_MANAGED' }, scriptName);
  }
  assert.deepEqual(spawned, []);
  scriptRunner.startRun({ scriptName: 'restart-service.sh', args: ['--service', 'nginx'] });
  assert.deepEqual(spawned.map((s) => s.script), ['restart-service.sh']);
  await untilIdle();
  setOverlay(false);
});

test('overlay present: read-only requests still pass the guard', async () => {
  setOverlay(true);
  const seen = [];
  const guard = createOverlayGuard();
  for (const [method, p] of [['GET', '/settings'], ['GET', '/dashboard'], ['GET', '/api/deploy/status'], ['POST', '/api/monitoring/restart'], ['POST', '/api/monitoring/support-bundle']]) {
    const res = { locals: {}, status() { throw new Error(`${method} ${p} was refused`); } };
    guard({ method, path: p, body: {} }, res, () => seen.push(p));
    assert.deepEqual(res.locals.overlay, { overlayDir: '/etc/padsign/overlay/20260101-initial' });
  }
  assert.equal(seen.length, 5);
  setOverlay(false);
});

// ---------------------------------------------------------------------------
// Overlay absent: unchanged
// ---------------------------------------------------------------------------

test('overlay absent: the guard passes everything through and sets res.locals.overlay to null', () => {
  setOverlay(false);
  const guard = createOverlayGuard();
  for (const p of WRITE_ROUTES) {
    const res = { locals: {}, status() { throw new Error(`${p} was refused`); } };
    let passed = false;
    guard({ method: 'POST', path: p, body: {} }, res, () => { passed = true; });
    assert.equal(passed, true, p);
    assert.equal(res.locals.overlay, null);
  }
});

test('overlay absent: the write routes start their scripts as before', async () => {
  setOverlay(false);
  const cases = [
    ['/api/deploy', { mode: 'bootstrap' }, 'bootstrap.sh'],
    ['/api/settings/hostname', { newHost: NEW_HOST, adminPass: 'example-password' }, 'update-hostname.sh'],
    ['/api/settings/cert/renew', {}, 'renew-cert.sh'],
    ['/api/settings/features/toggle', { demo: true }, 'toggle-features.sh']
  ];
  for (const [urlPath, body, script] of cases) {
    spawned.length = 0;
    const res = await post(urlPath, body);
    assert.equal(res.status, 200, urlPath);
    assert.ok(res.json.runId, urlPath);
    assert.deepEqual(spawned.map((s) => s.script), [script], urlPath);
    await untilIdle();
  }

  spawned.length = 0;
  const previewId = savePlan({ plan: { pendingCount: 0 }, args: ['--server-tag', '9.99'], sessionId: SESSION_ID });
  const apply = await post('/api/upgrade/apply', { previewId });
  assert.equal(apply.status, 200);
  assert.deepEqual(spawned.map((s) => s.script), ['upgrade.sh']);
  await untilIdle();
});

test('overlay absent: the routes\' own validation answers are unchanged', async () => {
  setOverlay(false);
  assert.deepEqual(await post('/api/deploy', { mode: 'upgrade' }), {
    status: 400,
    json: { error: 'Upgrades must go through the preview step — POST /api/upgrade/plan instead.' }
  });
  assert.deepEqual(await post('/api/upgrade/plan', {}), {
    status: 400,
    json: { error: 'Provide at least one of server tag, client tag, or enable local e-sealing.' }
  });
  assert.deepEqual(await post('/api/settings/features/toggle', {}), {
    status: 400,
    json: { error: 'No feature changes provided.' }
  });
  assert.equal((await post('/api/deploy/retry', { runId: 'gone' })).status, 404);
});

// ---------------------------------------------------------------------------
// Views: banner and disabled controls with the overlay, unchanged without
// ---------------------------------------------------------------------------

const ejs = require('ejs');
const VIEWS = path.join(__dirname, '..', 'views');
const TOPBAR = { hostname: HOST, version: '3.33/8.40', hasCompletedSetup: true, runActive: false };
const OVERLAY_STATE = { overlayDir: '/etc/padsign/overlay/20260101-initial' };

function renderDashboard(overlay) {
  return ejs.renderFile(path.join(VIEWS, 'dashboard.ejs'), {
    ...TOPBAR,
    overlay,
    state: { state: 'DEPLOYED' },
    tags: { serverTag: '3.33', clientTag: '8.40' },
    latestTags: { serverTag: '3.34', clientTag: '8.41' },
    upgradePanelState: 'update-available',
    host: HOST,
    activeRunId: null,
    staleLock: null
  });
}

function renderSettings(overlay) {
  return ejs.renderFile(path.join(VIEWS, 'settings.ejs'), {
    ...TOPBAR,
    overlay,
    host: HOST,
    features: { routing: false, demo: true, localEseal: false },
    cert: { checks: [{ status: 'ok', message: 'Certificate is valid' }] },
    servedCert: null,
    activeRunId: null
  });
}

test('dashboard with the overlay: banner, no upgrade controls, health check still runs', async () => {
  const html = await renderDashboard(OVERLAY_STATE);
  assert.match(html, /This host is overlay-managed/);
  assert.match(html, /\/etc\/padsign\/overlay\/20260101-initial/);
  assert.match(html, /09-11-start-at-boot-backups-and-customized-hosts\.md/);
  assert.match(html, /id="upgrade-overlay-note"/);
  assert.doesNotMatch(html, /id="upgradeForm"/);
  assert.doesNotMatch(html, /\/api\/upgrade\/plan/);
  assert.match(html, /\/api\/wizard\/verify/);
});

test('dashboard without the overlay: no banner, upgrade panel as before', async () => {
  for (const overlay of [null, undefined]) {
    const html = await renderDashboard(overlay);
    assert.doesNotMatch(html, /overlay-managed/);
    assert.match(html, /id="upgradeForm"/);
    assert.match(html, /\/api\/upgrade\/plan/);
  }
});

test('settings with the overlay: banner, every action group disabled, live state still shown', async () => {
  const html = await renderSettings(OVERLAY_STATE);
  assert.match(html, /This host is overlay-managed/);
  for (const id of ['host-actions', 'cert-actions', 'features-actions']) {
    assert.match(html, new RegExp(`<fieldset class="settings-actions" id="${id}" disabled>`), id);
  }
  assert.match(html, /Certificate is valid/);
  assert.match(html, new RegExp(`Currently configured for: <strong>${HOST.replace(/\./g, '\.')}</strong>`));
});

test('settings without the overlay: no banner, nothing disabled by it', async () => {
  const html = await renderSettings(null);
  assert.doesNotMatch(html, /overlay-managed/);
  assert.doesNotMatch(html, /<fieldset[^>]*disabled/);
  assert.equal((html.match(/<fieldset class="settings-actions"/g) || []).length, 3);
});

test('review step with the overlay: banner, and Confirm & Deploy is disabled', async () => {
  const locals = {
    ...TOPBAR,
    hasCompletedSetup: false,
    wizard: { host: HOST, companyRole: 'Example', realm: 'padsign', adminUser: 'admin', adminPass: 'x', features: {}, cert: { host: HOST }, furthestStepReached: 5 },
    features: [{ key: 'enable_routing', label: 'Document routing' }]
  };
  const file = path.join(VIEWS, 'steps', '05-review.ejs');
  const locked = await ejs.renderFile(file, { ...locals, overlay: OVERLAY_STATE });
  assert.match(locked, /This host is overlay-managed/);
  assert.match(locked, /<button type="button" id="deployBtn" class="btn btn-primary" disabled>/);
  const open = await ejs.renderFile(file, { ...locals, overlay: null });
  assert.doesNotMatch(open, /overlay-managed/);
  assert.match(open, /<button type="button" id="deployBtn" class="btn btn-primary">/);
});
