'use strict';

const express = require('express');
const fs = require('fs');
const multer = require('multer');

const { ensureWizardSession } = require('../lib/wizardSession');
const { getTopbarContext } = require('../lib/topbarContext');
const {
  readConfiguredHost,
  readConfiguredFeatures
} = require('../lib/dockerFacts');
const { validateCert, certPathsFor, checkLiveCert, deployedCertPathsFor, checkServedCert } = require('../lib/certValidator');
const { startRun, getRun, isRunActive, getActiveRunId } = require('../lib/scriptRunner');
const defaults = require('../config/defaults');

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 1024 * 1024 } });
const router = express.Router();

// Everything below reads LIVE state (readConfiguredHost/readConfiguredFeatures/
// checkLiveCert), never the onboarding session — Settings is reached long
// after that session may have expired (2-hour TTL) or the operator logged
// in fresh, matching the same "derive from disk, never from session alone"
// rule dashboard.js already follows (decision #8).

router.get('/settings', async (req, res, next) => {
  try {
    const wizard = ensureWizardSession(req);
    const host = readConfiguredHost();
    // servedCert is the over-the-wire counterpart to cert: checkLiveCert()
    // reads the FILE at nginx/certs/, checkServedCert() asks nginx what it is
    // actually presenting. They can legitimately disagree, and that
    // disagreement is the whole point — see documentation/11-02.
    const [topbar, cert, servedCert] = await Promise.all([
      getTopbarContext(wizard),
      host ? checkLiveCert(host) : Promise.resolve(null),
      host ? checkServedCert(host) : Promise.resolve(null)
    ]);
    res.render('settings', {
      host,
      features: readConfiguredFeatures(),
      cert,
      servedCert,
      runActive: isRunActive(),
      activeRunId: getActiveRunId(),
      ...topbar
    });
  } catch (err) {
    next(err);
  }
});

router.get('/settings/progress', async (req, res, next) => {
  try {
    const runId = String(req.query.runId || '');
    if (!runId || !getRun(runId)) return res.redirect('/settings');
    const wizard = ensureWizardSession(req);
    const topbar = await getTopbarContext(wizard);
    res.render('settings-progress', { runId, ...topbar });
  } catch (err) {
    next(err);
  }
});

// ---- Hostname change ----

// Validates a candidate cert against the NEW hostname (not the current
// one) and stages it at installation-scripts/certs/<newHost>.{crt,key} —
// the exact default path update-hostname.sh's configure-host.sh call will
// resolve to with no explicit --cert-crt/--cert-key args, same convention
// bootstrap.sh already relies on for onboarding.
router.post(
  '/api/settings/hostname/cert-upload',
  upload.fields([{ name: 'crtFile', maxCount: 1 }, { name: 'keyFile', maxCount: 1 }]),
  async (req, res) => {
    const newHost = String(req.body.newHost || '').trim();
    if (!newHost) return res.status(400).json({ error: 'newHost is required.' });

    const files = req.files || {};
    const crtText = files.crtFile ? files.crtFile[0].buffer.toString('utf8') : req.body.crtText;
    const keyText = files.keyFile ? files.keyFile[0].buffer.toString('utf8') : req.body.keyText;
    const allowSelfSigned = req.body.allowSelfSigned === 'on' || req.body.allowSelfSigned === 'true';

    if (!crtText || !keyText) {
      return res.status(400).json({ error: 'Both a certificate and a private key are required (file or pasted text).' });
    }

    try {
      const result = await validateCert({ host: newHost, crtText, keyText, allowSelfSigned });
      res.json({ passed: result.passed, checks: result.checks });
    } catch (err) {
      console.error('Cert validation failed to run:', err);
      res.status(500).json({ error: 'Could not run certificate validation — check `docker logs padsign-wizard`.' });
    }
  }
);

router.post('/api/settings/hostname', async (req, res) => {
  const body = req.body || {};
  const newHost = String(body.newHost || '').trim();
  const adminPass = body.adminPass;
  const adminUser = body.adminUser ? String(body.adminUser).trim() : 'admin';
  const allowSelfSigned = Boolean(body.allowSelfSigned);
  const reuseCurrentCert = Boolean(body.reuseCurrentCert);

  if (!newHost || !adminPass) {
    return res.status(400).json({ error: 'New hostname and the current Keycloak admin password are both required.' });
  }

  const { crtPath: stagedCrt, keyPath: stagedKey } = certPathsFor(newHost);

  if (reuseCurrentCert) {
    const currentHost = readConfiguredHost();
    if (!currentHost) {
      return res.status(400).json({ error: 'Could not determine the current hostname to copy a certificate from.' });
    }
    const { crtPath: liveCrt, keyPath: liveKey } = deployedCertPathsFor(currentHost);
    if (!fs.existsSync(liveCrt) || !fs.existsSync(liveKey)) {
      return res.status(400).json({ error: `No live certificate found for ${currentHost} to reuse.` });
    }
    try {
      const crtText = fs.readFileSync(liveCrt, 'utf8');
      const keyText = fs.readFileSync(liveKey, 'utf8');
      // Re-validate the EXISTING cert against the NEW hostname — refuse if
      // it doesn't actually cover it (e.g. not a wildcard/multi-SAN cert),
      // rather than trusting the "reuse" checkbox blindly.
      const result = await validateCert({ host: newHost, crtText, keyText, allowSelfSigned: true });
      if (!result.passed) {
        return res.status(400).json({
          error: `The existing certificate does not appear to cover ${newHost}.`,
          checks: result.checks
        });
      }
    } catch (err) {
      console.error('Cert reuse validation failed:', err);
      return res.status(500).json({ error: 'Could not validate the existing certificate against the new hostname.' });
    }
  } else if (!fs.existsSync(stagedCrt) || !fs.existsSync(stagedKey)) {
    return res.status(400).json({ error: `Upload and validate a certificate for ${newHost} first.` });
  }

  const args = ['--host', newHost, '--admin-pass', adminPass, '--admin-user', adminUser, '--realm', defaults.realm];
  if (allowSelfSigned) args.push('--allow-self-signed');

  try {
    const runId = startRun({ scriptName: 'update-hostname.sh', args });
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message });
    }
    console.error('Failed to start hostname update:', err);
    res.status(500).json({ error: 'Failed to start hostname update — check `docker logs padsign-wizard`.' });
  }
});

// ---- TLS certificate renewal ----

router.post(
  '/api/settings/cert/upload',
  upload.fields([{ name: 'crtFile', maxCount: 1 }, { name: 'keyFile', maxCount: 1 }]),
  async (req, res) => {
    const host = readConfiguredHost();
    if (!host) return res.status(400).json({ error: 'No configured hostname found.' });

    const files = req.files || {};
    const crtText = files.crtFile ? files.crtFile[0].buffer.toString('utf8') : req.body.crtText;
    const keyText = files.keyFile ? files.keyFile[0].buffer.toString('utf8') : req.body.keyText;
    const allowSelfSigned = req.body.allowSelfSigned === 'on' || req.body.allowSelfSigned === 'true';

    if (!crtText || !keyText) {
      return res.status(400).json({ error: 'Both a certificate and a private key are required (file or pasted text).' });
    }

    try {
      const result = await validateCert({ host, crtText, keyText, allowSelfSigned });
      res.json({ passed: result.passed, checks: result.checks });
    } catch (err) {
      console.error('Cert validation failed to run:', err);
      res.status(500).json({ error: 'Could not run certificate validation — check `docker logs padsign-wizard`.' });
    }
  }
);

router.post('/api/settings/cert/renew', (req, res) => {
  const host = readConfiguredHost();
  if (!host) return res.status(400).json({ error: 'No configured hostname found.' });

  const { crtPath, keyPath } = certPathsFor(host);
  if (!fs.existsSync(crtPath) || !fs.existsSync(keyPath)) {
    return res.status(400).json({ error: `Upload and validate a certificate for ${host} first.` });
  }

  try {
    const runId = startRun({
      scriptName: 'renew-cert.sh',
      args: ['--host', host, '--cert-crt', crtPath, '--cert-key', keyPath]
    });
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message });
    }
    console.error('Failed to start cert renewal:', err);
    res.status(500).json({ error: 'Failed to start cert renewal — check `docker logs padsign-wizard`.' });
  }
});

// ---- Feature toggles ----

// Any subset of the 3 flags — flipping several switches then clicking one
// "Apply changes" costs one restart, not one per flip (confirmed with user).
router.post('/api/settings/features/toggle', (req, res) => {
  const body = req.body || {};
  const args = [];
  if (typeof body.routing === 'boolean') args.push(body.routing ? '--enable-routing' : '--disable-routing');
  if (typeof body.demo === 'boolean') args.push(body.demo ? '--enable-demo' : '--disable-demo');
  if (typeof body.localEseal === 'boolean') args.push(body.localEseal ? '--enable-local-eseal' : '--disable-local-eseal');

  if (!args.length) {
    return res.status(400).json({ error: 'No feature changes provided.' });
  }

  try {
    const runId = startRun({ scriptName: 'toggle-features.sh', args });
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message });
    }
    console.error('Failed to start feature toggle:', err);
    res.status(500).json({ error: 'Failed to start feature toggle — check `docker logs padsign-wizard`.' });
  }
});

module.exports = router;
