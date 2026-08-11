'use strict';

const crypto = require('crypto');

// In-memory only, mirroring lib/scriptRunner.js's `runs` map. No disk, no
// database — "no wizard-side database" (decision #8) is load-bearing here:
// a plan is a short-lived artefact of one operator's session, and losing it
// on a container restart is correct, not a bug.
//
// The store exists so Apply runs exactly the arguments that were previewed,
// rather than trusting the browser to send them back.

const TTL_MS = 30 * 60 * 1000;
const plans = new Map(); // previewId -> { plan, args, sessionId, createdAt }

function sweep() {
  const cutoff = Date.now() - TTL_MS;
  for (const [id, entry] of plans) {
    if (entry.createdAt < cutoff) plans.delete(id);
  }
}

function savePlan({ plan, args, sessionId }) {
  sweep();
  const previewId = crypto.randomBytes(9).toString('hex');
  plans.set(previewId, { plan, args, sessionId, createdAt: Date.now() });
  return previewId;
}

// Scoped to the session that created it: a preview is one operator's
// in-flight decision, not a shared resource.
function getPlan(previewId, sessionId) {
  sweep();
  const entry = plans.get(String(previewId || ''));
  if (!entry) return null;
  if (sessionId && entry.sessionId && entry.sessionId !== sessionId) return null;
  return entry;
}

function dropPlan(previewId) {
  plans.delete(String(previewId || ''));
}

module.exports = { savePlan, getPlan, dropPlan, TTL_MS };
