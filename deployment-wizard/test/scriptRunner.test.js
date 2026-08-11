'use strict';

const path = require('path');
// Must be set before requiring lib/paths (directly or transitively) —
// it's read once at module-load time.
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'fake-repo');

const test = require('node:test');
const assert = require('node:assert/strict');
const { startRun, subscribe, getRun } = require('../lib/scriptRunner');

function waitForDone(runId) {
  return new Promise((resolve) => {
    const events = [];
    subscribe(runId, (item) => {
      events.push(item);
      if (item.event === 'done') resolve(events);
    });
  });
}

test('runs a fixture script, classifies steps/checks/warnings, and reports success', async () => {
  const runId = startRun({ scriptName: 'fake-multistep.sh', args: [] });
  const events = await waitForDone(runId);

  const steps = events.filter((e) => e.event === 'step');
  assert.equal(steps.length, 3);
  assert.equal(steps[0].data.step, '1');
  assert.equal(steps[0].data.total, 3);
  assert.equal(steps[0].data.label, 'doing thing one');

  const checks = events.filter((e) => e.event === 'check');
  assert.ok(checks.some((c) => c.data.status === 'ok' && c.data.label === 'sub-check one'));

  const warnings = events.filter((e) => e.event === 'warning');
  assert.ok(warnings.some((w) => w.data.message === 'something minor'));

  const done = events.find((e) => e.event === 'done');
  assert.equal(done.data.success, true);
  assert.equal(done.data.exitCode, 0);

  const state = getRun(runId);
  assert.equal(state.done, true);
});

test('reports failure with the ERROR message surfaced', async () => {
  const runId = startRun({ scriptName: 'fake-multistep-fail.sh', args: [] });
  const events = await waitForDone(runId);

  const errors = events.filter((e) => e.event === 'error');
  assert.ok(errors.some((e) => e.data.message === 'things broke'));

  const done = events.find((e) => e.event === 'done');
  assert.equal(done.data.success, false);
  assert.notEqual(done.data.exitCode, 0);
});

test('refuses to start a second run while one is active', async () => {
  const runId = startRun({ scriptName: 'fake-multistep.sh', args: [] });
  assert.throws(
    () => startRun({ scriptName: 'fake-multistep.sh', args: [] }),
    (err) => err.code === 'RUN_IN_PROGRESS'
  );
  await waitForDone(runId); // let it finish so it doesn't leak into the next test
});

test('a late subscriber replays buffered events instead of missing them', async () => {
  const runId = startRun({ scriptName: 'fake-multistep.sh', args: [] });
  // give it a head start so some events are already buffered before we subscribe
  await new Promise((r) => setTimeout(r, 50));
  const events = await waitForDone(runId);
  assert.ok(events.some((e) => e.event === 'step' && e.data.step === '1'));
  assert.ok(events.some((e) => e.event === 'done'));
});
