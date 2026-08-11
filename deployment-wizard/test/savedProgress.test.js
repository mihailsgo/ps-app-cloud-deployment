'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const test = require('node:test');
const assert = require('node:assert/strict');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wizard-saved-progress-'));
process.env.HOST_PROJECT_DIR = tmpDir;
delete require.cache[require.resolve('../lib/paths')];
delete require.cache[require.resolve('../lib/savedProgress')];
const { saveProgress, loadProgress, clearProgress, hasSavedProgress } = require('../lib/savedProgress');

const SAMPLE_WIZARD = {
  host: 'padsign.example.com',
  companyRole: 'Acme Corp',
  adminUser: 'admin',
  adminPass: 'ShouldNeverBePersisted!',
  realm: 'padsign',
  allowSelfSigned: true,
  cert: { validated: true, host: 'padsign.example.com', crtPath: '/x.crt', keyPath: '/x.key', checks: [] },
  features: { enable_routing: true, enable_demo: false, enable_local_eseal: false },
  furthestStepReached: 5
};

test('hasSavedProgress() is false before any save', () => {
  assert.equal(hasSavedProgress(), false);
});

test('saveProgress() persists everything except adminPass', () => {
  saveProgress(SAMPLE_WIZARD, 5);
  assert.equal(hasSavedProgress(), true);

  const loaded = loadProgress();
  assert.equal(loaded.host, 'padsign.example.com');
  assert.equal(loaded.companyRole, 'Acme Corp');
  assert.equal(loaded.furthestStepReached, 5);
  assert.equal(loaded.step, 5);
  assert.equal('adminPass' in loaded, false, 'adminPass must never be written to the saved-progress file');
});

test('clearProgress() removes the file', () => {
  clearProgress();
  assert.equal(hasSavedProgress(), false);
  assert.equal(loadProgress(), null);
});

test('loadProgress() returns null (not throw) when the file is missing or corrupt', () => {
  assert.equal(loadProgress(), null);
  fs.writeFileSync(path.join(tmpDir, '.wizard-saved-progress.json'), 'not valid json{{{');
  assert.equal(loadProgress(), null);
  fs.unlinkSync(path.join(tmpDir, '.wizard-saved-progress.json'));
});
