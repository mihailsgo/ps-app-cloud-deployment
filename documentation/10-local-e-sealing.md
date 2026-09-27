# 10. Local e-sealing

An e-seal is the organisation's own digital signature, applied to the PDF
after the signer has signed it. PadSign can apply the e-seal in one of two
ways. You choose one when you deploy and can switch later:

- **External (default).** `ps-server` sends the PDF to a cloud e-sealing
  service. It is configured with `STAMP_API_URL`, `STAMP_API_KEY`,
  `STAMP_COMPANY_ID` and `STAMP_COMPANY_SECRET` in `config/config.js`. The
  shipped file has `CHANGE_ME` in those three credential fields. Put in the
  values your e-sealing provider gave you.
- **Local.** `ps-server` sends the PDF to `dmss-container-and-signature-services`
  in your own stack. That service gets the signature from the
  `dmss-digital-stamping-service` container, which holds the signing key in a
  PKCS12 keystore on your host. The document stays on your host.

## How the mode is selected

Three settings decide the mode, and they must agree:

| Setting | Where | Local mode | External mode |
|---|---|---|---|
| `STAMP_MODE` | `config/config.js` | `"local"` | `"external"`, or no field at all |
| `STAMP_LOCAL` block | `config/config.js` | URL and credentials for container-signature | ignored |
| `COMPOSE_PROFILES` | `.env` next to `docker-compose.yml` | includes `local-eseal` | does not include `local-eseal` |

`docker-compose.yml` defines `dmss-digital-stamping-service` with
`profiles: ["local-eseal"]`. That means `docker compose up -d` starts it only
when the `local-eseal` profile is active. If you never enable local
e-sealing, the stamping container never starts and nothing changes.

The scripts set all three for you: `bootstrap.sh --enable-local-eseal`,
`upgrade.sh --enable-local-eseal` and `toggle-features.sh
--enable-local-eseal` / `--disable-local-eseal`. The Deployment Wizard runs
the same scripts. Its **Local e-sealing** switch is on the Features step, on
the Settings page and in the Dashboard's upgrade panel.

## Before you start

- **The portal must request the seal.** In both modes the portal asks for a
  seal only when `RUN_STAMPING_REQUEST` is `true` in `config/constants.json`.
  The shipped value is `false`, and no script changes it. See
  [7.3 Client constants.json](07-03-client-constants-json.md).
- **The ps-server image must be recent enough.** Older ps-server images ignore
  `STAMP_MODE` and always use the external service. The minimum tag is the
  `local-eseal` entry in `release/capabilities.json`. `upgrade.sh` and
  `toggle-features.sh` refuse to enable local mode against an older tag.
- **The shipped keystore and passwords are for demos only.** The demo keystore
  is self-signed, and three demo passwords are set to `changeit`. Replace them
  before production. See
  [10.6 Production key and certificate](10-06-production-key-and-certificate.md)
  and [6. Production hardening](06-production-hardening.md).

## Sub-sections

- [10.1 Concepts and glossary](10-01-concepts-and-glossary.md)
- [10.2 Architecture](10-02-architecture.md)
- [10.3 Fresh install](10-03-fresh-install.md)
- [10.4 Existing deployment](10-04-existing-deployment.md)
- [10.5 Switching modes](10-05-switching-modes.md)
- [10.6 Production key and certificate](10-06-production-key-and-certificate.md)
- [10.7 Adding a signing profile](10-07-adding-a-signing-profile.md)
- [10.8 TSA and OCSP for LT and LTA](10-08-tsa-and-ocsp-for-lt-and-lta.md)
- [10.9 Verifying it works](10-09-verifying-it-works.md)
- [10.10 Verifying signatures end-to-end](10-10-verifying-signatures-end-to-end.md)
