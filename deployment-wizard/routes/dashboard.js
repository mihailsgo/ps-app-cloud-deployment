'use strict';

const express = require('express');
const { detectState } = require('../lib/stateDetector');
const { readImageTags, readLatestKnownTags, readConfiguredHost } = require('../lib/dockerFacts');
const { getRun, isRunActive, getActiveRunId, staleLockInfo } = require('../lib/scriptRunner');
const { getTopbarContext } = require('../lib/topbarContext');
const { ensureWizardSession } = require('../lib/wizardSession');
const { hasSavedProgress, clearProgress } = require('../lib/savedProgress');

const router = express.Router();

// Decides which of the Upgrade panel's 3 states applies (nav/UX pass — the
// fix for "why is Start Upgrade there when I'm already current"). If we
// can't determine a "latest known" tag for an image at all (missing/
// unparseable release-snapshot doc), fall back to "unknown" rather than
// guessing — the view treats that the same as "update available" (show the
// form) since silently claiming "up to date" would be actively misleading.
function upgradeState(current, latest) {
  if (!latest.serverTag && !latest.clientTag) return 'unknown';
  const serverUpToDate = !latest.serverTag || current.serverTag === latest.serverTag;
  const clientUpToDate = !latest.clientTag || current.clientTag === latest.clientTag;
  return serverUpToDate && clientUpToDate ? 'up-to-date' : 'update-available';
}

router.get('/dashboard', async (req, res, next) => {
  try {
    const wizard = ensureWizardSession(req);
    const [state, tags, topbar] = await Promise.all([
      detectState(),
      Promise.resolve(readImageTags()),
      getTopbarContext(wizard)
    ]);
    // Reaching the Dashboard at all means setup is done — a saved-progress
    // file (e.g. from an earlier Save & Exit that was never resumed) is now
    // stale, matching "cleared... on finishing setup" from the nav/UX plan.
    if (state.state !== 'FRESH' && hasSavedProgress()) clearProgress();

    const latestTags = readLatestKnownTags();
    const host = readConfiguredHost();
    res.render('dashboard', {
      state,
      tags,
      latestTags,
      upgradePanelState: upgradeState(tags, latestTags),
      host,
      runActive: isRunActive(),
      activeRunId: getActiveRunId(),
      staleLock: state.state !== 'FRESH' ? staleLockInfo() : null,
      ...topbar
    });
  } catch (err) {
    next(err);
  }
});

router.get('/upgrade/progress', async (req, res) => {
  const runId = String(req.query.runId || '');
  if (!runId || !getRun(runId)) return res.redirect('/dashboard');
  const wizard = ensureWizardSession(req);
  const topbar = await getTopbarContext(wizard);
  res.render('upgrade-progress', { runId, ...topbar });
});

module.exports = router;
