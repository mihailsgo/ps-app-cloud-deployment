'use strict';

const https = require('https');
const { createApp } = require('./app');
const { generateSelfSignedCert, SAN_ENV_VAR } = require('./lib/tlsSelfSigned');
const { getAccessToken } = require('./lib/auth');
const { readConfiguredHost } = require('./lib/dockerFacts');
const defaults = require('./config/defaults');

// On a return visit this deployment already has a hostname; including it in
// the wizard cert means reaching the wizard at that same name doesn't add a
// name-mismatch error on top of the expected self-signed warning.
let configuredHost = null;
try {
  configuredHost = readConfiguredHost();
} catch (err) {
  // Nothing configured yet (fresh checkout) — not an error.
}

const { key, cert, dnsNames, ipAddresses } = generateSelfSignedCert({ extraHost: configuredHost });
const app = createApp();

https.createServer({ key, cert }, app).listen(defaults.port, () => {
  console.log('========================================');
  console.log('PadSign Deployment Wizard');
  console.log(`  Listening on https://<this-host>:${defaults.port}`);
  console.log(`  Access token: ${getAccessToken()}`);
  console.log('  (regenerated every container start — copy it into the browser to unlock)');
  console.log('');
  console.log('  Certificate valid for:');
  console.log(`    names: ${dnsNames.join(', ')}`);
  console.log(`    IPs:   ${ipAddresses.join(', ')}`);
  console.log(`  Reaching the wizard at an address not listed above adds a`);
  console.log(`  name-mismatch error on top of the expected self-signed warning.`);
  console.log(`  Set ${SAN_ENV_VAR} to add more (see docker-compose.yml).`);
  console.log('========================================');
});
