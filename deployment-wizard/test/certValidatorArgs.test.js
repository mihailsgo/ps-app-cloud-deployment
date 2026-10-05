'use strict';

// Asserts the exact argument list validate-certs.sh receives from each caller.
// The script is replaced by a stub (via HOST_PROJECT_DIR) that records its argv,
// so no openssl is needed for the argument tests.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wiz-certargs-'));
process.env.HOST_PROJECT_DIR = root;

const test = require('node:test');
const assert = require('node:assert/strict');
const { validateCert, checkLiveCert } = require('../lib/certValidator');

const HOST = 'padsign.example.com';
const argsFile = path.join(root, 'argv.txt');

fs.mkdirSync(path.join(root, 'installation-scripts'), { recursive: true });
fs.mkdirSync(path.join(root, 'nginx', 'certs'), { recursive: true });
fs.writeFileSync(
  path.join(root, 'installation-scripts', 'validate-certs.sh'),
  [
    '#!/usr/bin/env bash',
    `printf '%s\\n' "$@" > '${argsFile.split(path.sep).join('/')}'`,
    "echo '  OK   stub'",
    ''
  ].join('\n')
);
fs.writeFileSync(path.join(root, 'nginx', 'certs', `${HOST}.crt`), 'x');
fs.writeFileSync(path.join(root, 'nginx', 'certs', `${HOST}.key`), 'x');

test.after(() => fs.rmSync(root, { recursive: true, force: true }));

function recordedArgs() {
  return fs.readFileSync(argsFile, 'utf8').split('\n').filter(Boolean);
}

test('checkLiveCert() never passes --allow-self-signed', async () => {
  await checkLiveCert(HOST);
  const args = recordedArgs();
  assert.deepEqual(args, [
    '--host', HOST,
    '--cert-crt', path.join(root, 'nginx', 'certs', `${HOST}.crt`),
    '--cert-key', path.join(root, 'nginx', 'certs', `${HOST}.key`)
  ]);
  assert.ok(!args.includes('--allow-self-signed'));
});

test('validateCert() passes --allow-self-signed only when asked', async () => {
  const staged = [
    '--host', HOST,
    '--cert-crt', path.join(root, 'installation-scripts', 'certs', `${HOST}.crt`),
    '--cert-key', path.join(root, 'installation-scripts', 'certs', `${HOST}.key`)
  ];

  await validateCert({ host: HOST, crtText: 'c', keyText: 'k', allowSelfSigned: true });
  assert.deepEqual(recordedArgs(), [...staged, '--allow-self-signed']);

  await validateCert({ host: HOST, crtText: 'c', keyText: 'k', allowSelfSigned: false });
  assert.deepEqual(recordedArgs(), staged);
});

// End to end against the real script: a genuinely self-signed live
// certificate must still produce an honest WARN, not a clean pass.
const hasOpenssl = spawnSync('openssl', ['version']).status === 0;

test('checkLiveCert(): a self-signed live certificate gets a self-signed warning', { skip: !hasOpenssl }, async () => {
  const realRoot = path.join(__dirname, '..', '..');
  fs.copyFileSync(
    path.join(realRoot, 'installation-scripts', 'validate-certs.sh'),
    path.join(root, 'installation-scripts', 'validate-certs.sh')
  );
  const crt = path.join(root, 'nginx', 'certs', `${HOST}.crt`);
  const key = path.join(root, 'nginx', 'certs', `${HOST}.key`);
  const gen = spawnSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '90',
    '-subj', `/CN=${HOST}`, '-addext', `subjectAltName=DNS:${HOST}`,
    '-keyout', key, '-out', crt
  ], { env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
  assert.equal(gen.status, 0, String(gen.stderr));

  const result = await checkLiveCert(HOST);
  const messages = result.checks.map((c) => `${c.status}: ${c.message}`).join('\n');
  assert.ok(result.checks.some((c) => c.status === 'warn' && /self-signed/.test(c.message)), messages);
  assert.ok(!result.checks.some((c) => /chain verification skipped/.test(c.message)), messages);
  assert.ok(!result.checks.some((c) => c.status === 'fail'), messages);
});
