'use strict';

const path = require('path');
// lib/execError.js strips the project root from what it returns, and reads
// HOST_PROJECT_DIR once at load time, so set it before requiring anything.
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'monitoring');

const test = require('node:test');
const assert = require('node:assert/strict');

const { describeExecFailure } = require('../lib/execError');

test('describeExecFailure(): last non-empty stderr line', () => {
  const err = Object.assign(new Error('Command failed'), { code: 1, stderr: 'first\nsecond\n\n' });
  assert.equal(describeExecFailure(err), 'second');
});

test('describeExecFailure(): prefers the last ERROR: line over later chatter (e.g. a usage line)', () => {
  const err = Object.assign(new Error('Command failed'), {
    code: 2,
    stderr: 'ERROR: old problem\nERROR: Unknown arg: --format\nusage: monitor-status.sh [--host H]\n'
  });
  assert.equal(describeExecFailure(err), 'ERROR: Unknown arg: --format');
});

test('describeExecFailure(): "timed out" when the process was killed or signalled and printed nothing', () => {
  assert.equal(describeExecFailure(Object.assign(new Error('x'), { killed: true, code: null })), 'timed out');
  assert.equal(describeExecFailure(Object.assign(new Error('x'), { signal: 'SIGTERM' })), 'timed out');
});

test('describeExecFailure(): "exited with code N" for a numeric exit code with no stderr', () => {
  assert.equal(describeExecFailure(Object.assign(new Error('x'), { code: 127 })), 'exited with code 127');
});

test('describeExecFailure(): falls back to the first message line, minus any "Command failed:" line', () => {
  assert.equal(describeExecFailure(new Error('spawn bash ENOENT')), 'spawn bash ENOENT');
  const err = new Error('Command failed: bash /opt/padsign/installation-scripts/x.sh --host h\nsomething went wrong');
  assert.equal(describeExecFailure(err), 'something went wrong');
});

test('describeExecFailure(): never leaks the command line when the message is only the command line', () => {
  const err = new Error('Command failed: bash /opt/padsign/installation-scripts/x.sh --host h --company-role R');
  const out = describeExecFailure(err);
  assert.ok(!out.includes('/opt/padsign'), out);
  assert.ok(!out.includes('--host'), out);
});

test('describeExecFailure(): strips the absolute project root from a stderr line', () => {
  const script = path.join(process.env.HOST_PROJECT_DIR, 'installation-scripts', 'monitor-status.sh');
  const err = Object.assign(new Error('Command failed'), {
    code: 127,
    stderr: `bash: ${script}: No such file or directory\n`
  });
  const out = describeExecFailure(err);
  assert.ok(!out.includes(process.env.HOST_PROJECT_DIR), out);
  assert.match(out, /installation-scripts.monitor-status\.sh: No such file or directory/);
});

test('describeExecFailure(): tolerates a missing or non-Error argument', () => {
  assert.equal(typeof describeExecFailure(undefined), 'string');
  assert.ok(describeExecFailure(undefined).length > 0);
  assert.equal(describeExecFailure({ stderr: Buffer.from('boom\n') }), 'boom');
});

// ---- composeErrorLine ----

const { composeErrorLine, redactSecrets } = require('../lib/execError');

test('composeErrorLine(): the first stderr line that is not a compose warning', () => {
  const err = Object.assign(new Error('Command failed: docker compose config --services'), {
    code: 1,
    stderr: 'WARN[0000] The "X" variable is not set. Defaulting to a blank string.\n' +
      'time="2026-10-05T10:00:00Z" level=warning msg="version is obsolete"\n' +
      'stat /srv/padsign-overlay/compose.overlay.yml: no such file or directory\n' +
      'second line\n'
  });
  assert.equal(composeErrorLine(err), 'stat /srv/padsign-overlay/compose.overlay.yml: no such file or directory');
});

test('composeErrorLine(): only warnings -> the first of them; no stderr -> what Node knows', () => {
  assert.equal(composeErrorLine({ stderr: 'WARN[0000] only a warning\n' }), 'WARN[0000] only a warning');
  assert.equal(composeErrorLine(Object.assign(new Error('x'), { killed: true })), 'timed out');
  assert.equal(composeErrorLine(new Error('spawn docker ENOENT')), 'spawn docker ENOENT');
  assert.equal(typeof composeErrorLine(undefined), 'string');
});

test('composeErrorLine(): strips the project root and redacts secret values', () => {
  const file = path.join(process.env.HOST_PROJECT_DIR, 'docker-compose.yml');
  const err = {
    stderr: `invalid interpolation format for ${file} services.keycloak.environment.KEYCLOAK_ADMIN_PASSWORD: "s3cr$t{". You may need to escape any $ with another $.\n`
  };
  const out = composeErrorLine(err);
  assert.ok(!out.includes(process.env.HOST_PROJECT_DIR), out);
  assert.ok(!out.includes('s3cr'), out);
  assert.match(out, /KEYCLOAK_ADMIN_PASSWORD: <redacted>/);
});

test('composeErrorLine(): a very long line is cut', () => {
  const out = composeErrorLine({ stderr: `${'x'.repeat(1000)}\n` });
  assert.equal(out.length, 301);
  assert.ok(out.endsWith('…'));
});

test('redactSecrets(): key=value and key: value, quoted or not; other words untouched', () => {
  assert.equal(redactSecrets('SPRING_SECURITY_USER_PASSWORD=hunter2 next'), 'SPRING_SECURITY_USER_PASSWORD=<redacted> next');
  assert.equal(redactSecrets("api_key: 'abc def'"), 'api_key: <redacted>');
  assert.equal(redactSecrets('no such service: ps-server'), 'no such service: ps-server');
});
