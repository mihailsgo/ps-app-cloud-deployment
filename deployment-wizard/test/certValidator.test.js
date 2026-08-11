'use strict';

const path = require('path');
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'state-fresh');

const test = require('node:test');
const assert = require('node:assert/strict');
const { checkLiveCert, deployedCertPathsFor, certPathsFor, checkServedCert } = require('../lib/certValidator');

// Only the pure-JS paths are covered here (no bash/openssl invocation) —
// matching the rest of this codebase's convention of leaving anything that
// shells out to validate-certs.sh to manual/E2E verification rather than
// unit tests, since that plumbing is already exercised by validateCert()'s
// existing use in onboarding and by the new scripts' own bash-level checks.

test('deployedCertPathsFor() points at nginx/certs/, distinct from certPathsFor()\'s staging path', () => {
  const deployed = deployedCertPathsFor('padsign.example.com');
  const staged = certPathsFor('padsign.example.com');
  assert.ok(deployed.crtPath.includes(path.join('nginx', 'certs')));
  assert.ok(staged.crtPath.includes(path.join('installation-scripts', 'certs')));
  assert.notEqual(deployed.crtPath, staged.crtPath);
});

test('checkLiveCert(): returns a synthetic warn check, never throws, when no cert is deployed yet', async () => {
  const result = await checkLiveCert('nothing-deployed-here.example.com');
  assert.equal(result.passed, false);
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].status, 'warn');
  assert.match(result.checks[0].message, /No certificate found/);
});

test('checkLiveCert(): requires a host argument', async () => {
  await assert.rejects(() => checkLiveCert(), /host is required/);
});

test('checkServedCert(): requires a host argument', async () => {
  await assert.rejects(() => checkServedCert(), /host is required/);
});

// HOST_PROJECT_DIR points at fixtures/state-fresh, which has no
// installation-scripts/verify-served-cert.sh — the exact "newer wizard image,
// older repo checkout" state. It must degrade to one warn row, never throw:
// GET /settings does next(err), so a throw here would blank the whole page.
test('checkServedCert(): degrades to a warn check instead of throwing when the script is absent', async () => {
  const result = await checkServedCert('padsign.example.com');
  assert.equal(result.passed, false);
  assert.equal(result.checks.length, 1);
  assert.equal(result.checks[0].status, 'warn');
  assert.match(result.checks[0].message, /Could not determine what nginx is currently serving/);
});
