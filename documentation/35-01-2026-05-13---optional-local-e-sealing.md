# 35.1 2026-05-13 - Optional local e-sealing

**Added** an opt-in *local* e-sealing mode. The default external
e-sealing path (ps-server → cloud signing service) is unchanged. The
new local path adds an in-stack `dmss-digital-stamping-service`
container that holds its own signing key + cert and produces sealed
PDFs without any outbound call.

**New repo artefacts:**

- `dmss-digital-stamping-service/` (top-level directory) - Spring Boot
  config + bind-mounted demo seal.p12 for the new stamping service.
- `installation-scripts/assets/dmss-digital-stamping-service/` -
  pristine reference copy used by `upgrade.sh` to populate existing
  deployments.

**New install-script flags:**

- `installation-scripts/bootstrap.sh` - `--enable-local-eseal` flag
  (passes through to `configure-host.sh`).
- `installation-scripts/configure-host.sh` - `--enable-local-eseal`
  flag, plus a new end-of-script provisioning block.
- `installation-scripts/upgrade.sh` - `--enable-local-eseal` flag, new
  Step 4b. The flag is idempotent and can be combined with the existing
  `--server-tag` / `--client-tag` flags or used alone.

**Config-file additions** (all backwards-compatible; defaults preserve
pre-feature behaviour):

- `config/config.js` - new `STAMP_MODE: "external" | "local"` field
  (defaults to `"external"`) and a new `STAMP_LOCAL: { url, username,
  password, timeoutMs }` block. Existing `STAMP_API_*` fields untouched.
- `docker-compose.yml` - new gated `dmss-digital-stamping-service`
  service block (carries `profiles: ["local-eseal"]` so it doesn't
  start unless the profile is active).
- `dmss-container-and-signature-services/documentsigningprofiles.json`
  - new `LocalDemo` profile prepended (B_BES, esealCompany `TrustLynx`).
  Existing profiles untouched.
- `dmss-container-and-signature-services/application.yml` - the
  `digital-stamping-service.baseUrl` value is unchanged at the file
  level; `upgrade.sh --enable-local-eseal` rewrites it idempotently
  when local mode is opted in.

**New README sections** (all under the new top-level *Enabling local
e-sealing* heading, plus the existing *Bootstrap parameters* gained
a `--enable-local-eseal` row, and the *Upgrading an Existing Deployment*
step list gained a new Step 6 entry):

- Concepts and glossary - full glossary of digital-signature terms.
- Architecture deep-dive - request-flow diagrams for both modes; the
  profile → company → keystore resolution chain.
- Initial deployment (fresh install) - `bootstrap.sh --enable-local-eseal`
  recipe.
- Existing deployment (upgrade an already-deployed instance) - full
  step-by-step walkthrough (Phase 1 scripts/configs update → Phase 8
  rollback recipes).
- Switching modes after install - config-only flip recipes.
- Production setup: deploying with your own key and certificate - the
  centerpiece for production use. Three recipes covering common CA
  artefact shapes (separate cert+key, existing .pfx, alias rename).
- Adding a new signing profile end-to-end - per-company profile
  walkthrough.
- Wiring TSA and OCSP for LT and LTA signature profiles - required
  for eIDAS-grade signatures.
- Verifying it works - basic smoke-test commands.
- Verifying signatures end-to-end (beyond the stack) - Adobe Reader,
  `pdfsig`, programmatic verification.

**Default-behaviour invariant:** customers who pull the new repo
version and run plain `docker compose up -d` (without
`--enable-local-eseal`) see *zero* behavioural change. The new stamping
container is gated by a compose profile and never starts; `STAMP_MODE`
defaults to `"external"` so ps-server keeps calling the cloud service
exactly as before; no env vars on container-signature change so its
Spring Security auto-generated password mechanism stays in place.
Existing deployments only switch to local mode after the customer
explicitly runs `upgrade.sh --enable-local-eseal`.

