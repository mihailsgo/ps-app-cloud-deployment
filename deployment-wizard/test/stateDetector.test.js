'use strict';

const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');

// Regression test for a real bug found E2E-testing against a live deployment:
// a checkout that has only ever been upgraded (never re-bootstrapped) has
// docker-compose.yml.bak but NOT nginx/nginx.conf.bak (upgrade.sh never
// touches nginx.conf) — the old check required both and so misreported
// UNKNOWN forever, even immediately after a successful wizard-driven
// upgrade. docker (or docker compose) isn't expected to be reachable for
// these fixture dirs, so `coreUp` is always false here — that's fine, these
// cases only exercise the `hasRunBefore` half of the state matrix.

test('reports FRESH when no docker-compose.yml.bak exists', async () => {
  process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'state-fresh');
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/stateDetector')];
  const { detectState } = require('../lib/stateDetector');

  const result = await detectState();
  assert.equal(result.hasRunBefore, false);
  assert.equal(result.state, 'FRESH');
});

test('reports hasRunBefore=true from docker-compose.yml.bak alone (no nginx.conf.bak needed)', async () => {
  process.env.HOST_PROJECT_DIR = path.join(__dirname, 'fixtures', 'state-upgraded-only');
  delete require.cache[require.resolve('../lib/paths')];
  delete require.cache[require.resolve('../lib/stateDetector')];
  const { detectState } = require('../lib/stateDetector');

  const result = await detectState();
  assert.equal(result.hasRunBefore, true);
  // coreUp is false here (no real containers named nginx/ps-server/keycloak
  // under this fixture dir), so this lands on DEPLOYED_STOPPED rather than
  // DEPLOYED — the point of this test is hasRunBefore alone, not coreUp.
  assert.equal(result.state, 'DEPLOYED_STOPPED');
});
