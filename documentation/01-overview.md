# 1. Overview

PadSign is a web application for signing PDF documents in a browser, typically on a tablet at a
service desk. This repository is the deployment package: a Docker Compose stack, its runtime
configuration and the scripts that install and operate it on your own Linux host. It contains no
application source code; every service runs from a pre-built, digest-pinned image.

## What PadSign does

- A business system, the PadSign Virtual Printer or a third-party integration registers a PDF for a
  signer through the PadSign API, authenticated with an API key.
- The signer, logged in to the PadSign portal through Keycloak, sees that document, reviews it and
  draws a handwritten signature.
- PadSign embeds the visual signature into the PDF and, when e-sealing is enabled, applies an
  electronic seal on behalf of your organisation. The seal comes from an external e-sealing service
  or from a keystore held on your own host.
- The signed document is kept in the archive. Optionally it is also saved to a folder, sent to a
  webhook, or returned to the Padsign Manager ([11. Document routing and receive-back](11-document-routing-and-receive-back.md)).

## What runs on your host

| Component | Role |
|---|---|
| nginx | Public entry point on ports 80 and 443. Terminates TLS and routes requests to the services below. |
| ps-client | The PadSign portal (React single-page app) under `/portal/`. |
| ps-server | The PadSign API (Node.js) under `/api/`. Holds the list of documents waiting for each signer. |
| Keycloak | Login and user management under `/auth/`. |
| DMSS archive services | Document archive API under `/archive/api/`, with a filesystem store for the document files. |
| DMSS container and signature services | Applies visual signatures and e-seals to PDFs, under `/container/api/`. |
| DMSS digital stamping service | Holds the e-seal key. Runs only when local e-sealing is enabled. |
| Deployment Wizard | Optional browser UI for installing, upgrading and changing settings. Runs only when you start it. |

Only nginx (and the wizard, while you run it) listens on the network; every other service is
reachable through nginx or on the host's loopback interface.
Details: [1.1 Architecture](01-01-architecture.md).

## How to install

1. Prepare the host: [2. Prerequisites](02-prerequisites.md).
2. Install with the browser-based wizard (recommended,
   [3. Install with the Deployment Wizard](03-install-with-the-wizard.md)) or with one script
   ([4. Install from the command line](04-install-from-the-command-line.md)). Both give the same
   result.
3. Log in and verify: [5. First login and verification](05-first-login-and-verification.md).
4. Harden for production: [6. Production hardening](06-production-hardening.md).

Day-to-day operations (hostname and certificate changes, feature toggles, upgrades, rollback,
monitoring) are in [9. Operations](09-operations.md).

## Sub-sections

- [1.1 Architecture](01-01-architecture.md)
- [1.2 How signing works](01-02-how-signing-works.md)
