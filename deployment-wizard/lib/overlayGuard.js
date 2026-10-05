'use strict';

const fs = require('fs');
const path = require('path');
const { HOST_PROJECT_DIR } = require('./paths');

// An overlay-managed checkout (`overlay.sh apply` wrote .overlay-applied.json)
// is never edited in place: every change goes through a new overlay version
// (documentation 9.11). Bootstrap, upgrade, hostname, certificate and feature
// changes all rewrite tracked files, so on such a host the wizard is
// read-only: it still shows state, monitoring and diagnostics, and restarts a
// service (docker compose restart changes no file), but refuses everything
// that would rewrite the checkout.
//
// Enforced here, server-side, by one middleware in front of every router, and
// once more in lib/scriptRunner.js startRun() for the scripts themselves, so a
// route added later cannot start one by forgetting a check. The views only
// mirror it (banner, disabled controls).

const OVERLAY_MARKER = '.overlay-applied.json';
const OVERLAY_DOC = 'documentation/09-11-start-at-boot-backups-and-customized-hosts.md#living-with-an-overlay';

// Scripts that rewrite tracked files in the checkout.
const WRITE_SCRIPTS = new Set([
  'bootstrap.sh',
  'upgrade.sh',
  'rollback.sh',
  'update-hostname.sh',
  'renew-cert.sh',
  'toggle-features.sh'
]);

// POST routes that start one of those scripts, or stage files for one (the
// certificate uploads write installation-scripts/certs/).
const WRITE_ROUTES = new Set([
  '/api/deploy',
  '/api/wizard/cert-upload',
  '/api/upgrade/plan',
  '/api/upgrade/apply',
  '/api/settings/hostname/cert-upload',
  '/api/settings/hostname',
  '/api/settings/cert/upload',
  '/api/settings/cert/renew',
  '/api/settings/features/toggle'
]);
// Re-runs whatever script a finished run used; refused only for WRITE_SCRIPTS.
const RETRY_ROUTE = '/api/deploy/retry';

// Live, never cached: the marker appears on `overlay.sh apply` and goes away
// only with the checkout, and the wizard derives state from disk (decision #8).
// Returns null on a normal checkout, otherwise { overlayDir } (null when the
// marker cannot be parsed; its presence alone decides).
function readOverlayState(projectDir = HOST_PROJECT_DIR) {
  const marker = path.join(projectDir, OVERLAY_MARKER);
  if (!fs.existsSync(marker)) return null;
  let overlayDir = null;
  try {
    const stamp = JSON.parse(fs.readFileSync(marker, 'utf8'));
    if (stamp && typeof stamp.overlay_dir === 'string') overlayDir = stamp.overlay_dir;
  } catch (err) {
    // unreadable or not JSON: still an overlay host
  }
  return { overlayDir };
}

function isOverlayManaged(projectDir = HOST_PROJECT_DIR) {
  return readOverlayState(projectDir) !== null;
}

function isWriteScript(scriptName) {
  return WRITE_SCRIPTS.has(String(scriptName || ''));
}

const REFUSAL_MESSAGE =
  'This host is overlay-managed (.overlay-applied.json is present), so the wizard does not change, ' +
  'deploy or upgrade it: that would rewrite files the overlay owns. Make the change in a new overlay ' +
  `version instead, see ${OVERLAY_DOC}. Monitoring and diagnostics still work.`;

function overlayRefusal() {
  return { error: REFUSAL_MESSAGE, code: 'OVERLAY_MANAGED', documentation: OVERLAY_DOC };
}

function overlayManagedError(scriptName) {
  const err = new Error(`Refusing to run ${scriptName}: ${REFUSAL_MESSAGE}`);
  err.code = 'OVERLAY_MANAGED';
  return err;
}

// One middleware for the whole app (mounted in app.js before every router):
// sets res.locals.overlay for the views and answers every write route with
// 409 before its handler (and so before any upload is staged or script
// spawned). `getRun` is looked up lazily: scriptRunner requires this module.
function createOverlayGuard({
  readState = readOverlayState,
  getRun = (id) => require('./scriptRunner').getRun(id)
} = {}) {
  return function overlayGuard(req, res, next) {
    const state = readState();
    res.locals.overlay = state;
    if (!state || req.method !== 'POST') return next();

    let refuse = WRITE_ROUTES.has(req.path);
    if (!refuse && req.path === RETRY_ROUTE) {
      const prev = getRun(String((req.body || {}).runId || ''));
      refuse = Boolean(prev && isWriteScript(prev.scriptName));
    }
    if (refuse) return res.status(409).json(overlayRefusal());
    return next();
  };
}

module.exports = {
  OVERLAY_MARKER,
  OVERLAY_DOC,
  WRITE_SCRIPTS,
  WRITE_ROUTES,
  readOverlayState,
  isOverlayManaged,
  isWriteScript,
  overlayRefusal,
  overlayManagedError,
  createOverlayGuard
};
