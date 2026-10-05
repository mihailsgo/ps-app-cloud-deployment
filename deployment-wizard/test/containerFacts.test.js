'use strict';

const path = require('path');
// Must be set before requiring anything that pulls in lib/paths — it reads
// HOST_PROJECT_DIR once at module-load time. containerFacts only uses it as
// the `cwd` for exec calls, which every test here fakes out, so any fixture
// dir works.
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'fake-repo');

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const {
  readStackServices,
  listStackServices,
  getOverview,
  parseInspect,
  parseStats,
  parseSize,
  imageTag,
  _resetCache
} = require('../lib/containerFacts');

const fixturePath = (name) => path.join(__dirname, 'fixtures', 'monitoring', name);
const readFixture = (name) => fs.readFileSync(fixturePath(name), 'utf8');

// ---- parseSize ----

test('parseSize: parses every supported unit and rejects junk', () => {
  const cases = [
    ['0B', 0],
    ['123.4MiB', 129394278],
    ['1.5GiB', 1610612736],
    ['2kB', 2000],
    ['2KB', 2000],
    ['1KiB', 1024],
    ['1MB', 1000000],
    ['1GB', 1000000000],
    ['1TB', 1000000000000],
    ['1TiB', 1099511627776],
    ['12.5MiB', 13107200],
    ['7.6GiB', 8160437862],
    ['?', null],
    ['', null],
    ['abc', null],
    ['5', null],
    [undefined, null],
    [null, null]
  ];
  for (const [input, expected] of cases) {
    assert.equal(parseSize(input), expected, `parseSize(${JSON.stringify(input)}) -> ${expected}`);
  }
});

// ---- imageTag ----

test('imageTag: extracts the tag, ignoring a digest suffix and a registry:port prefix', () => {
  assert.equal(imageTag('mihailsgordijenko/ps-server:3.32@sha256:abc123'), '3.32');
  assert.equal(imageTag('nginx:1.27-alpine'), '1.27-alpine');
  assert.equal(imageTag('repo/img'), 'latest');
  assert.equal(imageTag('registry:5000/repo/img:1.0'), '1.0');
  assert.equal(imageTag('registry:5000/repo/img'), 'latest');
});

test('imageTag: empty or missing image is null, not "latest"', () => {
  assert.equal(imageTag(''), null);
  assert.equal(imageTag(undefined), null);
  assert.equal(imageTag(null), null);
});

// ---- parseInspect ----

test('parseInspect: maps by compose service, computing uptime/health/lastProbe from the fixture', () => {
  const inspectArray = JSON.parse(readFixture('inspect.json'));
  const nowMs = Date.parse('2026-09-29T08:00:00.000Z');
  const map = parseInspect(inspectArray, nowMs);

  const nginx = map.get('nginx');
  assert.equal(nginx.state, 'running');
  assert.equal(nginx.health, 'healthy');
  assert.equal(nginx.uptimeSec, 10800, '3 hours since StartedAt');
  assert.equal(nginx.restarts, 0);
  assert.equal(nginx.image, 'nginx:1.27-alpine');
  assert.equal(nginx.imageTag, '1.27-alpine');
  assert.equal(nginx.lastProbe, 'nginx healthy');

  const psServer = map.get('ps-server');
  assert.equal(psServer.health, 'none', 'no Health block at all means "none", not "healthy"');
  assert.equal(psServer.uptimeSec, 5400, '90 minutes since StartedAt');
  assert.equal(psServer.lastProbe, null);
  assert.equal(psServer.restarts, 2);

  const psClient = map.get('ps-client');
  assert.equal(psClient.state, 'exited');
  assert.equal(psClient.health, 'unhealthy');
  assert.equal(psClient.uptimeSec, null, 'not running -> no uptime');
  assert.equal(psClient.lastProbe, 'connection refused', 'the LAST log entry, trimmed');
});

test('parseInspect: lastProbe is trimmed and capped at 300 chars', () => {
  const longOutput = `  ${'x'.repeat(320)}  `;
  const arr = [{
    Id: 'a'.repeat(64),
    Name: '/some-container',
    RestartCount: 0,
    State: {
      Status: 'running',
      Running: true,
      StartedAt: '2026-01-01T00:00:00.000Z',
      Health: { Status: 'healthy', Log: [{ Start: '', End: '', ExitCode: 0, Output: longOutput }] }
    },
    Config: { Image: 'x:1', Labels: { 'com.docker.compose.service': 'svc' } }
  }];
  const map = parseInspect(arr, Date.parse('2026-01-01T01:00:00.000Z'));
  const info = map.get('svc');
  assert.equal(info.lastProbe.length, 300);
  assert.equal(info.lastProbe, 'x'.repeat(300));
});

test('parseInspect: falls back to the container Name when compose labels are absent', () => {
  const arr = [{
    Id: 'b'.repeat(64),
    Name: '/standalone-thing',
    RestartCount: 0,
    State: { Status: 'running', Running: true, StartedAt: '2026-01-01T00:00:00.000Z' },
    Config: { Image: 'x:1', Labels: {} }
  }];
  const map = parseInspect(arr, Date.parse('2026-01-01T00:00:10.000Z'));
  assert.ok(map.has('standalone-thing'));
});

// ---- parseStats ----

test('parseStats: parses percentages, MemUsage pairs and pids, keyed by the 12-char short id', () => {
  const map = parseStats(readFixture('stats.ndjson'));

  const nginxStats = map.get('e8d78bba48dd');
  assert.equal(nginxStats.cpuPct, 0.15);
  assert.equal(nginxStats.memUsageBytes, parseSize('12.5MiB'));
  assert.equal(nginxStats.memLimitBytes, parseSize('7.6GiB'));
  assert.equal(nginxStats.memPct, 0.16);
  assert.equal(nginxStats.netIO, '1.2kB / 850B');
  assert.equal(nginxStats.blockIO, '0B / 0B');
  assert.equal(nginxStats.pids, 3);

  const serverStats = map.get('dd667f3a8a3a');
  assert.equal(serverStats.cpuPct, 1.25);
  assert.equal(serverStats.memPct, 1.58);
  assert.equal(serverStats.pids, 11);
});

test('parseStats: an unparsable field degrades to null, never throws', () => {
  const map = parseStats('{"ID":"abc123456789","Name":"x","CPUPerc":"?","MemUsage":"weird","MemPerc":"n/a","NetIO":"-","BlockIO":"-","PIDs":"x"}\n');
  const row = map.get('abc123456789');
  assert.equal(row.cpuPct, null);
  assert.equal(row.memUsageBytes, null);
  assert.equal(row.memLimitBytes, null);
  assert.equal(row.memPct, null);
  assert.equal(row.pids, null);
});

test('parseStats: keys by the first 12 chars so a full-length ID still joins', () => {
  const fullId = 'dd667f3a8a3a785cc9070e296e7709b2decfd301fac1d12d39f0536fb8913b4b';
  const line = JSON.stringify({ ID: fullId, Name: 'x', CPUPerc: '1%', MemUsage: '1MiB / 1GiB', MemPerc: '1%', NetIO: '-', BlockIO: '-', PIDs: '1' });
  const map = parseStats(`${line}\n`);
  assert.ok(map.has(fullId.slice(0, 12)));
});

// ---- listStackServices ----

test('listStackServices: returns a copy; mutating a result does not corrupt the cache', async () => {
  _resetCache();
  const exec = async () => ({ stdout: 'nginx\nps-server\n' });
  const first = await listStackServices({ exec, now: () => 1000 });
  first.push('tampered');
  const second = await listStackServices({ exec, now: () => 1000 });
  assert.deepEqual(second, ['nginx', 'ps-server']);
  second.push('tampered');
  const third = await listStackServices({ exec, now: () => 1000 });
  assert.deepEqual(third, ['nginx', 'ps-server']);
});

test('listStackServices: concurrent first calls share one exec', async () => {
  _resetCache();
  let calls = 0;
  const exec = async () => {
    calls += 1;
    await new Promise((r) => setTimeout(r, 20));
    return { stdout: 'nginx\nps-server\n' };
  };
  const [a, b] = await Promise.all([
    listStackServices({ exec, now: () => 1000 }),
    listStackServices({ exec, now: () => 1000 })
  ]);
  assert.equal(calls, 1);
  assert.deepEqual(a, ['nginx', 'ps-server']);
  assert.deepEqual(b, ['nginx', 'ps-server']);
});

test('listStackServices: trims, drops blanks, removes "wizard", sorts', async () => {
  _resetCache();
  let calls = 0;
  const exec = async () => { calls += 1; return { stdout: '\nps-server\nwizard\nnginx\n\nps-client\n' }; };
  const list = await listStackServices({ exec, now: () => 1000 });
  assert.deepEqual(list, ['nginx', 'ps-client', 'ps-server']);
  assert.equal(calls, 1);
});

test('listStackServices: caches for 30s (a second call inside the window makes no new exec call)', async () => {
  _resetCache();
  let calls = 0;
  const exec = async () => { calls += 1; return { stdout: 'nginx\nps-server\n' }; };
  let t = 1000;
  const now = () => t;

  const first = await listStackServices({ exec, now });
  t += 5000; // well within the 30s window
  const second = await listStackServices({ exec, now });

  assert.deepEqual(first, second);
  assert.equal(calls, 1);
});

test('listStackServices: on error, falls back to the last good list (or [] with none yet)', async () => {
  _resetCache();
  const failExec = async () => { throw new Error('docker: command not found'); };
  const empty = await listStackServices({ exec: failExec, now: () => 1000 });
  assert.deepEqual(empty, [], 'no prior successful call -> []');

  _resetCache();
  let t = 1000;
  const now = () => t;
  const okExec = async () => ({ stdout: 'nginx\n' });
  const first = await listStackServices({ exec: okExec, now });
  assert.deepEqual(first, ['nginx']);

  t += 40000; // past the 30s cache window, so the next call actually re-execs
  const second = await listStackServices({ exec: failExec, now });
  assert.deepEqual(second, ['nginx'], 'stale-but-good beats blanking the table');
});

// ---- readStackServices: a compose failure is an error, not "no services" ----

// What `docker compose config --services` prints on an overlay host whose
// overlay directory is not mounted into the wizard container.
const OVERLAY_STDERR = 'stat /srv/padsign-overlay/compose.overlay.yml: no such file or directory\n';

function composeError(stderr = OVERLAY_STDERR) {
  return Object.assign(new Error('Command failed: docker compose config --services'), { code: 1, stderr });
}

test('readStackServices: a failing compose call resolves to its first stderr line, not an empty success', async () => {
  _resetCache();
  const exec = async () => { throw composeError(); };
  const result = await readStackServices({ exec, now: () => 1000, unreadable: () => [] });
  assert.deepEqual(result.services, []);
  assert.equal(result.error, 'stat /srv/padsign-overlay/compose.overlay.yml: no such file or directory');
  assert.equal(result.hint, null, 'no hint when every COMPOSE_FILE entry is readable');
});

test('readStackServices: names the COMPOSE_FILE entry the container cannot read, and the page that explains it', async () => {
  _resetCache();
  const exec = async () => { throw composeError(); };
  const result = await readStackServices({ exec, now: () => 1000, unreadable: () => ['/srv/padsign-overlay/compose.overlay.yml'] });
  assert.match(result.hint, /COMPOSE_FILE names \/srv\/padsign-overlay\/compose\.overlay\.yml, which the wizard container cannot read/);
  assert.match(result.hint, /documentation\/09-12-monitoring-from-the-wizard\.md/);
});

test('readStackServices: success has error null; a later failure keeps the last good list and reports the error', async () => {
  _resetCache();
  let t = 1000;
  const now = () => t;
  const ok = await readStackServices({ exec: async () => ({ stdout: 'nginx\n' }), now });
  assert.deepEqual(ok, { services: ['nginx'], error: null, hint: null });
  t += 40000;
  const stale = await readStackServices({ exec: async () => { throw composeError(); }, now, unreadable: () => [] });
  assert.deepEqual(stale.services, ['nginx']);
  assert.match(stale.error, /no such file or directory/);
});

test('readStackServices: an unreadable() that throws still yields the compose error', async () => {
  _resetCache();
  const result = await readStackServices({
    exec: async () => { throw composeError(); },
    now: () => 1000,
    unreadable: () => { throw new Error('boom'); }
  });
  assert.match(result.error, /no such file or directory/);
  assert.equal(result.hint, null);
});

// ---- getOverview ----

function fakeExecFor({ services, ps, inspect, stats, failPs, failStats }) {
  return async (file, args) => {
    assert.equal(file, 'docker');
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: services };
    if (args[0] === 'compose' && args[1] === 'ps') {
      if (failPs) throw new Error('Cannot connect to the Docker daemon');
      return { stdout: ps };
    }
    if (args[0] === 'inspect') return { stdout: inspect };
    if (args[0] === 'stats') {
      if (failStats) throw new Error('docker stats timed out');
      return { stdout: stats };
    }
    throw new Error(`unexpected exec call: ${args.join(' ')}`);
  };
}

test('getOverview: joins compose config + ps + inspect + stats into one row per stack service', async () => {
  _resetCache();
  const exec = fakeExecFor({
    services: 'dmss-archive-services-fallback\nnginx\nps-client\nps-server\nwizard\n',
    ps: readFixture('compose-ps.json'),
    inspect: readFixture('inspect.json'),
    stats: readFixture('stats.ndjson')
  });

  const result = await getOverview({ exec, now: () => Date.parse('2026-09-29T08:00:00.000Z') });

  assert.equal(result.dockerAvailable, true);
  assert.equal(result.services.length, 4, 'wizard is excluded; the other 4 stack services are all rows');
  assert.deepEqual(result.services.map((r) => r.service),
    ['dmss-archive-services-fallback', 'nginx', 'ps-client', 'ps-server'], 'sorted by name');

  const missing = result.services.find((r) => r.service === 'dmss-archive-services-fallback');
  assert.equal(missing.state, 'missing');
  assert.equal(missing.health, null);
  assert.equal(missing.cpuPct, null);

  const nginxRow = result.services.find((r) => r.service === 'nginx');
  assert.equal(nginxRow.state, 'running');
  assert.equal(nginxRow.health, 'healthy');
  assert.equal(nginxRow.imageTag, '1.27-alpine');
  assert.equal(nginxRow.cpuPct, 0.15, 'joined from stats by the 12-char id prefix');
  assert.equal(nginxRow.memUsageBytes, parseSize('12.5MiB'));

  const serverRow = result.services.find((r) => r.service === 'ps-server');
  assert.equal(serverRow.health, 'none');
  assert.equal(serverRow.cpuPct, 1.25);

  const clientRow = result.services.find((r) => r.service === 'ps-client');
  assert.equal(clientRow.state, 'exited');
  assert.equal(clientRow.health, 'unhealthy');
  assert.equal(clientRow.cpuPct, null, 'exited containers are never passed to docker stats');
});

test('getOverview: dockerAvailable is false and services is [] when "compose ps" fails', async () => {
  _resetCache();
  const exec = fakeExecFor({
    services: 'nginx\n',
    failPs: true
  });
  const result = await getOverview({ exec, now: () => 1000 });
  assert.equal(result.dockerAvailable, false);
  assert.deepEqual(result.services, []);
  assert.ok(result.generatedAt);
});

test('getOverview: every compose call failing (overlay compose file not mounted) is an error state, not an empty table', async () => {
  _resetCache();
  const exec = async (file, args) => {
    if (args[0] === 'compose') throw composeError();
    throw new Error(`unexpected exec call: ${args.join(' ')}`);
  };
  const result = await getOverview({ exec, now: () => 1000, unreadable: () => ['/srv/padsign-overlay/compose.overlay.yml'] });
  assert.equal(result.dockerAvailable, false);
  assert.deepEqual(result.services, []);
  assert.equal(result.error, 'stat /srv/padsign-overlay/compose.overlay.yml: no such file or directory');
  assert.match(result.hint, /cannot read/);
});

test('getOverview: "compose config" failing while "compose ps" answers still reports the error', async () => {
  _resetCache();
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') throw composeError();
    if (args[0] === 'compose' && args[1] === 'ps') return { stdout: '' };
    throw new Error(`unexpected exec call: ${args.join(' ')}`);
  };
  const result = await getOverview({ exec, now: () => 1000, unreadable: () => [] });
  assert.equal(result.dockerAvailable, true);
  assert.deepEqual(result.services, []);
  assert.match(result.error, /no such file or directory/);
});

test('getOverview: a healthy run carries error and hint null', async () => {
  _resetCache();
  const exec = fakeExecFor({
    services: 'nginx\n',
    ps: readFixture('compose-ps.json'),
    inspect: readFixture('inspect.json'),
    stats: readFixture('stats.ndjson')
  });
  const result = await getOverview({ exec, now: () => Date.parse('2026-09-29T08:00:00.000Z') });
  assert.equal(result.error, null);
  assert.equal(result.hint, null);
});

test('getOverview: a failing "docker stats" degrades cpu/mem to null without throwing', async () => {
  _resetCache();
  const exec = fakeExecFor({
    services: 'nginx\nps-server\n',
    ps: readFixture('compose-ps.json'),
    inspect: readFixture('inspect.json'),
    failStats: true
  });

  const result = await getOverview({ exec, now: () => Date.parse('2026-09-29T08:00:00.000Z') });
  assert.equal(result.dockerAvailable, true);

  const nginxRow = result.services.find((r) => r.service === 'nginx');
  assert.equal(nginxRow.state, 'running', 'inspect data is still present');
  assert.equal(nginxRow.cpuPct, null);
  assert.equal(nginxRow.memUsageBytes, null);
  assert.equal(nginxRow.memPct, null);
});

const NOW = () => Date.parse('2026-09-29T08:00:00.000Z');

test('getOverview: partial "docker inspect" failure salvages stdout and falls back to compose ps for the rest', async () => {
  _resetCache();
  const survivors = JSON.stringify(JSON.parse(readFixture('inspect.json')).slice(0, 1)); // nginx only
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: 'nginx\nps-server\nother\n' };
    if (args[0] === 'compose' && args[1] === 'ps') return { stdout: readFixture('compose-ps.json') };
    if (args[0] === 'inspect') {
      // docker inspect exits 1 when one id vanished, but still prints the rest
      const err = new Error('Error: No such object: dd667f3a8a3a');
      err.code = 1;
      err.stdout = survivors;
      throw err;
    }
    if (args[0] === 'stats') return { stdout: readFixture('stats.ndjson') };
    throw new Error(`unexpected: ${args.join(' ')}`);
  };

  const result = await getOverview({ exec, now: NOW });
  const byName = Object.fromEntries(result.services.map((r) => [r.service, r]));

  assert.equal(byName.nginx.state, 'running');
  assert.equal(byName.nginx.restarts, 0, 'salvaged from the partial inspect JSON');

  assert.equal(byName['ps-server'].state, 'running', 'compose ps State, not "missing"');
  assert.equal(byName['ps-server'].health, 'none', 'compose ps reported an empty Health');
  assert.equal(byName['ps-server'].restarts, null);
  assert.equal(byName['ps-server'].imageTag, '3.32');

  assert.equal(byName.other.state, 'missing', 'no compose ps row at all');
});

test('getOverview: inspect failing outright without usable stdout falls back to compose ps rows', async () => {
  _resetCache();
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: 'nginx\nps-client\n' };
    if (args[0] === 'compose' && args[1] === 'ps') return { stdout: readFixture('compose-ps.json') };
    if (args[0] === 'inspect') throw new Error('boom');
    throw new Error(`unexpected: ${args.join(' ')}`);
  };
  const result = await getOverview({ exec, now: NOW });
  const byName = Object.fromEntries(result.services.map((r) => [r.service, r]));
  assert.equal(byName.nginx.state, 'running');
  assert.equal(byName.nginx.health, 'healthy');
  assert.equal(byName['ps-client'].state, 'exited');
  assert.equal(byName['ps-client'].health, 'unhealthy');
});

test('getOverview: accepts the older single-JSON-array "compose ps" format', async () => {
  _resetCache();
  const asArray = JSON.stringify(readFixture('compose-ps.json').trim().split('\n').map((l) => JSON.parse(l)));
  const exec = fakeExecFor({
    services: 'nginx\nps-client\nps-server\n',
    ps: asArray,
    inspect: readFixture('inspect.json'),
    stats: readFixture('stats.ndjson')
  });
  const result = await getOverview({ exec, now: NOW });
  assert.equal(result.services.length, 3);
  assert.equal(result.services.find((r) => r.service === 'nginx').cpuPct, 0.15);
});

test('getOverview: overlapping calls share one in-flight promise', async () => {
  _resetCache();
  let psCalls = 0;
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: 'nginx\n' };
    if (args[0] === 'compose' && args[1] === 'ps') {
      psCalls += 1;
      await new Promise((r) => setTimeout(r, 20));
      return { stdout: '' };
    }
    throw new Error(`unexpected: ${args.join(' ')}`);
  };
  const [a, b] = await Promise.all([getOverview({ exec, now: NOW }), getOverview({ exec, now: NOW })]);
  assert.equal(psCalls, 1);
  assert.deepEqual(a, b);
});

test('getOverview: only stack services are inspected (the wizard container is excluded)', async () => {
  _resetCache();
  const wizardLine = JSON.stringify({ ID: 'ffffffffffff', Name: 'padsign-wizard-1', Service: 'wizard', State: 'running', Health: '', Status: 'Up', Image: 'x:1' });
  let inspected = null;
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: 'nginx\nwizard\n' };
    if (args[0] === 'compose' && args[1] === 'ps') return { stdout: `${readFixture('compose-ps.json')}${wizardLine}\n` };
    if (args[0] === 'inspect') { inspected = args.slice(1); return { stdout: readFixture('inspect.json') }; }
    if (args[0] === 'stats') return { stdout: readFixture('stats.ndjson') };
    throw new Error(`unexpected: ${args.join(' ')}`);
  };
  const result = await getOverview({ exec, now: NOW });
  assert.deepEqual(inspected, ['e8d78bba48dd'], 'only nginx (the sole stack service) is inspected');
  assert.deepEqual(result.services.map((r) => r.service), ['nginx']);
});

test('getOverview: when a service has several containers the running one wins', async () => {
  _resetCache();
  const old = JSON.stringify({ ID: 'aaaaaaaaaaaa', Name: 'padsign-nginx-old', Service: 'nginx', State: 'exited', Health: '', Status: 'Exited', Image: 'nginx:1.0' });
  let inspected = null;
  const exec = async (file, args) => {
    if (args[0] === 'compose' && args[1] === 'config') return { stdout: 'nginx\n' };
    if (args[0] === 'compose' && args[1] === 'ps') return { stdout: `${old}\n${readFixture('compose-ps.json')}` };
    if (args[0] === 'inspect') { inspected = args.slice(1); return { stdout: readFixture('inspect.json') }; }
    if (args[0] === 'stats') return { stdout: readFixture('stats.ndjson') };
    throw new Error(`unexpected: ${args.join(' ')}`);
  };
  await getOverview({ exec, now: NOW });
  assert.deepEqual(inspected, ['e8d78bba48dd']);
});

test('getOverview: no containers at all -> inspect/stats are skipped, everything is "missing"', async () => {
  _resetCache();
  const exec = fakeExecFor({
    services: 'nginx\nps-server\n',
    ps: '' // docker compose ps -a with an empty (never-started) stack
  });
  const result = await getOverview({ exec, now: () => 1000 });
  assert.equal(result.dockerAvailable, true);
  assert.ok(result.services.every((r) => r.state === 'missing'));
});
