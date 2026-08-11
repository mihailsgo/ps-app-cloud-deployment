'use strict';

const path = require('path');
// Must be set before requiring anything that pulls in lib/paths — it reads
// HOST_PROJECT_DIR once at module-load time.
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'fake-repo');

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');

const { parsePlan } = require('../lib/upgradePlan');
const { buildUpgradeArgs, validateUpgradeRequest } = require('../lib/upgradeArgs');
const { savePlan, getPlan, dropPlan } = require('../lib/planStore');

// Real captured stdout from `upgrade.sh --plan-only --plan-format machine`,
// same convention as the validate-certs-*.txt fixtures. Refresh these if the
// plan output format ever changes.
const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');

test('parses a mixed plan: tag context plus per-migration status', () => {
  const plan = parsePlan(fixture('plan-machine-mixed.txt'));

  assert.equal(plan.items.length, 3);
  assert.deepEqual(plan.items.map((i) => i.id), ['document-routing', 'signed-output', 'local-eseal']);
  assert.equal(plan.pendingCount, 2);
  assert.equal(plan.empty, false);

  assert.equal(plan.tags.server.from, '3.27');
  assert.equal(plan.tags.server.to, '3.28');
  assert.equal(plan.tags.server.changes, true);
});

test('an all-already-applied plan is reported as empty', () => {
  const plan = parsePlan(fixture('plan-machine-applied.txt'));
  assert.equal(plan.items.length, 3);
  assert.equal(plan.pendingCount, 0);
  assert.equal(plan.empty, true, 'empty means "nothing to review", not "no items"');
  assert.ok(plan.items.every((i) => i.status === 'already-applied'));
});

test('an already-applied item carries no body', () => {
  const plan = parsePlan(fixture('plan-machine-mixed.txt'));
  const applied = plan.items.find((i) => i.status === 'already-applied');
  assert.equal(applied.body, '');
});

// The whole reason the format is delimiter-framed rather than JSON: bodies are
// literal config fragments full of braces, quotes and slashes.
test('bodies survive braces, quotes, slashes and blank lines intact', () => {
  const plan = parsePlan(fixture('plan-machine-mixed.txt'));
  const eseal = plan.items.find((i) => i.id === 'local-eseal');

  assert.match(eseal.body, /STAMP_LOCAL: \{/);
  assert.match(eseal.body, /url: "http:\/\/dmss-container-and-signature-services:8092/);
  assert.match(eseal.body, /SPRING_SECURITY_USER_PASSWORD=changeit/);
  assert.ok(eseal.body.includes('\n\n'), 'blank lines between sub-parts are preserved');
});

test('files is split into a list', () => {
  const plan = parsePlan(fixture('plan-machine-mixed.txt'));
  const eseal = plan.items.find((i) => i.id === 'local-eseal');
  assert.ok(eseal.files.includes('config/config.js'));
  assert.ok(eseal.files.includes('.env'));
  assert.ok(eseal.files.length >= 4);
});

test('tag context reports "no change" when a tag is not being bumped', () => {
  const plan = parsePlan(
    '###PLAN-BEGIN\nserver_tag_from=3.27\nserver_tag_to=3.27\n' +
    'client_tag_from=8.38\nclient_tag_to=8.39\n###PLAN-END\n'
  );
  assert.equal(plan.tags.server.changes, false);
  assert.equal(plan.tags.client.changes, true);
});

test('ignores anything outside the plan markers', () => {
  const plan = parsePlan(
    'Some unrelated script chatter\nid=not-an-item\n' +
    fixture('plan-machine-mixed.txt') +
    '\ntrailing noise\n'
  );
  assert.equal(plan.items.length, 3, 'stray key=value lines outside the markers are not items');
});

test('empty or truncated input degrades to an empty plan rather than throwing', () => {
  for (const input of ['', '###PLAN-BEGIN\n', '###PLAN-BEGIN\n###PLAN-ITEM\nid=x\n']) {
    const plan = parsePlan(input);
    assert.equal(plan.empty, true);
    assert.equal(plan.pendingCount, 0);
  }
});

// ---- upgradeArgs ----

test('buildUpgradeArgs matches the CLI flag shape and trims', () => {
  assert.deepEqual(buildUpgradeArgs({ serverTag: ' 3.28 ', clientTag: '8.39' }),
    ['--server-tag', '3.28', '--client-tag', '8.39']);
  assert.deepEqual(buildUpgradeArgs({ serverTag: '3.28' }), ['--server-tag', '3.28']);
  assert.deepEqual(buildUpgradeArgs({ enableLocalEseal: true }), ['--enable-local-eseal']);
  assert.deepEqual(buildUpgradeArgs({}), []);
});

test('validateUpgradeRequest enforces the same "at least one of" rule as the CLI', () => {
  assert.ok(validateUpgradeRequest({}));
  assert.equal(validateUpgradeRequest({ clientTag: '8.39' }), null);
  assert.equal(validateUpgradeRequest({ enableLocalEseal: true }), null);
});

// ---- planStore ----

test('a stored plan round-trips and is scoped to its session', () => {
  const id = savePlan({ plan: { items: [] }, args: ['--server-tag', '3.28'], sessionId: 'sess-a' });

  assert.deepEqual(getPlan(id, 'sess-a').args, ['--server-tag', '3.28']);
  assert.equal(getPlan(id, 'sess-b'), null, 'another session cannot read it');
  assert.equal(getPlan('nope', 'sess-a'), null);

  dropPlan(id);
  assert.equal(getPlan(id, 'sess-a'), null);
});

test('preview ids are unguessable and unique', () => {
  const ids = new Set();
  for (let i = 0; i < 50; i++) ids.add(savePlan({ plan: {}, args: [], sessionId: 's' }));
  assert.equal(ids.size, 50);
  for (const id of ids) assert.match(id, /^[0-9a-f]{18}$/);
});
