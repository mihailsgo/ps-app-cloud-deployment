'use strict';

const { detectState } = require('./stateDetector');
const { readImageTags, readConfiguredHost } = require('./dockerFacts');
const { isRunActive } = require('./scriptRunner');

// Single place computing everything the shared topbar partial needs, so
// every route doesn't re-derive "hasCompletedSetup"/"hostname"/etc. its own
// way. Stateless (decision #8) — re-derived from live files/docker/session
// on every call, same as everything else in this app.
async function getTopbarContext(wizard) {
  const [state, tags] = await Promise.all([detectState(), Promise.resolve(readImageTags())]);
  const hostname = (wizard && wizard.host) || readConfiguredHost() || 'padsign.trustlynx.local';
  const version = tags.serverTag && tags.clientTag ? `${tags.serverTag}/${tags.clientTag}` : null;

  return {
    hostname,
    version,
    hasCompletedSetup: state.state !== 'FRESH',
    runActive: isRunActive()
  };
}

module.exports = { getTopbarContext };
