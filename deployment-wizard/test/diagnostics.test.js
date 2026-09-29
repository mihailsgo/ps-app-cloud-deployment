'use strict';

const path = require('path');
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'monitoring');

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const {
  CHECKS,
  listChecks,
  runCheck,
  parseLooseCheckOutput,
  alertsToChecks
} = require('../lib/diagnostics');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', 'monitoring', name), 'utf8');
const monitorReport = JSON.parse(fixture('monitor-status.json'));

// ---- parseLooseCheckOutput ----

test('parseLooseCheckOutput(): parses verify-keycloak.sh output and ignores the RESULT: line', () => {
  const result = parseLooseCheckOutput(fixture('verify-keycloak.txt'));
  assert.equal(result.checks.length, 2);
  assert.equal(result.checks[0].status, 'ok');
  assert.match(result.checks[0].message, /Realm padsign exists/);
  assert.equal(result.checks[1].status, 'fail');
  assert.match(result.checks[1].message, /secret mismatch/);
  assert.equal(result.passed, false);
  assert.ok(!result.checks.some((c) => c.message.includes('RESULT')));
});

test('parseLooseCheckOutput(): also parses lines with 2-4 space indentation (validate-*.sh convention)', () => {
  const result = parseLooseCheckOutput('  OK   Realm padsign exists\n    FAIL Something broke\n');
  assert.equal(result.checks.length, 2);
  assert.equal(result.checks[0].status, 'ok');
  assert.equal(result.checks[1].status, 'fail');
});

test('parseLooseCheckOutput(): folds continuation lines into the preceding check, like parseHelperCheckOutput', () => {
  const result = parseLooseCheckOutput('FAIL Something broke\n  more detail on the next line\n');
  assert.equal(result.checks.length, 1);
  assert.match(result.checks[0].message, /Something broke\nmore detail on the next line/);
});

test('parseLooseCheckOutput(): text after the RESULT: line is not folded into the last check', () => {
  const result = parseLooseCheckOutput('FAIL Client padsign-backend secret mismatch\nRESULT: 1 check failed\nhint: rerun later\n');
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].message, 'Client padsign-backend secret mismatch');
});

test('parseLooseCheckOutput(): empty input degrades to a passing, empty result', () => {
  const result = parseLooseCheckOutput('');
  assert.equal(result.passed, true);
  assert.deepEqual(result.checks, []);
});

// ---- alertsToChecks ----

test('alertsToChecks(): no alerts -> a single ok row', () => {
  assert.deepEqual(alertsToChecks({ alerts: [] }), [{ status: 'ok', message: 'No alert thresholds are crossed.' }]);
  assert.deepEqual(alertsToChecks({}), [{ status: 'ok', message: 'No alert thresholds are crossed.' }]);
});

test('alertsToChecks(): maps each alert through alertSeverity()', () => {
  const checks = alertsToChecks(monitorReport);
  assert.equal(checks.length, 2);
  const unhealthy = checks.find((c) => c.message.startsWith('service_unhealthy:'));
  assert.ok(unhealthy);
  assert.equal(unhealthy.status, 'fail');
  const certRisk = checks.find((c) => c.message.startsWith('certificate_risk:'));
  assert.ok(certRisk);
  assert.equal(certRisk.status, 'warn');
});

// ---- listChecks / CHECKS ----

test('listChecks(): ids in display order, each with a label and non-empty description', () => {
  assert.deepEqual(CHECKS.map((c) => c.id), ['config', 'cert', 'served-cert', 'keycloak', 'alerts']);
  const list = listChecks();
  assert.deepEqual(list.map((c) => c.id), ['config', 'cert', 'served-cert', 'keycloak', 'alerts']);
  for (const c of list) {
    assert.equal(typeof c.label, 'string');
    assert.ok(c.label.length > 0);
    assert.equal(typeof c.description, 'string');
    assert.ok(c.description.length > 0);
  }
});

// ---- runCheck ----

test('runCheck("config"): delegates to the injected validateConfig and drops `raw`', async () => {
  const validateConfig = async () => ({ passed: true, checks: [{ status: 'ok', message: 'All good' }], raw: 'huge blob' });
  const result = await runCheck('config', { deps: { validateConfig } });
  assert.equal(result.id, 'config');
  assert.equal(result.label, 'Configuration');
  assert.equal(result.passed, true);
  assert.deepEqual(result.checks, [{ status: 'ok', message: 'All good' }]);
  assert.equal(typeof result.durationMs, 'number');
  assert.equal('raw' in result, false, 'runCheck must drop the raw script output');
});

test('runCheck(): cert/served-cert/keycloak warn when no hostname is configured', async () => {
  for (const id of ['cert', 'served-cert', 'keycloak']) {
    const result = await runCheck(id, {});
    assert.equal(result.passed, true, `${id}: a warn-only result still counts as passed`);
    assert.equal(result.checks.length, 1);
    assert.equal(result.checks[0].status, 'warn');
    assert.equal(result.checks[0].message, 'No hostname is configured yet.');
  }
});

test('runCheck("keycloak"): warns and never calls exec when companyRole is missing or CHANGE_ME', async () => {
  let called = false;
  const exec = async () => {
    called = true;
    return { stdout: '' };
  };
  for (const companyRole of [undefined, 'CHANGE_ME']) {
    const result = await runCheck('keycloak', { host: 'padsign.example.com', companyRole, deps: { exec } });
    assert.equal(result.passed, true, 'a warn-only result still counts as passed');
    assert.equal(result.checks.length, 1);
    assert.equal(result.checks[0].status, 'warn');
    assert.match(result.checks[0].message, /company role is not configured/);
  }
  assert.equal(called, false);
});

test('runCheck("keycloak"): exit 1 parses err.stdout into checks (passed:false)', async () => {
  const exec = async () => {
    const err = new Error('Command failed');
    err.code = 1;
    err.stdout = fixture('verify-keycloak.txt');
    throw err;
  };
  const result = await runCheck('keycloak', { host: 'padsign.example.com', companyRole: 'ClientCo', deps: { exec } });
  assert.equal(result.passed, false);
  assert.equal(result.checks.length, 2);
});

test('runCheck("keycloak"): passes --host and --company-role through to the script', async () => {
  let seenArgs;
  const exec = async (cmd, args) => {
    seenArgs = args;
    return { stdout: 'OK   Realm padsign exists\nRESULT: all checks passed\n' };
  };
  const result = await runCheck('keycloak', { host: 'padsign.example.com', companyRole: 'ClientCo', deps: { exec } });
  assert.ok(seenArgs.includes('--host'));
  assert.ok(seenArgs.includes('padsign.example.com'));
  assert.ok(seenArgs.includes('--company-role'));
  assert.ok(seenArgs.includes('ClientCo'));
  assert.equal(result.passed, true);
});

test('runCheck("keycloak"): a non-exit-1 exec error (usage error / timeout) is treated as "runner threw"', async () => {
  const exec = async () => {
    const err = new Error('timed out');
    err.killed = true;
    throw err;
  };
  const result = await runCheck('keycloak', { host: 'padsign.example.com', companyRole: 'ClientCo', deps: { exec } });
  assert.equal(result.passed, true);
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].status, 'warn');
  assert.match(result.checks[0].message, /Keycloak realm and clients could not be run/);
});

test('runCheck(): a runner throwing degrades to a single warn row; passed stays true (no FAIL present)', async () => {
  const validateConfig = async () => {
    throw new Error('boom');
  };
  const result = await runCheck('config', { deps: { validateConfig } });
  assert.equal(result.passed, true);
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].status, 'warn');
  assert.match(result.checks[0].message, /Configuration could not be run: boom/);
});

test('runCheck("alerts"): {ok:false} from runMonitorStatus becomes a single warn row', async () => {
  const runMonitorStatus = async () => ({ ok: false, error: 'x' });
  const result = await runCheck('alerts', { deps: { runMonitorStatus } });
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].status, 'warn');
  assert.equal(result.checks[0].message, 'x');
});

test('runCheck("alerts"): {ok:true} maps the report through alertsToChecks', async () => {
  const runMonitorStatus = async () => ({ ok: true, report: monitorReport });
  const result = await runCheck('alerts', { deps: { runMonitorStatus } });
  assert.equal(result.passed, false, 'service_unhealthy is a FAIL-severity alert');
  assert.equal(result.checks.length, 2);
});

test('runCheck(): unknown id rejects with an Error whose code is UNKNOWN_CHECK', async () => {
  await assert.rejects(
    () => runCheck('nope', {}),
    (err) => {
      assert.equal(err.code, 'UNKNOWN_CHECK');
      return true;
    }
  );
});
