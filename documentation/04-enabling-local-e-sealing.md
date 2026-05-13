# 4. Enabling local e-sealing

PadSign ships with **two e-sealing paths** that you can pick between at deploy
time without touching source code:

- **External (default)** - `ps-server` calls a cloud e-sealing service
  configured via `STAMP_API_URL` / `STAMP_API_KEY` / `STAMP_COMPANY_ID` /
  `STAMP_COMPANY_SECRET` in `config/config.js`.
- **Local** - `ps-server` calls an in-stack `dmss-container-and-signature-services`
  endpoint, which delegates to a new `dmss-digital-stamping-service` container.
  The signing key lives inside that container
  (`dmss-digital-stamping-service/seal/seal.p12`). Nothing leaves the host.

**Decision rules:** the toggle lives in `config/config.js`
(`STAMP_MODE: "external" | "local"`), and a docker compose profile
(`local-eseal`) controls whether the stamping container is actually started.
`.env` links the two.

## Sub-sections

- [4.1 Concepts and glossary](04-01-concepts-and-glossary.md)
- [4.2 Architecture deep-dive](04-02-architecture-deep-dive.md)
- [4.3 Initial deployment (fresh install)](04-03-initial-deployment-fresh-install.md)
- [4.4 Existing deployment (upgrade an already-deployed instance)](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)
- [4.5 Switching modes after install](04-05-switching-modes-after-install.md)
- [4.6 Production setup: deploying with your own key and certificate](04-06-production-setup-deploying-with-your-own-key-and-certificate.md)
- [4.7 Adding a new signing profile end-to-end](04-07-adding-a-new-signing-profile-end-to-end.md)
- [4.8 Wiring TSA and OCSP for LT and LTA signature profiles](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md)
- [4.9 Verifying it works](04-09-verifying-it-works.md)
- [4.10 Verifying signatures end-to-end (beyond the stack)](04-10-verifying-signatures-end-to-end-beyond-the-stack.md)

