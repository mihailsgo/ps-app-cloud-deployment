'use strict';

const path = require('path');
process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'release-snapshot-fixture');

const test = require('node:test');
const assert = require('node:assert/strict');
const { readLatestKnownTags } = require('../lib/dockerFacts');

test('readLatestKnownTags() reads the approved tags from release/approved-digests.json', () => {
  const tags = readLatestKnownTags();
  assert.equal(tags.serverTag, '9.9');
  assert.equal(tags.clientTag, '1.1');
});

test('readLatestKnownTags() returns nulls, never throws, when the file is missing', () => {
  process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'state-fresh');
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/dockerFacts')];
  const { readLatestKnownTags: reread } = require('../lib/dockerFacts');
  const tags = reread();
  assert.equal(tags.serverTag, null);
  assert.equal(tags.clientTag, null);
});

function loadDockerFactsAgainst(fixtureName) {
  process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', fixtureName);
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/dockerFacts')];
  return require('../lib/dockerFacts');
}

test('readConfiguredFeatures(): everything on, profile active', () => {
  const { readConfiguredFeatures } = loadDockerFactsAgainst('features-full-fixture');
  const f = readConfiguredFeatures();
  assert.equal(f.routing, true);
  assert.equal(f.demo, true);
  assert.equal(f.localEseal, true);
  assert.equal(f.localEsealProfileActive, true);
});

test('readConfiguredFeatures(): everything off', () => {
  const { readConfiguredFeatures } = loadDockerFactsAgainst('features-off-fixture');
  const f = readConfiguredFeatures();
  assert.equal(f.routing, false);
  assert.equal(f.demo, false);
  assert.equal(f.localEseal, false);
  assert.equal(f.localEsealProfileActive, false);
});

test('readConfiguredFeatures(): config.js readable but fields never configured -> null, not a guess', () => {
  const { readConfiguredFeatures } = loadDockerFactsAgainst('features-partial-fixture');
  const f = readConfiguredFeatures();
  assert.equal(f.routing, null, 'no DOCUMENT_ROUTING field at all means "can\'t tell", not false');
  assert.equal(f.demo, null, 'constants.json missing entirely means "can\'t tell"');
  assert.equal(f.localEseal, false, 'no STAMP_MODE field is a definite "not local", not unknown');
  assert.equal(f.localEsealProfileActive, false);
});

test('readConfiguredFeatures(): never throws on malformed constants.json', () => {
  const { readConfiguredFeatures } = loadDockerFactsAgainst('features-malformed-fixture');
  assert.doesNotThrow(() => readConfiguredFeatures());
  const f = readConfiguredFeatures();
  assert.equal(f.routing, true);
  assert.equal(f.demo, null);
});

test('readConfiguredFeatures(): never throws when every source file is missing', () => {
  const { readConfiguredFeatures } = loadDockerFactsAgainst('state-fresh');
  assert.doesNotThrow(() => readConfiguredFeatures());
  const f = readConfiguredFeatures();
  assert.equal(f.routing, null);
  assert.equal(f.demo, null);
  assert.equal(f.localEseal, null);
  assert.equal(f.localEsealProfileActive, false);
});

test('readConfiguredCompanyRole(): reads DEMO_COMPANY_ROLE, including multi-word names', () => {
  const { readConfiguredCompanyRole } = loadDockerFactsAgainst('features-full-fixture');
  assert.equal(readConfiguredCompanyRole(), 'Acme Corp');
});

test('readConfiguredCompanyRole(): returns null (not throw) when absent or file missing', () => {
  const partial = loadDockerFactsAgainst('features-partial-fixture');
  assert.equal(partial.readConfiguredCompanyRole(), null);

  const fresh = loadDockerFactsAgainst('state-fresh');
  assert.equal(fresh.readConfiguredCompanyRole(), null);
});

// ---- unreadableComposeFiles ----

test('unreadableComposeFiles(): the COMPOSE_FILE entries that do not exist here, none when unset', (t) => {
  const os = require('os');
  const fs = require('fs');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'wizard-compose-file-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const saved = { COMPOSE_FILE: process.env.COMPOSE_FILE, COMPOSE_PATH_SEPARATOR: process.env.COMPOSE_PATH_SEPARATOR };
  delete process.env.COMPOSE_FILE;
  delete process.env.COMPOSE_PATH_SEPARATOR;
  t.after(() => {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  });
  fs.writeFileSync(path.join(dir, 'docker-compose.yml'), 'services: {}\n');
  const present = path.join(dir, 'present.yml');
  fs.writeFileSync(present, 'services: {}\n');
  const gone = path.join(dir, 'overlay', 'compose.overlay.yml');

  process.env.HOST_PROJECT_DIR = dir;
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/dockerFacts')];
  const { unreadableComposeFiles } = require('../lib/dockerFacts');

  assert.deepEqual(unreadableComposeFiles(), [], 'no .env');
  fs.writeFileSync(path.join(dir, '.env'), `COMPOSE_PROJECT_NAME=padsign\nCOMPOSE_FILE="docker-compose.yml${path.delimiter}${present}${path.delimiter}${gone}"\n`);
  assert.deepEqual(unreadableComposeFiles(), [gone], 'relative entries resolve against the project directory');

  fs.writeFileSync(path.join(dir, '.env'), `COMPOSE_PATH_SEPARATOR=,\nCOMPOSE_FILE=docker-compose.yml,missing.yml\n`);
  assert.deepEqual(unreadableComposeFiles(), ['missing.yml'], 'COMPOSE_PATH_SEPARATOR is honoured');

  process.env.COMPOSE_FILE = 'docker-compose.yml';
  assert.deepEqual(unreadableComposeFiles(), [], 'the environment wins over .env, as in docker compose');
});
