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
