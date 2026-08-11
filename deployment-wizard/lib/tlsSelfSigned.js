'use strict';

const net = require('net');
const os = require('os');
const selfsigned = require('selfsigned');

// Generates a throwaway HTTPS cert for the wizard's OWN admin UI. This is
// independent of the real PadSign hostname cert the operator uploads in
// step 3 — the wizard needs HTTPS before that cert exists (chicken-and-egg),
// so it never touches installation-scripts/certs/ and is regenerated fresh
// on every container start (nothing persists it to disk).
//
// The browser will always warn (the cert is self-signed, by design). The
// point of the SAN list below is to keep that warning at the milder
// "untrusted issuer" level — which every browser lets you click past —
// rather than escalating it to a NAME MISMATCH, which some mobile browsers
// refuse to bypass at all. An earlier version listed only localhost and
// 127.0.0.1, so every operator reaching the wizard at its real address
// (i.e. all of them, since the documented flow is opening it from a laptop)
// hit the harsher variant.

// Operators reach a containerised wizard at the *host's* address, which the
// container can't discover for itself — os.networkInterfaces() inside a
// container returns the bridge IP, not the host's LAN IP. WIZARD_TLS_SANS is
// the only thing that can cover that case; see docker-compose.yml.
const SAN_ENV_VAR = 'WIZARD_TLS_SANS';

function collectSubjectAltNames(extraHost) {
  const dnsNames = new Set(['localhost']);
  // IPv4 only: node-forge's IP encoding for SAN type 7 is unreliable for
  // IPv6, and an IPv6-literal URL is a negligible case — reaching the wizard
  // over ::1 still matches on the "localhost" DNS entry.
  const ipAddresses = new Set(['127.0.0.1']);

  const hostname = os.hostname();
  if (hostname) dnsNames.add(hostname);

  const interfaces = os.networkInterfaces();
  for (const addresses of Object.values(interfaces)) {
    for (const addr of addresses || []) {
      if (!addr.internal && net.isIPv4(addr.address)) ipAddresses.add(addr.address);
    }
  }

  // The hostname this deployment is already configured for, when there is
  // one — makes the wizard reachable warning-free-ish at the same address
  // the operator uses for PadSign itself on a return visit.
  if (extraHost) dnsNames.add(extraHost);

  for (const raw of String(process.env[SAN_ENV_VAR] || '').split(',')) {
    const value = raw.trim();
    if (!value) continue;
    if (net.isIPv4(value)) ipAddresses.add(value);
    else if (net.isIPv6(value)) continue; // see IPv4-only note above
    else dnsNames.add(value);
  }

  return { dnsNames: Array.from(dnsNames), ipAddresses: Array.from(ipAddresses) };
}

function generateSelfSignedCert(options) {
  const { extraHost } = options || {};
  const { dnsNames, ipAddresses } = collectSubjectAltNames(extraHost);

  const attrs = [{ name: 'commonName', value: dnsNames[0] }];
  const pems = selfsigned.generate(attrs, {
    days: 3650,
    keySize: 2048,
    extensions: [
      { name: 'basicConstraints', cA: false },
      {
        name: 'subjectAltName',
        altNames: [
          ...dnsNames.map((value) => ({ type: 2, value })),
          ...ipAddresses.map((ip) => ({ type: 7, ip }))
        ]
      }
    ]
  });

  return { key: pems.private, cert: pems.cert, dnsNames, ipAddresses };
}

module.exports = { generateSelfSignedCert, collectSubjectAltNames, SAN_ENV_VAR };
