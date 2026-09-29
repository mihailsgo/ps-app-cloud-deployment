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

// ---- listStackServices ----

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
