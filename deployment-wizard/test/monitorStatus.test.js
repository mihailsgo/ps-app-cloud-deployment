'use strict';

const path = require('path');
// monitor-status.sh does not exist in this checkout yet (a parallel task is
// writing it) — every test injects `exec` so nothing here ever shells out.
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'monitoring');

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const { runMonitorStatus, alertSeverity } = require('../lib/monitorStatus');

const fixtureJson = fs.readFileSync(path.join(__dirname, 'fixtures', 'monitoring', 'monitor-status.json'), 'utf8');

test('runMonitorStatus(): ok:true with the parsed report for a valid schema-1 document', async () => {
  const exec = async () => ({ stdout: fixtureJson, stderr: '' });
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, true);
  assert.equal(result.report.schema, 1);
  assert.equal(result.report.host, 'padsign.example.com');
  assert.equal(result.report.alerts.length, 2);
});

test('runMonitorStatus(): ok:false when the document has an unexpected schema version', async () => {
  const exec = async () => ({ stdout: JSON.stringify({ schema: 2 }), stderr: '' });
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, false);
  assert.match(result.error, /unexpected format/);
});

test('runMonitorStatus(): ok:false on non-JSON stdout', async () => {
  const exec = async () => ({ stdout: 'this is not json', stderr: '' });
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, false);
  assert.match(result.error, /unexpected format/);
});

test('runMonitorStatus(): ok:false and mentions --format when exec rejects with an older checkout\'s usage error', async () => {
  const exec = async () => {
    const err = new Error('Command failed: bash monitor-status.sh --format json');
    err.code = 2;
    err.stderr = 'ERROR: Unknown arg: --format\nusage: monitor-status.sh [--host H]\n';
    throw err;
  };
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, false);
  assert.match(result.error, /--format/);
});

test('runMonitorStatus(): never throws on a generic exec rejection (missing script / timeout)', async () => {
  const exec = async () => {
    throw new Error('spawn bash ENOENT');
  };
  await assert.doesNotReject(async () => {
    const result = await runMonitorStatus({ exec });
    assert.equal(result.ok, false);
    assert.equal(typeof result.error, 'string');
    assert.ok(result.error.length > 0);
  });
});

test('runMonitorStatus(): a timeout-style rejection (no stderr) still resolves ok:false with a usable message', async () => {
  const exec = async () => {
    const err = new Error('Command timed out');
    err.killed = true;
    err.signal = 'SIGTERM';
    throw err;
  };
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, false);
  assert.equal(typeof result.error, 'string');
});

test('runMonitorStatus(): the error never carries the script path or arguments', async () => {
  const exec = async () => {
    const err = new Error('Command failed: bash /opt/padsign/installation-scripts/monitor-status.sh --format json --host h');
    err.code = 127;
    throw err;
  };
  const result = await runMonitorStatus({ exec });
  assert.equal(result.ok, false);
  assert.ok(!result.error.includes('/opt/padsign'), result.error);
  assert.match(result.error, /exited with code 127/);
});

test('runMonitorStatus(): passes --host only when a host is given', async () => {
  let seenArgs;
  const exec = async (cmd, args) => {
    seenArgs = args;
    return { stdout: fixtureJson, stderr: '' };
  };
  await runMonitorStatus({ exec, host: 'padsign.example.com' });
  assert.ok(seenArgs.includes('--host'));
  assert.ok(seenArgs.includes('padsign.example.com'));
  assert.ok(seenArgs.includes('--format'));
  assert.ok(seenArgs.includes('json'));

  let seenArgsNoHost;
  const execNoHost = async (cmd, args) => {
    seenArgsNoHost = args;
    return { stdout: fixtureJson, stderr: '' };
  };
  await runMonitorStatus({ exec: execNoHost });
  assert.ok(!seenArgsNoHost.includes('--host'));
});

test('alertSeverity(): "fail" for service_down and service_unhealthy', () => {
  assert.equal(alertSeverity('service_down'), 'fail');
  assert.equal(alertSeverity('service_unhealthy'), 'fail');
});

test('alertSeverity(): "warn" for everything else', () => {
  assert.equal(alertSeverity('certificate_risk'), 'warn');
  assert.equal(alertSeverity('disk_pressure'), 'warn');
  assert.equal(alertSeverity('buffer_backlog'), 'warn');
  assert.equal(alertSeverity('something_unforeseen'), 'warn');
});
