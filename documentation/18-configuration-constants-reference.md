# 18. Configuration Constants Reference

This document describes all configurable values exposed in the two runtime configuration files used by this project:

- Client runtime config: `config/constants.json`
- Backend server config: `config/config.js`

It explains what each constant does, default values present in the repo, and how deployers can change them for their environment.

Cloud usage note
- This deployment uses two parallel flows:
- External integration flow (API key): `/api/registerUser`, `/api/registerUserPDF`, `/api/registerPDF`, `/api/removeUser`.
- Internal operator flow (Keycloak token): `/api/latestUser`, `/api/fillPDFDemo`, `/api/visual-signature`, `/api/stamp`, `/api/cleanupUser`, `/api/demo/upload`, `/api/demo/upload/version`, `/api/demo/fill-by-docid`.
- Any item below explicitly marked �API is not relevant for cloud instance� is not used in standard cloud operation and can be ignored.

## Sub-sections

- [18.1 Cloud Essentials (TL;DR)](18-01-cloud-essentials-tldr.md)
- [18.2 How configuration is loaded](18-02-how-configuration-is-loaded.md)
- [18.3 Client: config/constants.json](18-03-client-configconstantsjson.md)
- [18.4 Server: config/config.js](18-04-server-configconfigjs.md)
- [18.5 Cloud Flow: /api/registerPDF](18-05-cloud-flow-apiregisterpdf.md)
- [18.6 Changing values safely](18-06-changing-values-safely.md)
- [18.7 Quick verification](18-07-quick-verification.md)
- [18.8 Notes](18-08-notes.md)
- [18.9 Debug Steps](18-09-debug-steps.md)

