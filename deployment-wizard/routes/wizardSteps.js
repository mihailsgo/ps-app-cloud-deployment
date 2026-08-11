'use strict';

const express = require('express');
const dns = require('dns').promises;

const { detectState } = require('../lib/stateDetector');
const { dockerAvailable, readConfiguredHost } = require('../lib/dockerFacts');
const { HOST_PROJECT_DIR } = require('../lib/paths');
const { ensureWizardSession } = require('../lib/wizardSession');
const { getRun } = require('../lib/scriptRunner');
const { validateConfig } = require('../lib/configValidator');
const { getTopbarContext } = require('../lib/topbarContext');
const { saveProgress, loadProgress, clearProgress, hasSavedProgress } = require('../lib/savedProgress');
const defaults = require('../config/defaults');

const router = express.Router();

const STEP_LABELS = {
  1: 'Welcome',
  2: 'Host & Company',
  3: 'TLS Certificate',
  4: 'Feature Toggles',
  5: 'Review & Confirm',
  6: 'Deploy',
  7: 'Verify & Go-Live'
};

const STEP_URL = (n) => (n === 1 ? '/' : `/wizard/step/${n}`);

// Onboarding GET handlers for steps 2-7 all need the same "don't let someone
// jump ahead of where they've actually gotten to" guard (nav/UX pass —
// clicking a done step-dot is fine; typing a later URL by hand isn't).
// `minFurthest` is separate from `step` for 6/7: those pages are reached via
// a client-side redirect right after POSTing /api/deploy (which is what
// actually bumps furthestStepReached to 6), not their own form POST, so the
// gate has to check against the PRIOR step, not itself.
function requireReached(step, minFurthest = step) {
  return (req, res, next) => {
    const wizard = ensureWizardSession(req);
    if (wizard.furthestStepReached < minFurthest) {
      return res.redirect(STEP_URL(wizard.furthestStepReached));
    }
    next();
  };
}

router.get('/', async (req, res, next) => {
  try {
    const wizard = ensureWizardSession(req);
    const [state, dockerOk, topbar] = await Promise.all([
      detectState(),
      dockerAvailable(),
      getTopbarContext(wizard)
    ]);

    // Setup already complete (e.g. returning operator, or a leftover
    // saved-progress file from before setup finished) — no reason to show
    // onboarding again; clear any stale saved-progress and go to Dashboard.
    if (state.state !== 'FRESH' && state.state !== 'DEPLOYED_STOPPED') {
      if (hasSavedProgress()) clearProgress();
      return res.redirect('/dashboard');
    }

    const saved = hasSavedProgress() ? loadProgress() : null;
    res.render('welcome', {
      state,
      dockerOk,
      projectDir: HOST_PROJECT_DIR,
      saved,
      savedStepLabel: saved ? STEP_LABELS[saved.step] : null,
      ...topbar
    });
  } catch (err) {
    next(err);
  }
});

router.get('/api/state', async (req, res, next) => {
  try {
    const state = await detectState();
    res.json(state);
  } catch (err) {
    next(err);
  }
});

// ---- Save & Exit / Start Over / Resume (nav/UX pass) ----

router.post('/api/wizard/save-and-exit', (req, res) => {
  const wizard = ensureWizardSession(req);
  const step = Number(req.query.step) || wizard.furthestStepReached;
  saveProgress(wizard, step);
  req.session.destroy(() => res.redirect('/login'));
});

router.post('/api/wizard/start-over', (req, res) => {
  clearProgress();
  req.session.wizard = null;
  ensureWizardSession(req);
  res.redirect('/');
});

router.get('/api/wizard/resume', (req, res) => {
  const saved = loadProgress();
  if (!saved) return res.redirect('/');

  const wizard = ensureWizardSession(req);
  Object.assign(wizard, saved, { adminPass: '' }); // never persisted — see lib/savedProgress.js
  clearProgress();
  res.redirect(STEP_URL(saved.step));
});

// ---- Step 2: Host & company info ----

router.get('/wizard/step/2', requireReached(2), async (req, res) => {
  const wizard = ensureWizardSession(req);
  const topbar = await getTopbarContext(wizard);
  res.render('steps/02-host', { wizard, dnsResult: null, error: null, ...topbar });
});

router.post('/wizard/step/2', async (req, res) => {
  const wizard = ensureWizardSession(req);
  const { host, companyRole, adminUser, adminPass, realm } = req.body || {};

  const missing = [];
  if (!host) missing.push('Hostname');
  if (!companyRole) missing.push('Company / role name');
  if (!adminPass) missing.push('Keycloak admin password');

  if (missing.length) {
    const topbar = await getTopbarContext(wizard);
    return res.status(400).render('steps/02-host', {
      wizard: { ...wizard, host, companyRole, adminUser, adminPass, realm },
      dnsResult: null,
      error: `Missing required field(s): ${missing.join(', ')}`,
      ...topbar
    });
  }

  wizard.host = host.trim();
  wizard.companyRole = companyRole.trim();
  wizard.adminUser = (adminUser || 'admin').trim();
  wizard.adminPass = adminPass;
  wizard.realm = (realm || defaults.realm).trim();
  wizard.furthestStepReached = Math.max(wizard.furthestStepReached, 3);

  res.redirect('/wizard/step/3');
});

// Live DNS-resolves hint (decision #9, step 2) — informational only, never
// blocks proceeding, since some deployments resolve only via an internal
// DNS server or hosts-file entry not visible from this exact check.
router.get('/api/wizard/dns-check', async (req, res) => {
  const host = String(req.query.host || '').trim();
  if (!host) return res.json({ resolved: false, addresses: [] });
  try {
    const addresses = await dns.resolve(host);
    res.json({ resolved: true, addresses });
  } catch (err) {
    res.json({ resolved: false, addresses: [] });
  }
});

// ---- Step 4: Feature toggles ----

router.get('/wizard/step/4', requireReached(4), async (req, res) => {
  const wizard = ensureWizardSession(req);
  if (!wizard.cert.validated) return res.redirect('/wizard/step/3');
  const topbar = await getTopbarContext(wizard);
  res.render('steps/04-features', { wizard, features: defaults.features, ...topbar });
});

router.post('/wizard/step/4', (req, res) => {
  const wizard = ensureWizardSession(req);
  const body = req.body || {};
  defaults.features.forEach((f) => {
    wizard.features[f.key] = body[f.key] === 'on';
  });
  wizard.furthestStepReached = Math.max(wizard.furthestStepReached, 5);
  res.redirect('/wizard/step/5');
});

// ---- Step 5: Review & confirm ----

router.get('/wizard/step/5', requireReached(5), async (req, res) => {
  const wizard = ensureWizardSession(req);
  if (!wizard.cert.validated) return res.redirect('/wizard/step/3');
  const topbar = await getTopbarContext(wizard);
  res.render('steps/05-review', { wizard, features: defaults.features, ...topbar });
});

// ---- Step 6: Deploy (live progress) ----

router.get('/wizard/step/6', requireReached(6, 5), async (req, res) => {
  const wizard = ensureWizardSession(req);
  const runId = String(req.query.runId || wizard.lastRunId || '');
  if (!runId || !getRun(runId)) return res.redirect('/wizard/step/5');
  wizard.lastRunId = runId;
  const topbar = await getTopbarContext(wizard);
  res.render('steps/06-deploy', { wizard, runId, ...topbar });
});

// ---- Step 7: Verify & go-live checklist ----

router.get('/wizard/step/7', requireReached(7, 6), async (req, res) => {
  const wizard = ensureWizardSession(req);
  wizard.furthestStepReached = Math.max(wizard.furthestStepReached, 7);
  const topbar = await getTopbarContext(wizard);
  res.render('steps/07-verify', { wizard, ...topbar });
});

router.get('/api/wizard/verify', async (req, res) => {
  const wizard = ensureWizardSession(req);
  try {
    const result = await validateConfig({ host: wizard.host || readConfiguredHost() });
    res.json(result);
  } catch (err) {
    console.error('validate-config.sh failed to run:', err);
    res.status(500).json({ error: 'Could not run configuration validation — check `docker logs padsign-wizard`.' });
  }
});

module.exports = router;
// Exposed for unit testing only (test/routeGuards.test.js) — the guard's
// step-catch-up logic is easy to get subtly wrong (see the minFurthest
// comment above) and is worth covering without spinning up a full HTTP stack.
module.exports.requireReached = requireReached;
module.exports.STEP_URL = STEP_URL;
