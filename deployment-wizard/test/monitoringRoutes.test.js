'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const { PassThrough } = require('stream');
const express = require('express');

const { requireAuth } = require('../lib/auth');
const logStream = require('../lib/logStream');
const monitoringRoutes = require('../routes/monitoringRoutes');
const {
  createMonitoringRouter,
  pickSelectedService,
  bundleErrorStatus,
  serviceFromRunArgs
} = monitoringRoutes;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

test('pickSelectedService(): the requested service wins when it is in the stack', () => {
  assert.equal(pickSelectedService(['nginx', 'ps-server'], 'nginx'), 'nginx');
});

test('pickSelectedService(): an unknown request falls back to ps-server', () => {
  assert.equal(pickSelectedService(['nginx', 'ps-server'], 'nope'), 'ps-server');
  assert.equal(pickSelectedService(['nginx', 'ps-server'], undefined), 'ps-server');
});

test('pickSelectedService(): without ps-server the first service is used, without services null', () => {
  assert.equal(pickSelectedService(['nginx'], undefined), 'nginx');
  assert.equal(pickSelectedService([], 'x'), null);
});

test('pickSelectedService(): a non-string query value (?service[]=x) is ignored', () => {
  assert.equal(pickSelectedService(['nginx', 'ps-server'], ['nginx']), 'ps-server');
});

test('bundleErrorStatus(): maps the error codes createBundle() throws', () => {
  assert.equal(bundleErrorStatus({ code: 'BAD_SINCE' }), 400);
  assert.equal(bundleErrorStatus({ code: 'BAD_HOST' }), 400);
  assert.equal(bundleErrorStatus({ code: 'BUNDLE_IN_PROGRESS' }), 409);
  assert.equal(bundleErrorStatus(new Error('boom')), 500);
  assert.equal(bundleErrorStatus(null), 500);
});

test('serviceFromRunArgs(): reads the service back out of the run arguments', () => {
  assert.equal(serviceFromRunArgs(['--service', 'nginx']), 'nginx');
  assert.equal(serviceFromRunArgs(['--service']), null);
  assert.equal(serviceFromRunArgs(undefined), null);
});

// ---------------------------------------------------------------------------
// Over HTTP, with the libraries stubbed (no Docker needed)
// ---------------------------------------------------------------------------

const VIEWS = path.join(__dirname, '..', 'views');

function baseDeps(overrides = {}) {
  return {
    listStackServices: async () => ['nginx', 'ps-server'],
    getOverview: async () => ({ generatedAt: 'now', dockerAvailable: true, services: [] }),
    runMonitorStatus: async () => ({ ok: false, error: 'not available' }),
    listChecks: () => [{ id: 'config', label: 'Configuration', description: 'Runs validate-config.sh.' }],
    runCheck: async (id) => {
      if (id !== 'config') {
        const err = new Error('unknown');
        err.code = 'UNKNOWN_CHECK';
        throw err;
      }
      return { id, label: 'Configuration', passed: true, checks: [], durationMs: 1 };
    },
    listBundles: () => [],
    isBundleRunning: () => false,
    readConfiguredHost: () => 'padsign.example.com',
    readConfiguredCompanyRole: () => 'ACME',
    getTopbarContext: async () => ({ hostname: 'padsign.example.com', version: '3.33/8.40', hasCompletedSetup: true, runActive: false }),
    ensureWizardSession: () => ({ host: '' }),
    getRun: () => null,
    ...overrides
  };
}

function makeApp(deps, { authenticated = true } = {}) {
  const app = express();
  app.set('view engine', 'ejs');
  app.set('views', VIEWS);
  app.use(express.json());
  app.use((req, res, next) => {
    req.session = authenticated ? { authenticated: true } : {};
    req.sessionID = 'sess-1';
    next();
  });
  app.use((req, res, next) => requireAuth(req, res, next));
  app.use((req, res, next) => {
    res.locals.activeNav = req.path.startsWith('/monitoring') ? 'monitoring' : '';
    next();
  });
  app.use(createMonitoringRouter(deps));
  return app;
}

async function withServer(app, fn) {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

const post = (url, body) => fetch(url, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body)
});

test('an unauthenticated API request is refused with 401 (the router sits behind the auth gate)', async () => {
  await withServer(makeApp(baseDeps(), { authenticated: false }), async (base) => {
    const res = await fetch(`${base}/api/monitoring/services`);
    assert.equal(res.status, 401);
  });
});

test('GET /api/monitoring/services: JSON, never cached', async () => {
  await withServer(makeApp(baseDeps()), async (base) => {
    const res = await fetch(`${base}/api/monitoring/services`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('cache-control'), 'no-store');
    assert.equal((await res.json()).dockerAvailable, true);
  });
});

test('GET /api/monitoring/services: an unexpected failure is a 500 sentence pointing at the wizard log', async (t) => {
  t.mock.method(console, 'error', () => {});
  const deps = baseDeps({ getOverview: async () => { throw new Error('boom'); } });
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/services`);
    assert.equal(res.status, 500);
    const { error } = await res.json();
    assert.match(error, /check `docker logs padsign-wizard`\.$/);
    assert.doesNotMatch(error, /boom/);
  });
});

test('GET /api/monitoring/status: passes the configured host to the runner', async () => {
  let seen;
  const deps = baseDeps({ runMonitorStatus: async (opts) => { seen = opts; return { ok: true, report: { schema: 1 } }; } });
  await withServer(makeApp(deps), async (base) => {
    const body = await (await fetch(`${base}/api/monitoring/status`)).json();
    assert.equal(body.ok, true);
    assert.equal(seen.host, 'padsign.example.com');
  });
});

// ---- Log stream ----

test('GET logs/stream: an unknown service is a 400 with an operator-facing error', async () => {
  logStream._resetStreams();
  const deps = { ...baseDeps(), ...logStreamDeps() };
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/logs/stream?service=nope`);
    assert.equal(res.status, 400);
    assert.match((await res.json()).error, /Unknown service/);
  });
});

test('GET logs/stream: 429 when the session has no stream slots left', async () => {
  logStream._resetStreams();
  const held = [1, 2, 3, 4].map(() => logStream.acquireStream('sess-1'));
  try {
    await withServer(makeApp({ ...baseDeps(), ...logStreamDeps() }), async (base) => {
      const res = await fetch(`${base}/api/monitoring/logs/stream?service=nginx`);
      assert.equal(res.status, 429);
      assert.equal((await res.json()).error, 'Too many open log streams - close another Logs tab.');
    });
  } finally {
    held.forEach((release) => release());
    logStream._resetStreams();
  }
});

// The real streamLogsSse with a fake `docker`, so the slot bookkeeping is
// checked against the real request/response close semantics of this Node.
function logStreamDeps(children = []) {
  return {
    TAIL_CHOICES: logStream.TAIL_CHOICES,
    validateLogParams: logStream.validateLogParams,
    acquireStream: logStream.acquireStream,
    streamLogsSse: (req, res, params) => logStream.streamLogsSse(req, res, params, {
      spawn: () => {
        const child = new EventEmitter();
        child.stdout = new PassThrough();
        child.stderr = new PassThrough();
        child.kill = () => { child.killed = true; child.emit('close', null); };
        children.push(child);
        return child;
      },
      heartbeatMs: 1000000
    })
  };
}

function freeSlots() {
  const got = [];
  for (let i = 0; i < 4; i += 1) {
    const release = logStream.acquireStream('sess-1');
    if (!release) break;
    got.push(release);
  }
  got.forEach((release) => release());
  return got.length;
}

async function waitFor(check, ms = 2000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (check()) return true;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return false;
}

test('GET logs/stream: streams lines while open, keeps its slot, and frees it when the tab closes', async () => {
  logStream._resetStreams();
  const children = [];
  await withServer(makeApp({ ...baseDeps(), ...logStreamDeps(children) }), async (base) => {
    const controller = new AbortController();
    const res = await fetch(`${base}/api/monitoring/logs/stream?service=ps-server&follow=1`, { signal: controller.signal });
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /text\/event-stream/);

    assert.equal(children.length, 1);
    children[0].stdout.write('2026-09-29T10:00:00Z hello\n');
    const reader = res.body.getReader();
    const { value } = await reader.read();
    assert.match(Buffer.from(value).toString('utf8'), /event: lines/);

    // Still open: the slot is held and the child was not killed.
    assert.equal(children[0].killed, undefined);
    assert.equal(freeSlots(), 3);

    controller.abort();
    assert.ok(await waitFor(() => children[0].killed === true), 'docker child is stopped when the client leaves');
    assert.ok(await waitFor(() => freeSlots() === 4), 'the stream slot is released');
  });
  logStream._resetStreams();
});

test('GET logs/stream: a null result from streamLogsSse releases the slot at once', async () => {
  logStream._resetStreams();
  const deps = {
    ...baseDeps(),
    ...logStreamDeps(),
    streamLogsSse: (req, res) => { res.status(204).end(); return null; }
  };
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/logs/stream?service=nginx`);
    assert.equal(res.status, 204);
    assert.ok(await waitFor(() => freeSlots() === 4));
  });
  logStream._resetStreams();
});

test('GET logs/stream: a client that left during the service lookup takes no slot and starts nothing', async () => {
  logStream._resetStreams();
  let started = false;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const deps = {
    ...baseDeps({ listStackServices: async () => { await gate; return ['nginx']; } }),
    ...logStreamDeps(),
    streamLogsSse: () => { started = true; return null; }
  };
  await withServer(makeApp(deps), async (base) => {
    const req = http.get(`${base}/api/monitoring/logs/stream?service=nginx`);
    req.on('error', () => {});
    await new Promise((resolve) => setTimeout(resolve, 50));
    req.destroy();
    await new Promise((resolve) => setTimeout(resolve, 50));
    release();
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(started, false);
    assert.equal(freeSlots(), 4);
  });
  logStream._resetStreams();
});

test('GET logs/download: follow is ignored and the validated params reach the streamer', async () => {
  let seen;
  const deps = {
    ...baseDeps(),
    validateLogParams: logStream.validateLogParams,
    streamLogsDownload: (res, params) => { seen = params; res.type('text/plain').send('ok'); }
  };
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/logs/download?service=nginx&tail=1000&since=1h&follow=1`);
    assert.equal(res.status, 200);
    assert.deepEqual(seen, { service: 'nginx', tail: 1000, since: '1h', follow: false });

    const bad = await fetch(`${base}/api/monitoring/logs/download?service=nope`);
    assert.equal(bad.status, 400);
  });
});

// ---- Restart ----

test('POST restart: a service outside the compose list is a 400 and nothing is started', async () => {
  let started = false;
  const deps = baseDeps({ startRun: () => { started = true; return 'r1'; } });
  await withServer(makeApp(deps), async (base) => {
    for (const body of [{ service: 'wizard' }, { service: '../../etc' }, { service: ['nginx'] }, {}]) {
      const res = await post(`${base}/api/monitoring/restart`, body);
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.ok((await res.json()).error);
    }
    assert.equal(started, false);
  });
});

test('POST restart: a run already in progress is a 409 with the same body shape as Settings', async () => {
  const deps = baseDeps({
    startRun: () => {
      const err = new Error('A deploy/upgrade run is already in progress.');
      err.code = 'RUN_IN_PROGRESS';
      throw err;
    }
  });
  await withServer(makeApp(deps), async (base) => {
    const res = await post(`${base}/api/monitoring/restart`, { service: 'nginx' });
    assert.equal(res.status, 409);
    assert.deepEqual(await res.json(), { error: 'A deploy/upgrade run is already in progress.' });
  });
});

test('POST restart: success starts restart-service.sh for exactly that service and returns the runId', async () => {
  let call;
  const deps = baseDeps({ startRun: (opts) => { call = opts; return 'run-42'; } });
  await withServer(makeApp(deps), async (base) => {
    const res = await post(`${base}/api/monitoring/restart`, { service: 'ps-server' });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { runId: 'run-42' });
    assert.deepEqual(call, { scriptName: 'restart-service.sh', args: ['--service', 'ps-server'] });
  });
});

test('POST restart: an unexpected startRun failure is a 500 sentence', async (t) => {
  t.mock.method(console, 'error', () => {});
  const deps = baseDeps({ startRun: () => { throw new Error('spawn failed'); } });
  await withServer(makeApp(deps), async (base) => {
    const res = await post(`${base}/api/monitoring/restart`, { service: 'nginx' });
    assert.equal(res.status, 500);
    assert.match((await res.json()).error, /check `docker logs padsign-wizard`\.$/);
  });
});

// ---- Diagnostics ----

test('GET diagnostics/:id: runs the check with the configured host and company role', async () => {
  let seen;
  const deps = baseDeps({ runCheck: async (id, opts) => { seen = { id, ...opts }; return { id, passed: true, checks: [] }; } });
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/diagnostics/keycloak`);
    assert.equal(res.status, 200);
    assert.deepEqual(seen, { id: 'keycloak', host: 'padsign.example.com', companyRole: 'ACME' });
  });
});

test('GET diagnostics/:id: an unknown check is a 404', async () => {
  await withServer(makeApp(baseDeps()), async (base) => {
    const res = await fetch(`${base}/api/monitoring/diagnostics/nope`);
    assert.equal(res.status, 404);
    assert.ok((await res.json()).error);
  });
});

// ---- Support bundle ----

function codeError(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

test('POST support-bundle: success returns the bundle description', async () => {
  let seen;
  const deps = baseDeps({
    exec: 'exec-stub',
    createBundle: async (opts) => { seen = opts; return { name: 'padsign-support-x-20260929T100000Z.tar.gz', sizeBytes: 10, checks: [] }; }
  });
  await withServer(makeApp(deps), async (base) => {
    const res = await post(`${base}/api/monitoring/support-bundle`, { since: '6h' });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).sizeBytes, 10);
    assert.equal(seen.since, '6h');
    assert.equal(seen.host, 'padsign.example.com');
    assert.equal(seen.exec, 'exec-stub');
  });
});

test('POST support-bundle: BAD_SINCE is 400, BUNDLE_IN_PROGRESS is 409, anything else 500', async (t) => {
  t.mock.method(console, 'error', () => {});
  const cases = [
    [codeError('BAD_SINCE', 'since must be one of: 1h'), 400, /since must be/],
    [codeError('BUNDLE_IN_PROGRESS', 'A support bundle is already being generated.'), 409, /already being generated/],
    [new Error('archive could not be written\nsecond line'), 500, /^Could not create the support bundle: archive could not be written - check `docker logs padsign-wizard`\.$/]
  ];
  for (const [err, status, pattern] of cases) {
    const deps = baseDeps({ createBundle: async () => { throw err; } });
    await withServer(makeApp(deps), async (base) => {
      const res = await post(`${base}/api/monitoring/support-bundle`, {});
      assert.equal(res.status, status);
      assert.match((await res.json()).error, pattern);
    });
  }
});

test('GET support-bundle: lists bundles and whether one is being generated', async () => {
  const deps = baseDeps({ listBundles: () => [{ name: 'a' }], isBundleRunning: () => true });
  await withServer(makeApp(deps), async (base) => {
    assert.deepEqual(await (await fetch(`${base}/api/monitoring/support-bundle`)).json(), { bundles: [{ name: 'a' }], running: true });
  });
});

test('GET support-bundle/:name: a name that is not a bundle is a 404 (real resolveBundle)', async () => {
  const { resolveBundle } = require('../lib/supportBundle');
  await withServer(makeApp(baseDeps({ resolveBundle })), async (base) => {
    for (const name of ['nope.tar.gz', '..%2Fsecret.tar.gz', 'padsign-support-a-20260929T100000Z.tar.gz']) {
      const res = await fetch(`${base}/api/monitoring/support-bundle/${name}`);
      assert.equal(res.status, 404, name);
      assert.ok((await res.json()).error);
    }
  });
});

test('GET support-bundle/:name: an existing bundle downloads as an attachment, uncached', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-bundle-'));
  const name = 'padsign-support-host-20260929T100000Z.tar.gz';
  fs.writeFileSync(path.join(dir, name), 'BUNDLE-BYTES');
  try {
    const deps = baseDeps({ resolveBundle: (n) => (n === name ? path.join(dir, name) : null) });
    await withServer(makeApp(deps), async (base) => {
      const res = await fetch(`${base}/api/monitoring/support-bundle/${name}`);
      assert.equal(res.status, 200);
      assert.equal(res.headers.get('cache-control'), 'no-store');
      assert.match(res.headers.get('content-disposition'), /attachment; filename="padsign-support-host-20260929T100000Z\.tar\.gz"/);
      assert.equal(await res.text(), 'BUNDLE-BYTES');
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// ---- Signing activity ----

test('GET activity: a bad date range is a 400 carrying the message', async () => {
  const deps = baseDeps({ getActivity: async () => { throw codeError('BAD_RANGE', 'The start date must not be after the end date.'); } });
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/activity?from=2026-09-30&to=2026-09-01`);
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: 'The start date must not be after the end date.' });
  });
});

test('GET activity: forwards the query untouched to the library', async () => {
  let seen;
  const deps = baseDeps({ getActivity: async (opts) => { seen = opts; return { documents: [] }; } });
  await withServer(makeApp(deps), async (base) => {
    await fetch(`${base}/api/monitoring/activity?from=2026-09-01&outcome=failed&page=2`);
    assert.equal(seen.query.outcome, 'failed');
    assert.equal(seen.query.page, '2');
  });
});

test('GET activity.csv: UTF-8 BOM, CSV headers and a filename built from the range', async () => {
  const deps = baseDeps({
    getActivityCsv: async () => ({ csv: 'last_event_utc,docid\r\n2026-09-29 10:00:00,d1\r\n', range: { from: '2026-09-01', to: '2026-09-29' } })
  });
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/activity.csv?from=2026-09-01`);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'text/csv; charset=utf-8');
    assert.equal(res.headers.get('content-disposition'), 'attachment; filename="padsign-signing-activity-2026-09-01-2026-09-29.csv"');
    assert.equal(res.headers.get('cache-control'), 'no-store');
    const bytes = Buffer.from(await res.arrayBuffer());
    assert.deepEqual([...bytes.subarray(0, 3)], [0xEF, 0xBB, 0xBF]);
    assert.equal(bytes.subarray(3).toString('utf8'), 'last_event_utc,docid\r\n2026-09-29 10:00:00,d1\r\n');
  });
});

test('GET activity.csv: a bad range is a 400 JSON error, not a file', async () => {
  const deps = baseDeps({ getActivityCsv: async () => { throw codeError('BAD_RANGE', 'Bad range.'); } });
  await withServer(makeApp(deps), async (base) => {
    const res = await fetch(`${base}/api/monitoring/activity.csv?from=x`);
    assert.equal(res.status, 400);
    assert.deepEqual(await res.json(), { error: 'Bad range.' });
  });
});

// ---- Pages ----

test('GET /monitoring*: each tab renders with the tab marked current', async () => {
  await withServer(makeApp(baseDeps()), async (base) => {
    const cases = [
      ['/monitoring', 'svcTable'],
      ['/monitoring/logs?service=nginx', 'logView'],
      ['/monitoring/activity', 'activityTable'],
      ['/monitoring/diagnostics', 'bundleGenerate']
    ];
    for (const [url, id] of cases) {
      const res = await fetch(`${base}${url}`);
      assert.equal(res.status, 200, url);
      const html = await res.text();
      assert.match(html, new RegExp(`id="${id}"`), url);
      assert.match(html, /aria-current="page"/, url);
    }
  });
});

test('GET /monitoring/logs: the requested service is preselected, an unknown one falls back to ps-server', async () => {
  await withServer(makeApp(baseDeps()), async (base) => {
    const chosen = await (await fetch(`${base}/monitoring/logs?service=nginx`)).text();
    assert.match(chosen, /<option value="nginx" selected>/);
    const fallback = await (await fetch(`${base}/monitoring/logs?service=nope`)).text();
    assert.match(fallback, /<option value="ps-server" selected>/);
  });
});

test('GET /monitoring/restart-progress: an unknown run goes back to Monitoring, a known one renders the service', async () => {
  const known = { scriptName: 'restart-service.sh', args: ['--service', 'nginx'] };
  const other = { scriptName: 'upgrade.sh', args: [] };
  const deps = baseDeps({ getRun: (id) => ({ r1: known, r2: other })[id] || null });
  await withServer(makeApp(deps), async (base) => {
    for (const url of ['/monitoring/restart-progress', '/monitoring/restart-progress?runId=zzz', '/monitoring/restart-progress?runId=r2']) {
      const res = await fetch(`${base}${url}`, { redirect: 'manual' });
      assert.equal(res.status, 302, url);
      assert.equal(res.headers.get('location'), '/monitoring', url);
    }
    const res = await fetch(`${base}/monitoring/restart-progress?runId=r1`);
    assert.equal(res.status, 200);
    assert.match(await res.text(), /Restarting nginx/);
  });
});
