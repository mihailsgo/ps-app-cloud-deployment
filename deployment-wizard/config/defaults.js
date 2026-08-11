'use strict';

module.exports = {
  port: parseInt(process.env.WIZARD_PORT || '8443', 10),
  realm: 'padsign',
  sessionTtlMs: 2 * 60 * 60 * 1000, // 2 hours — decision: §7 refinement, avoid an indefinitely-valid forgotten tab
  hostProjectDir: process.env.HOST_PROJECT_DIR || process.cwd(),
  features: [
    {
      key: 'enable_routing',
      label: 'Document routing',
      description: 'Save signed documents to disk automatically after signing completes.'
    },
    {
      key: 'enable_demo',
      label: 'Demo mode',
      description: 'Enables demo-only UI affordances in the client app. Do not use in production.'
    },
    {
      key: 'enable_local_eseal',
      label: 'Local e-sealing',
      description: 'Provision the in-stack e-sealing container instead of calling an external cloud e-sealing service.'
    }
  ]
};
