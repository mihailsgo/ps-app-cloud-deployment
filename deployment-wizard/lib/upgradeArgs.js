'use strict';

// Extracted from routes/deploy.js so the preview and the apply build their
// argv identically. If these two ever diverged, the wizard would show a plan
// for one set of arguments and then run another — the exact failure the
// preview exists to prevent.
function buildUpgradeArgs(body) {
  const args = [];
  if (body.serverTag) args.push('--server-tag', String(body.serverTag).trim());
  if (body.clientTag) args.push('--client-tag', String(body.clientTag).trim());
  if (body.enableLocalEseal) args.push('--enable-local-eseal');
  return args;
}

// Same "at least one of" rule the CLI enforces, surfaced early so the wizard
// can reject with a useful message instead of letting upgrade.sh exit 2.
function validateUpgradeRequest(body) {
  if (!body.serverTag && !body.clientTag && !body.enableLocalEseal) {
    return 'Provide at least one of server tag, client tag, or enable local e-sealing.';
  }
  return null;
}

module.exports = { buildUpgradeArgs, validateUpgradeRequest };
