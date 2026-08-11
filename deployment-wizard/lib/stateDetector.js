'use strict';

const fs = require('fs');
const { projectPath } = require('./paths');
const { listComposeServices } = require('./dockerFacts');

const CORE_SERVICES = ['nginx', 'ps-server', 'keycloak'];

// `docker-compose.yml.bak` is the one file BOTH bootstrap.sh (step 1: backs
// up config.js, constants.json, nginx.conf, AND docker-compose.yml) and
// upgrade.sh (step 1: backs up only docker-compose.yml + config.js) always
// create — used as the "has bootstrap/upgrade ever run here" signal instead
// of string-matching a "placeholder hostname" in config.js (a pristine git
// clone already ships a filled-in, not empty, config.js with example
// values, so there's no reliable "empty" signal to key off).
//
// Deliberately NOT requiring nginx.conf.bak too (an earlier version of this
// check did): upgrade.sh never touches nginx.conf, so a deployment that's
// only ever been upgraded — never re-bootstrapped — would fail that check
// forever and permanently misreport as UNKNOWN even right after a
// successful wizard-driven upgrade. Confirmed against a real deployment.
function backupFilesExist() {
  return fs.existsSync(projectPath('docker-compose.yml.bak'));
}

async function detectState() {
  const hasRunBefore = backupFilesExist();
  const services = await listComposeServices();
  const runningNames = new Set(
    services
      .filter((s) => (s.State || s.Status || '').toLowerCase().startsWith('running'))
      .map((s) => s.Service || s.Name)
  );
  const coreUp = CORE_SERVICES.every((name) => runningNames.has(name));

  let state;
  if (!hasRunBefore && !coreUp) {
    state = 'FRESH';
  } else if (hasRunBefore && coreUp) {
    state = 'DEPLOYED';
  } else if (hasRunBefore && !coreUp) {
    state = 'DEPLOYED_STOPPED';
  } else {
    // containers running but no .bak files — stack was likely configured
    // manually, outside these scripts. Advisory dashboard only; don't
    // offer "resume onboarding" over a deployment the wizard didn't make.
    state = 'UNKNOWN';
  }

  return { state, hasRunBefore, coreUp, runningServices: Array.from(runningNames) };
}

module.exports = { detectState };
