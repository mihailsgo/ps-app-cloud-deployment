'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { parseLine } = require('../lib/outputParser');

test('parses bootstrap.sh step markers', () => {
  const r = parseLine('Step 5/8: Bootstrapping Keycloak (realm/clients/roles/users)...');
  assert.equal(r.type, 'step');
  assert.equal(r.step, '5');
  assert.equal(r.total, 8);
  assert.equal(r.label, 'Bootstrapping Keycloak (realm/clients/roles/users)...');
});

test('parses upgrade.sh letter-suffixed step markers (4b)', () => {
  const r = parseLine('Step 4b/6: Enabling local e-sealing...');
  assert.equal(r.type, 'step');
  assert.equal(r.step, '4b');
  assert.equal(r.total, 6);
});

test('parses ad hoc colon-suffix OK checks', () => {
  // label deliberately excludes the redundant "OK" — that's conveyed by `status`
  const r1 = parseLine('  ps-server: OK');
  assert.deepEqual(r1, { type: 'check', status: 'ok', label: 'ps-server' });

  const r2 = parseLine('  Root redirect: OK (301 -> /portal/)');
  assert.equal(r2.type, 'check');
  assert.equal(r2.status, 'ok');
  assert.equal(r2.label, 'Root redirect (301 -> /portal/)');
});

test('parses WARNING: lines distinctly from colon-checks', () => {
  const r = parseLine('  WARNING: ps-server may not have started. Check: docker compose logs ps-server');
  assert.equal(r.type, 'warning');
  assert.equal(r.message, 'ps-server may not have started. Check: docker compose logs ps-server');
});

test('parses ERROR: lines with no leading whitespace', () => {
  const r = parseLine('ERROR: Missing dependency: docker');
  assert.equal(r.type, 'error');
  assert.equal(r.message, 'Missing dependency: docker');
});

test('falls back to raw for unrecognized lines', () => {
  const r = parseLine('========================================');
  assert.equal(r.type, 'raw');
});

test('does not misclassify a WARNING line as a colon-check', () => {
  // regression guard for the ordering note in outputParser.js
  const r = parseLine('  WARNING: Root redirect not working. Check nginx config.');
  assert.equal(r.type, 'warning');
});

// ---- Settings feature: update-hostname.sh / renew-cert.sh / toggle-features.sh ----
// Every new script's live-checklist output was written to use the SAME ad
// hoc conventions bootstrap.sh/upgrade.sh already established (Step N/M:
// and "  label: OK") specifically so parseLine() needs no changes — these
// are regression guards confirming that held, not new parser behavior.

test('parses update-hostname.sh step markers (4-step script)', () => {
  const r = parseLine("Step 2/4: Configuring files for hostname 'padsign.newclient.com'...");
  assert.equal(r.type, 'step');
  assert.equal(r.step, '2');
  assert.equal(r.total, 4);
});

test('parses renew-cert.sh checklist lines with parenthetical detail', () => {
  const r = parseLine('  New certificate file: OK (valid until Jul 23 10:18:58 2027 GMT)');
  assert.equal(r.type, 'check');
  assert.equal(r.status, 'ok');
  assert.equal(r.label, 'New certificate file (valid until Jul 23 10:18:58 2027 GMT)');
});

test('parses renew-cert.sh TLS handshake check', () => {
  const r = parseLine('  TLS handshake: OK (serving cert valid until Jul 23 10:18:58 2027 GMT)');
  assert.equal(r.type, 'check');
  assert.equal(r.status, 'ok');
});

test('parses toggle-features.sh step markers (3-step script) and per-feature checks', () => {
  const step = parseLine("Step 1/3: Configuring feature flags for 'padsign.client.com'...");
  assert.equal(step.type, 'step');
  assert.equal(step.total, 3);

  const routing = parseLine('  Document routing: OK (enabled=true)');
  assert.equal(routing.type, 'check');
  assert.equal(routing.status, 'ok');

  const eseal = parseLine('  Local e-sealing: OK (STAMP_MODE=local)');
  assert.equal(eseal.type, 'check');
  assert.equal(eseal.status, 'ok');
});

test('parses toggle-features.sh readback-mismatch WARNING lines', () => {
  const r = parseLine('  WARNING: Document routing enabled=unknown, expected true');
  assert.equal(r.type, 'warning');
  assert.equal(r.message, 'Document routing enabled=unknown, expected true');
});
