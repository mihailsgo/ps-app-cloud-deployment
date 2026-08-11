'use strict';

const defaults = require('../config/defaults');

// Session doubles as both the auth gate (lib/auth.js) and the in-progress
// wizard-form store (decision #13) — one mechanism, not two. Nothing here
// is persisted outside the process; a wizard-container restart mid-flow
// loses in-progress form state, which is acceptable (decision #8: no
// wizard-side database, everything derivable is re-derived on load).
function ensureWizardSession(req) {
  if (!req.session.wizard) {
    req.session.wizard = {
      host: '',
      companyRole: '',
      adminUser: 'admin',
      adminPass: '',
      realm: defaults.realm,
      allowSelfSigned: false,
      // Hard security rule: the private key itself is NEVER stored here —
      // only a boolean + the path certValidator.js already wrote it to.
      cert: { validated: false, host: null, crtPath: null, keyPath: null, checks: [] },
      features: {
        enable_routing: false,
        enable_demo: false,
        enable_local_eseal: false
      },
      // Gates which step-rail dots are clickable (nav/UX pass). Starts at 2
      // (step 1/Welcome has no form of its own — reaching it is automatic).
      // Bumped forward by each step's POST handler on success; restored from
      // the saved-progress file on Resume.
      furthestStepReached: 2
    };
  }
  return req.session.wizard;
}

module.exports = { ensureWizardSession };
