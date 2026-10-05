'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { parseHelperCheckOutput } = require('../lib/outputParser');

function fixture(name) {
  return fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');
}

test('parses a fully-passing validate-certs.sh run', () => {
  const result = parseHelperCheckOutput(fixture('validate-certs-pass.txt'));
  assert.equal(result.passed, true);
  const statuses = result.checks.map((c) => c.status);
  assert.ok(statuses.includes('ok'));
  assert.ok(statuses.includes('warn'));
  assert.ok(!statuses.includes('fail'));
  // File(2) + Format(3) + Identity(4, incl. the 30-day-expiry WARN) + Chain(2) = 11
  assert.equal(result.checks.length, 11);
});

test('parses a failing validate-certs.sh run (hostname mismatch) and folds the multi-line message', () => {
  const result = parseHelperCheckOutput(fixture('validate-certs-fail-hostname.txt'));
  assert.equal(result.passed, false);
  const failing = result.checks.find((c) => c.status === 'fail');
  assert.ok(failing, 'expected a FAIL check to be present');
  assert.match(failing.message, /hostname 'wrong\.example\.com' is NOT present/);
});

test('does not misclassify section headers or banners as checks', () => {
  const result = parseHelperCheckOutput(fixture('validate-certs-pass.txt'));
  const messages = result.checks.map((c) => c.message);
  assert.ok(!messages.some((m) => m.includes('File checks:')));
  assert.ok(!messages.some((m) => m.includes('===')));
});

test('handles empty input without throwing', () => {
  const result = parseHelperCheckOutput('');
  assert.equal(result.passed, true);
  assert.deepEqual(result.checks, []);
});

test('re option: a custom line regex replaces the default (no-indent convention)', () => {
  const re = /^\s{0,4}(OK|FAIL|WARN)\b\s+(.*)$/;
  assert.deepEqual(parseHelperCheckOutput('OK   flush left\n').checks, [], 'default regex needs 2-4 spaces');
  const result = parseHelperCheckOutput('OK   flush left\nFAIL also flush\n', { re });
  assert.deepEqual(result.checks.map((c) => c.status), ['ok', 'fail']);
  assert.equal(result.passed, false);
});

test('skip option: a skipped line is dropped and ends the current check', () => {
  const re = /^\s{0,4}(OK|FAIL|WARN)\b\s+(.*)$/;
  const skip = (line) => line.startsWith('RESULT:');
  const result = parseHelperCheckOutput('FAIL broken\nRESULT: 1 check failed\ntrailing text\n', { re, skip });
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].message, 'broken', 'text after the skipped line must not be folded in');
});

test('default options are unchanged: no skip, indent required', () => {
  const result = parseHelperCheckOutput('  FAIL broken\nRESULT: 1 check failed\n');
  assert.equal(result.checks[0].message, 'broken\nRESULT: 1 check failed');
});

// --- verify-served-cert.sh ---------------------------------------------------
// Structural/regex assertions only, deliberately not exact check counts: the
// count assertion above is precisely why any wording change forces test edits.

test('parses a fully-passing verify-served-cert.sh run', () => {
  const result = parseHelperCheckOutput(fixture('verify-served-cert-pass.txt'));
  assert.equal(result.passed, true);
  const statuses = result.checks.map((c) => c.status);
  assert.ok(statuses.includes('ok'));
  assert.ok(!statuses.includes('fail'));
  assert.ok(result.checks.some((c) => /serving matches the one on disk/.test(c.message)));
});

test('parses a drift run and preserves the whole remediation hint', () => {
  const result = parseHelperCheckOutput(fixture('verify-served-cert-drift.txt'));
  assert.equal(result.passed, false);
  const drift = result.checks.find((c) => /does not match the certificate on disk/.test(c.message));
  assert.ok(drift, 'expected the served-vs-disk FAIL to be present');
  assert.equal(drift.status, 'fail');
  // Regression guard: parseHelperCheckOutput() flushes the current check on any
  // BLANK line and drops everything after it. If a blank line is ever
  // introduced into that multi-line hint, the reload command silently vanishes
  // from the wizard UI and the operator is told there is a problem but not how
  // to fix it. (validate-certs.sh:245+ already has exactly this defect.)
  assert.match(drift.message, /docker compose kill -s HUP nginx/);
  assert.match(drift.message, /only at startup and on reload/);
});

test('parses an unreachable-endpoint run', () => {
  const result = parseHelperCheckOutput(fixture('verify-served-cert-unreachable.txt'));
  assert.equal(result.passed, false);
  assert.ok(result.checks.some((c) => c.status === 'fail' && /no TLS handshake/.test(c.message)));
});

test('INFO is its own status: a check this run could not look at is neither a pass nor a failure', () => {
  const out = [
    '  OK   signed-output volume mount in docker-compose.yml',
    '  INFO signed-output is mounted from /srv/padsign/signed-output, outside what the wizard can read',
    '  WARN something else',
    ''
  ].join('\n');
  const result = parseHelperCheckOutput(out);
  assert.deepEqual(result.checks.map((c) => c.status), ['ok', 'info', 'warn']);
  assert.equal(result.passed, true, 'an INFO row must not fail the run');
  assert.match(result.checks[1].message, /^signed-output is mounted from \/srv\/padsign\/signed-output/);
  // "INFO:" prefixed progress text (bootstrap.sh style) is still not a check row
  assert.deepEqual(parseHelperCheckOutput('  INFO: No certs found\n').checks, []);
});
