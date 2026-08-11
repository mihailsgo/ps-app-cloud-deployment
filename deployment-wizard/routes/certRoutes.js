'use strict';

const express = require('express');
const multer = require('multer');

const { ensureWizardSession } = require('../lib/wizardSession');
const { validateCert } = require('../lib/certValidator');
const { getTopbarContext } = require('../lib/topbarContext');

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 1024 * 1024 } });
const router = express.Router();

router.get('/wizard/step/3', async (req, res) => {
  const wizard = ensureWizardSession(req);
  if (!wizard.host) return res.redirect('/wizard/step/2');
  const topbar = await getTopbarContext(wizard);
  res.render('steps/03-cert', { wizard, result: null, ...topbar });
});

// Accepts EITHER uploaded files (crtFile/keyFile) OR pasted text
// (crtText/keyText) — the approved step-3 mockup calls for "drag-drop or
// paste". Never echoes key material back in the response beyond the
// pass/fail checklist (hard rule from the plan: the private key must
// never round-trip into the browser after this point).
router.post(
  '/api/wizard/cert-upload',
  upload.fields([{ name: 'crtFile', maxCount: 1 }, { name: 'keyFile', maxCount: 1 }]),
  async (req, res) => {
    const wizard = ensureWizardSession(req);
    if (!wizard.host) {
      return res.status(400).json({ error: 'Set a hostname in step 2 first.' });
    }

    const files = req.files || {};
    const crtText = files.crtFile ? files.crtFile[0].buffer.toString('utf8') : req.body.crtText;
    const keyText = files.keyFile ? files.keyFile[0].buffer.toString('utf8') : req.body.keyText;
    const allowSelfSigned = req.body.allowSelfSigned === 'on' || req.body.allowSelfSigned === 'true';

    if (!crtText || !keyText) {
      return res.status(400).json({ error: 'Both a certificate and a private key are required (file or pasted text).' });
    }

    try {
      const result = await validateCert({ host: wizard.host, crtText, keyText, allowSelfSigned });
      wizard.allowSelfSigned = allowSelfSigned;
      wizard.cert = {
        validated: result.passed,
        host: wizard.host,
        crtPath: result.crtPath,
        keyPath: result.keyPath,
        checks: result.checks
      };
      if (result.passed) {
        wizard.furthestStepReached = Math.max(wizard.furthestStepReached, 4);
      }
      res.json({ passed: result.passed, checks: result.checks });
    } catch (err) {
      console.error('Cert validation failed to run:', err);
      res.status(500).json({ error: 'Could not run certificate validation — check `docker logs padsign-wizard`.' });
    }
  }
);

module.exports = router;
