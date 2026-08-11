'use strict';

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');
const execFileP = promisify(execFile);

const { HOST_PROJECT_DIR, projectPath } = require('./paths');
const { parseHelperCheckOutput } = require('./outputParser');

const VALIDATE_CERTS_SCRIPT = projectPath('installation-scripts', 'validate-certs.sh');
const VERIFY_SERVED_CERT_SCRIPT = projectPath('installation-scripts', 'verify-served-cert.sh');

// Writes the uploaded cert/key to the EXACT default path
// bootstrap.sh/configure-host.sh already resolve to
// (installation-scripts/certs/<host>.crt|.key) — no new file-layout
// convention invented, and step 6's real bootstrap.sh run will find them
// there without the wizard needing to pass --cert-crt/--cert-key explicitly.
function certPathsFor(host) {
  const dir = projectPath('installation-scripts', 'certs');
  return {
    dir,
    crtPath: path.join(dir, `${host}.crt`),
    keyPath: path.join(dir, `${host}.key`)
  };
}

// Shared plumbing for both validateCert() (onboarding upload) and
// checkLiveCert() (Settings — status of what's already deployed): spawn
// validate-certs.sh and parse its OK/FAIL/WARN output. Exit code 1 means
// "a check failed" (expected input, not a wizard bug); anything else
// (arg-parse error, missing bash/script) is a real error and rethrown.
async function runValidateCerts({ host, crtPath, keyPath, allowSelfSigned }) {
  const args = ['--host', host, '--cert-crt', crtPath, '--cert-key', keyPath];
  if (allowSelfSigned) args.push('--allow-self-signed');

  let stdout;
  try {
    const result = await execFileP('bash', [VALIDATE_CERTS_SCRIPT, ...args], {
      cwd: HOST_PROJECT_DIR,
      timeout: 30000,
      maxBuffer: 4 * 1024 * 1024
    });
    stdout = result.stdout;
  } catch (err) {
    if (typeof err.code === 'number' && err.code === 1 && typeof err.stdout === 'string') {
      stdout = err.stdout;
    } else {
      throw err;
    }
  }

  return parseHelperCheckOutput(stdout);
}

async function validateCert({ host, crtText, keyText, allowSelfSigned }) {
  if (!host || !crtText || !keyText) {
    throw new Error('host, crtText, and keyText are all required');
  }

  const { dir, crtPath, keyPath } = certPathsFor(host);
  fs.mkdirSync(dir, { recursive: true });
  // Normalize CRLF -> LF: a pasted-from-Windows cert/key with stray \r
  // breaks openssl's PEM parsing in ways that produce confusing errors.
  fs.writeFileSync(crtPath, crtText.replace(/\r\n/g, '\n'), { mode: 0o600 });
  fs.writeFileSync(keyPath, keyText.replace(/\r\n/g, '\n'), { mode: 0o600 });

  const parsed = await runValidateCerts({ host, crtPath, keyPath, allowSelfSigned });
  return { ...parsed, host, crtPath, keyPath };
}

// The DEPLOYED path — what nginx actually serves (nginx/certs/<host>.crt|.key)
// — as distinct from certPathsFor()'s upload-staging path
// (installation-scripts/certs/<host>.crt|.key), which is only ever an input
// TO configure-host.sh, never what's live.
function deployedCertPathsFor(host) {
  const dir = projectPath('nginx', 'certs');
  return {
    dir,
    crtPath: path.join(dir, `${host}.crt`),
    keyPath: path.join(dir, `${host}.key`)
  };
}

// Read-only status check for the Settings page: re-runs validate-certs.sh
// against whatever cert is CURRENTLY deployed, with no upload — powers the
// "current cert expiry/status" display on page load. allowSelfSigned
// defaults true here (unlike validateCert()) because this is purely
// informational: an already-live self-signed cert isn't something the
// operator can "fix" by re-uploading right now, so surfacing a hard FAIL
// for the one check they can't act on would just be noise.
async function checkLiveCert(host) {
  if (!host) throw new Error('host is required');
  const { crtPath, keyPath } = deployedCertPathsFor(host);

  if (!fs.existsSync(crtPath) || !fs.existsSync(keyPath)) {
    return {
      passed: false,
      checks: [{ status: 'warn', message: `No certificate found at nginx/certs/${host}.{crt,key}.` }],
      raw: '',
      host,
      crtPath,
      keyPath
    };
  }

  const parsed = await runValidateCerts({ host, crtPath, keyPath, allowSelfSigned: true });
  return { ...parsed, host, crtPath, keyPath };
}

// Read-only wire check for the Settings page: what is nginx ACTUALLY serving?
// checkLiveCert() above reads the FILE on disk, which is necessary but not
// sufficient — nginx reads its certificate files only at startup and on
// reload, so a renewed file can sit unserved indefinitely while every
// file-level check passes. See documentation/11-02.
//
// Two deliberate differences from runValidateCerts():
//
//  1. --connect nginx:443 is passed explicitly. scriptRunner/this process run
//     INSIDE the wizard container, where localhost:443 is nothing at all —
//     nginx is reachable only by its compose service name. (The nginx service's
//     network alias is the repo's baseline hostname, which configure-host.sh
//     never rewrites, so the alias is not a usable target either.)
//
//  2. It NEVER rethrows. runValidateCerts() rethrows anything that isn't exit
//     1, which is right for an upload flow but wrong here: GET /settings does
//     next(err), so a missing script (exit 127, when a newer wizard image runs
//     against an older repo checkout) or an execFile timeout would take the
//     whole Settings page down instead of degrading one card.
async function checkServedCert(host) {
  if (!host) throw new Error('host is required');

  const args = ['--host', host, '--connect', 'nginx:443', '--retries', '1'];

  try {
    const result = await execFileP('bash', [VERIFY_SERVED_CERT_SCRIPT, ...args], {
      cwd: HOST_PROJECT_DIR,
      timeout: 12000,
      maxBuffer: 4 * 1024 * 1024
    });
    return { ...parseHelperCheckOutput(result.stdout), host };
  } catch (err) {
    if (typeof err.code === 'number' && err.code === 1 && typeof err.stdout === 'string') {
      return { ...parseHelperCheckOutput(err.stdout), host };
    }
    // Degrade to a single warn row rather than failing the page render.
    return {
      passed: false,
      checks: [{
        status: 'warn',
        message: 'Could not determine what nginx is currently serving (verify-served-cert.sh did not complete).'
      }],
      raw: typeof err.stdout === 'string' ? err.stdout : '',
      host
    };
  }
}

module.exports = { validateCert, certPathsFor, checkLiveCert, deployedCertPathsFor, checkServedCert };
