'use strict';

const express = require('express');

const { ensureWizardSession } = require('../lib/wizardSession');
const { startRun, isRunActive } = require('../lib/scriptRunner');
const { getTopbarContext } = require('../lib/topbarContext');
const { getUpgradePlan } = require('../lib/upgradePlan');
const { savePlan, getPlan, dropPlan } = require('../lib/planStore');
const { buildUpgradeArgs, validateUpgradeRequest } = require('../lib/upgradeArgs');

const router = express.Router();

// The upgrade flow is Preview -> Apply. The preview is a mandatory gate, and
// it is enforced here rather than in the browser: routes/deploy.js no longer
// accepts mode:'upgrade', so there is no way to start an upgrade without
// first producing a plan.

router.post('/api/upgrade/plan', async (req, res) => {
  const body = req.body || {};

  if (isRunActive()) {
    return res.status(409).json({ error: 'A deploy/upgrade run is already in progress.' });
  }
  const invalid = validateUpgradeRequest(body);
  if (invalid) return res.status(400).json({ error: invalid });

  const args = buildUpgradeArgs(body);

  try {
    const plan = await getUpgradePlan(args);
    const previewId = savePlan({ plan, args, sessionId: req.sessionID });
    res.json({ previewId, pendingCount: plan.pendingCount });
  } catch (err) {
    // upgrade.sh refusing the argument combination (e.g. the local-eseal
    // minimum-tag gate) is a real answer for the operator, not a wizard fault.
    if (err.code === 'PLAN_REFUSED') {
      return res.status(400).json({ error: err.message, detail: err.detail });
    }
    console.error('Failed to build upgrade plan:', err);
    res.status(500).json({ error: 'Could not read the upgrade plan — check `docker logs padsign-wizard`.' });
  }
});

router.get('/upgrade/preview', async (req, res, next) => {
  try {
    const entry = getPlan(req.query.previewId, req.sessionID);
    // Same behaviour as /upgrade/progress with an unknown runId: quietly
    // return to the Dashboard rather than showing a broken page.
    if (!entry) return res.redirect('/dashboard');

    const wizard = ensureWizardSession(req);
    const topbar = await getTopbarContext(wizard);
    res.render('upgrade-preview', {
      previewId: String(req.query.previewId),
      plan: entry.plan,
      args: entry.args,
      ...topbar
    });
  } catch (err) {
    next(err);
  }
});

router.post('/api/upgrade/apply', (req, res) => {
  const previewId = String((req.body || {}).previewId || '');
  const entry = getPlan(previewId, req.sessionID);

  if (!entry) {
    return res.status(404).json({
      error: 'That preview has expired or is no longer available — start the upgrade again.'
    });
  }

  try {
    // Runs the exact arguments that were previewed, from the store rather
    // than from the request body, so the browser can't substitute different
    // ones after the operator reviewed the plan.
    const runId = startRun({ scriptName: 'upgrade.sh', args: entry.args });
    ensureWizardSession(req).lastRunId = runId;
    dropPlan(previewId);
    res.json({ runId });
  } catch (err) {
    if (err.code === 'RUN_IN_PROGRESS') {
      return res.status(409).json({ error: err.message });
    }
    console.error('Failed to start upgrade:', err);
    res.status(500).json({ error: 'Failed to start the upgrade — check `docker logs padsign-wizard`.' });
  }
});

module.exports = router;
