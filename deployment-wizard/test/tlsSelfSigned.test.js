'use strict';

const test = require('node:test');
const assert = require('node:assert');
const os = require('os');

const { collectSubjectAltNames, generateSelfSignedCert, SAN_ENV_VAR } = require('../lib/tlsSelfSigned');

function withEnv(value, fn) {
  const previous = process.env[SAN_ENV_VAR];
  if (value === undefined) delete process.env[SAN_ENV_VAR];
  else process.env[SAN_ENV_VAR] = value;
  try {
    return fn();
  } finally {
    if (previous === undefined) delete process.env[SAN_ENV_VAR];
    else process.env[SAN_ENV_VAR] = previous;
  }
}

test('always covers localhost and 127.0.0.1', () => {
  const { dnsNames, ipAddresses } = withEnv(undefined, () => collectSubjectAltNames());
  assert.ok(dnsNames.includes('localhost'));
  assert.ok(ipAddresses.includes('127.0.0.1'));
});

test('includes the machine hostname', () => {
  const { dnsNames } = withEnv(undefined, () => collectSubjectAltNames());
  assert.ok(dnsNames.includes(os.hostname()));
});

test('includes the already-configured deployment hostname when given one', () => {
  const { dnsNames } = withEnv(undefined, () => collectSubjectAltNames('padsign.client.com'));
  assert.ok(dnsNames.includes('padsign.client.com'));
});

// The operator-supplied list is the only thing that can cover the HOST's
// address when the wizard runs in a container — see lib/tlsSelfSigned.js.
test('parses WIZARD_TLS_SANS into the right bucket, tolerating whitespace', () => {
  const { dnsNames, ipAddresses } = withEnv(' 10.0.0.42 , padsign-host.internal ,, ', () =>
    collectSubjectAltNames()
  );
  assert.ok(ipAddresses.includes('10.0.0.42'), 'IPv4 goes in the IP bucket');
  assert.ok(dnsNames.includes('padsign-host.internal'), 'name goes in the DNS bucket');
  assert.ok(!dnsNames.includes(''), 'empty entries are dropped');
});

// node-forge's SAN type-7 encoding is unreliable for IPv6; an IPv6-literal
// URL still matches the "localhost" DNS entry, so dropping them is safe.
test('drops IPv6 entries rather than emitting an unencodable SAN', () => {
  const { dnsNames, ipAddresses } = withEnv('fe80::1', () => collectSubjectAltNames());
  assert.ok(!ipAddresses.includes('fe80::1'));
  assert.ok(!dnsNames.includes('fe80::1'), 'must not be misfiled as a DNS name either');
});

test('generates a usable keypair carrying the requested SANs', () => {
  const result = withEnv('10.0.0.42', () => generateSelfSignedCert({ extraHost: 'padsign.client.com' }));
  assert.match(result.key, /BEGIN (RSA )?PRIVATE KEY/);
  assert.match(result.cert, /BEGIN CERTIFICATE/);
  assert.ok(result.dnsNames.includes('padsign.client.com'));
  assert.ok(result.ipAddresses.includes('10.0.0.42'));
});
