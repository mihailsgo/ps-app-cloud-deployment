'use strict';

const express = require('express');
const { ensureWizardSession } = require('../lib/wizardSession');
const { startRun, subscribe, getRun, isRunActive } = require('../lib/scriptRunner');

const router = express.Router();

function buildBootstrapArgs(wizard) {
  const args = [
    '--host', wizard.host,
    '--company-role', wizard.companyRole,
    '--admin-pass', wizard.adminPass,
    '--admin-user', wizard.adminUser,
    '--realm', wizard.realm
    // Deliberately no --cert-crt/--cert-key: certValidator.js already wrote
    // the validated cert/key to installation-scripts/certs/<host>.{crt,key},
    // which is the exact default path bootstrap.sh's own step 2 resolves to.
  ];
  if (wizard.features.enable_routing) args.push('--enable-routing');
  if (wizard.features.enable_demo) args.push('--enable-demo');
  if (wizard.features.enable_local_eseal) args.push('--enable-local-eseal');
  if (wizard.allowSelfSigned) args.push('--allow-self-signed');
  return args;
}

// Upgrades no longer start here. They go through the mandatory preview gate
// in routes/upgradeRoutes.js (POST /api/upgrade/plan -> /upgrade/preview ->
// POST /api/upgrade/apply). Leaving a mode:'upgrade' branch in place would
// have made that gate a browser-side suggestion rather than an actual gate,
// since anything could POST here directly. buildUpgradeArgs now lives in
// lib/upgradeArgs.js, shared by the plan and the apply.

router.post('/api/deploy', (req, res) => {
  const wizard = ensureWizardSession(req);
  const body = req.body || {};
  const mode = body.mode || 'bootstrap';

  if (mode === 'upgrade') {
    return res.status(400).json({
      error: 'Upgrades must go through the preview step — POST /api/upgrade/plan instead.'
    });
  }
  if (mode !== 'bootstrap') {
    return res.status(400).json({ error: `Unsupported deploy mode "${mode}".` });
  }
  if (!wizard.host || !wizard.companyRole || !wizard.adminPass) {
    return res.status(400).json({ error: 'Complete steps 2-4 before deploying.' });
  }
  if (!wizard.cert.validated) {
    return res.status(400).json({ error: 'Certificate must pass validation (step 3) before deploying.' });
  }

  const scriptName = 'bootstrap.sh';
  const args = buildBootstrapArgs(wizard);

  try {
    const runId = startRun({ scriptName, args });
    wizard.lastRunId = runId;
    wizard.furthestStepReached = Math.max(wizard.furthestStepReached, 6);
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message, runId: req.session.wizard.lastRunId });
    }
    console.error('Failed to start deploy run:', err);
    res.status(500).json({ error: 'Failed to start deploy — check `docker logs padsign-wizard`.' });
  }
});

// Re-run a finished run with the exact same script and arguments. A failed
// bootstrap/upgrade/settings run used to be a dead end in the UI — the only
// way out was the topbar, and for bootstrap the operator had to re-enter the
// admin password. scriptRunner keeps scriptName/args on the run state, so a
// retry needs no new input and can't drift from what actually ran.
router.post('/api/deploy/retry', (req, res) => {
  const wizard = ensureWizardSession(req);
  const prev = getRun(String((req.body || {}).runId || ''));

  if (!prev) {
    return res.status(404).json({
      error: 'That run is no longer in memory (the wizard restarted) — start the action again from the beginning.'
    });
  }
  if (!prev.done) {
    return res.status(409).json({ error: 'That run is still in progress.' });
  }

  try {
    const runId = startRun({ scriptName: prev.scriptName, args: prev.args });
    wizard.lastRunId = runId;
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message, runId: wizard.lastRunId });
    }
    console.error('Failed to retry run:', err);
    res.status(500).json({ error: 'Failed to start the retry — check `docker logs padsign-wizard`.' });
  }
});

router.get('/api/deploy/stream', (req, res) => {
  const runId = String(req.query.runId || '');
  const state = getRun(runId);
  if (!state) {
    res.status(404).end();
    return;
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive'
  });
  res.flushHeaders && res.flushHeaders();

  const send = (item) => {
    res.write(`event: ${item.event}\ndata: ${JSON.stringify(item.data)}\n\n`);
  };
  const unsubscribe = subscribe(runId, send);

  req.on('close', unsubscribe);
});

router.get('/api/deploy/status', (req, res) => {
  res.json({ active: isRunActive() });
});

module.exports = router;
