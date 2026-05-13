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

## 4.1 Concepts and glossary

Local e-sealing is a way to put a cryptographic signature (a "seal") onto a
PDF before it leaves the server. Instead of sending the document out to a
cloud signing service, the signing happens inside a Docker container you
control, using a private key and certificate that live on your host. The
result is the same kind of signed PDF that Adobe Reader and other PDF
readers can verify.

If you have never worked with PDF signatures or digital-signature
infrastructure before, these terms appear repeatedly in the rest of this
guide:

| Term | Meaning |
|---|---|
| **Certificate (cert)** | A file (usually `.crt`, `.cer`, or `.pem`) issued by a Certificate Authority (CA). Contains the public key plus identity info (company name, country, validity dates). |
| **Private key** | The matching secret half of the certificate's key pair. Usually a `.key` file (PEM-encoded), sometimes password-protected. Must never leave the signing host. |
| **PKCS12** (`.p12` / `.pfx`) | A single file format that bundles a private key + certificate (+ optional intermediate-CA chain) together, protected by one password. The stamping service consumes its key+cert in this format. |
| **Alias** | A name pointing at one specific key+cert entry inside a PKCS12/JKS keystore. The stamping service uses the alias `seal` by default - your keystore must have an entry with that name (or you edit the config to point at a different alias). |
| **PEM** | A text-encoded format for keys and certs (`-----BEGIN CERTIFICATE-----` ... `-----END CERTIFICATE-----`). Convertible to PKCS12 with `openssl`. |
| **CA (Certificate Authority)** | The organisation that issues your certificate. Public CAs (Sectigo, DigiCert, eParaksts, SK ID Solutions, etc.) chain to a globally trusted root; private/internal CAs do not. |
| **Trust chain** | The sequence of certificates from your signing cert up through intermediate CAs to a trusted root. Any verifier needs the full chain to validate a signature. |
| **signatureProfile** | The "level" of signature digidoc4j produces. The relevant ones for PDF signing are `B_BES` (basic, self-contained), `LT` (long-term, includes a timestamp), and `LTA` (long-term + archival). |
| **PAdES** | "PDF Advanced Electronic Signatures" - the ETSI standard family for PDF signatures. `PAdES_BASELINE_B`, `PAdES_BASELINE_T`, `PAdES_BASELINE_LT`, `PAdES_BASELINE_LTA` are progressive levels of preservation. The default in `application.yml` is `PAdES_BASELINE_LT`. |
| **ASiC-E** | "Associated Signature Container - Extended" - a zip-based container format that holds one or more files plus their detached signatures. Used for sealing non-PDF artefacts; not the default for the local-eseal flow. |
| **TSA / TSP** | "TimeStamp Authority" / "TimeStamp Protocol". A network service that signs `(hash, current-time)` and returns a timestamp token. Required for `LT` / `LTA` signature levels. |
| **OCSP** | "Online Certificate Status Protocol". A network service the verifier queries to check whether a certificate has been revoked. Required for `LT` / `LTA`. |
| **TSL** | "Trust Service List". An XML document, maintained by each EU member state, listing the qualified Trust Service Providers (CAs, TSAs) accepted as eIDAS-qualified. digidoc4j consults TSLs in PROD mode to decide which issuers it will validate against. |
| **eIDAS** | EU Regulation 910/2014. Defines what counts as a *qualified* electronic signature / seal - broadly, a signature whose cert was issued by a qualified CA and whose long-term integrity is provable. Only `LT`/`LTA` signatures with a qualified CA + qualified TSA satisfy eIDAS. |
| **digidoc4j** | The Java library container-signature uses to actually produce the signature. Configured via `dmss-container-and-signature-services/digidoc4j-custom.yaml` and the `digidoc4j:` section of `application.yml`. |
| **Container-signature** | Short name we use in this guide for the `dmss-container-and-signature-services` container. It is the service that orchestrates document sealing. |
| **Stamping service** | Short name for `dmss-digital-stamping-service`. It holds the keystore and answers two endpoints: `GET /api/signing/certificate/for/<company>` and `POST /api/sign/digest/as/<company>`. |
| **Profile** | An entry in `documentsigningprofiles.json` that bundles a name (used in the URL), an `esealCompany` (which must match a company in the stamping service's config), and visual + signature settings. |
| **Company** | An entry in the stamping service's `application.yml` (under `stamping.companies`) that pairs a name with one or more `providers` (each with its own keystore). |

### Picking a signature level

| Profile | Self-contained? | Needs TSA? | Needs OCSP? | Legal status (EU eIDAS) |
|---|---|---|---|---|
| `B_BES` (`PAdES_BASELINE_B`) | yes | no | no | Basic electronic signature. Cryptographically valid; not qualified. Suitable for internal workflows, demos, non-regulated business. |
| `LT` (`PAdES_BASELINE_LT`) | yes after TSA | **yes** | **yes** | Advanced electronic signature with long-term validation data embedded. Qualifies for eIDAS *advanced* level; with a qualified CA + qualified TSA, qualifies as a qualified e-seal. |
| `LTA` (`PAdES_BASELINE_LTA`) | yes, with archival timestamps | **yes** | **yes** | Like LT, plus archival timestamps so the signature stays verifiable as algorithms age. Best for long-retention archives. |

**Default in `dmss-container-and-signature-services/application.yml`:**
`pdf.defaultSignatureLevel: PAdES_BASELINE_LT`. The shipped `LocalDemo`
profile overrides this to `B_BES` so the demo certificate works without a
TSA - see [Production setup: deploying with your own key and certificate](#46-production-setup-deploying-with-your-own-key-and-certificate)
for how to choose for your real cert.

---

## 4.2 Architecture deep-dive

In **external mode** the stamping container is not running. The request flow
is short:

```
SPA (browser) ──HTTPS──▶ nginx:443 ──▶ ps-server:3001 /api/stamp
                                              │ POST multipart {file, visualization=false}
                                              │ X-API-KEY / X-COMPANY-ID / X-COMPANY-SECRET
                                              ▼
                                       eseal.trustlynx.com (cloud)
                                              │ returns sealed PDF
                                              ▼
                                       ps-server → dmss-archive-services (new version)
                                              │
                                              ▼
                                       optional DOCUMENT_ROUTING (filesystem / webhook)
```

In **local mode** the cloud hop is replaced by two in-stack containers:

```
SPA (browser) ──HTTPS──▶ nginx:443 ──▶ ps-server:3001 /api/stamp
                                              │ POST multipart {file}
                                              │ Authorization: Basic <user:pass>
                                              ▼
            dmss-container-and-signature-services:8092 /api/eseal/document/profile/<P>
                                              │ docker DNS
                                              ▼
                          dmss-digital-stamping-service:8084
                          /api/signing/certificate/for/<C>   → returns cert hex
                          /api/sign/digest/as/<C>            → returns signature hex
                                              │
                                              ▼
                                /seal/seal.p12  (bind-mounted from
                                                 dmss-digital-stamping-service/seal/)
                                              │
                                              ▼
                  container-signature embeds the signature into the PDF and
                  returns the sealed PDF to ps-server → archive → routing
                  (same downstream pipeline as external mode)
```

Where `<P>` is the profile name in
`dmss-container-and-signature-services/documentsigningprofiles.json` and `<C>`
is the `esealCompany` from that profile, which must equal a company name in
`dmss-digital-stamping-service/application.yml`. The shipped pairing is
`<P>=LocalDemo`, `<C>=TrustLynx`.

### How a request resolves end-to-end

When ps-server in local mode posts to
`http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo`:

1. **container-signature** looks up `LocalDemo` in `documentsigningprofiles.json`.
   It finds:
   ```json
   { "name": "LocalDemo", "esealCompany": "TrustLynx",
     "pdfSigningSigner": { "signatureProfile": "B_BES" } }
   ```
2. container-signature reads `digital-stamping-service.baseUrl` from its
   `application.yml` (set by `--enable-local-eseal` to
   `http://dmss-digital-stamping-service:8084/api`).
3. container-signature calls
   `GET .../api/signing/certificate/for/TrustLynx` on the stamping service.
4. **stamping service** looks up `TrustLynx` in its `application.yml`
   `stamping.companies` list. It finds:
   ```yaml
   - name: "TrustLynx"
     providers:
       - name: P12
         engine: P12
         keystore: file:/seal/seal.p12
         password: changeit
         alias: seal
   ```
5. stamping opens `/seal/seal.p12` (bind-mounted from
   `dmss-digital-stamping-service/seal/seal.p12`), finds the entry under
   alias `seal`, returns the certificate as hex.
6. container-signature computes the SHA-256 digest of the PDF + signature
   placeholder, then calls
   `POST .../api/sign/digest/as/TrustLynx` with the digest bytes.
7. stamping signs the digest with the private key from the same keystore
   entry, returns the signature as hex.
8. container-signature splices the signature into the PDF's
   `/Type /Sig` dictionary and returns the signed PDF to ps-server.

If any link in this chain has a typo - profile name not in JSON,
`esealCompany` not in stamping's `application.yml`, alias not in the
keystore, keystore password mismatch - the request returns 5xx and
ps-server's graceful-skip path returns `200 { stampStatus: "skipped" }`
so the SPA flow continues without a seal. Inspect
`docker compose logs dmss-digital-stamping-service` and
`docker compose logs dmss-container-and-signature-services` to find the
root cause.

---

## 4.3 Initial deployment (fresh install)

Pass `--enable-local-eseal` to `bootstrap.sh` and the stack comes up with
local e-sealing ready to use:

```bash
./installation-scripts/bootstrap.sh \
    --host padsign.client.com \
    --company-role "ClientName" \
    --admin-pass "StrongKeycloakAdminPass" \
    --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
    --cert-key ./installation-scripts/certs/padsign.client.com.key \
    --enable-local-eseal
```

What happens additionally when the flag is set:

- `dmss-digital-stamping-service/` is staged with the demo `application.yml`,
  `seal/seal.p12`, and a `seal/README.md` explaining the demo cert.
- The new service block (gated by `profiles: ["local-eseal"]`) is appended
  to `docker-compose.yml` if not already present.
- `dmss-container-and-signature-services/application.yml` is patched so its
  `digital-stamping-service.baseUrl` resolves to the in-network container.
- `SPRING_SECURITY_USER_NAME=user` / `SPRING_SECURITY_USER_PASSWORD=changeit`
  are pinned on container-signature so basic auth from ps-server is stable.
- `STAMP_MODE: "local"` and a `STAMP_LOCAL` block are inserted into
  `config/config.js` (or `STAMP_MODE` is flipped if it already existed).
- `COMPOSE_PROFILES=local-eseal` is appended to `.env` so every subsequent
  `docker compose up -d` includes the new service automatically.

---

## 4.4 Existing deployment (upgrade an already-deployed instance)

This is the section to follow if your PadSign deployment is currently
running on a repo version from **before** this feature was added (any
version where `installation-scripts/upgrade.sh` does **not** have the
`--enable-local-eseal` flag, and `config/config.js` does **not** have
`STAMP_MODE` / `STAMP_LOCAL` fields). It walks you through, in order:

- enabling local e-sealing with the **demo cert** that ships in the repo,
- verifying the demo signing works end to end,
- replacing the demo cert with your **own production key + certificate**
  and verifying that too,
- the rollback recipes if anything goes wrong.

The flow is non-destructive: external mode keeps working until you
explicitly switch `STAMP_MODE` to `"local"`. Every step is reversible
either via the `*.bak` files the script creates or with a small config
edit.

### Phase 1 - Update the deployment scripts and configs

Pull the new version of this repo into your deployment directory.

```bash
cd /opt/psapp

# 1. Sanity-check your remote - should be the same place you cloned from
#    originally:
git remote -v
# Typical output:
#   origin  git@gitlab.com:.../ps-app-cloud-deployment.git (fetch)
#   origin  git@gitlab.com:.../ps-app-cloud-deployment.git (push)

# 2. Confirm the working tree is clean. If there are local changes, stash
#    or commit them first - `git pull` will refuse to merge over dirty
#    files:
git status

# 3. Pull. Make sure you're on the branch that contains the local-eseal
#    feature; in this repo that branch is `main`:
git checkout main      # safe even if you're already on it
git pull               # fast-forward to the latest upstream commit
```

If you can't pull from a git remote (air-gapped host, no SSH keys, etc.),
the alternative is to download the repo as a `.zip` / `.tar.gz` from
your source code platform on a workstation with internet access, copy
it to the deployment host (scp / USB / internal artefact repo), unpack
it next to the existing deployment, and overwrite the changed files in
place. Don't delete `signed-output/`, `docs/`, your `*.bak` files, or
any customer-specific configs you've added.

After the pull (or unpack), confirm three things landed:

```bash
# 1. The upgrade script gained the new flag (look for "--enable-local-eseal"
#    in the usage text):
./installation-scripts/upgrade.sh --help | grep -i local-eseal

# 2. The pristine asset directory exists (this is where the demo cert
#    gets copied from during the next phase):
ls installation-scripts/assets/dmss-digital-stamping-service/seal/seal.p12

# 3. The DocumentSigningProfiles JSON now has a LocalDemo entry (this
#    is what the demo URL targets):
grep -A2 '"LocalDemo"' dmss-container-and-signature-services/documentsigningprofiles.json
```

If any of those three checks fail, the repo version you pulled does not
contain the local-eseal feature. Stop here and double-check the branch /
tag you fetched.

### Phase 2 - Enable local e-sealing with the demo cert

Run the upgrade script with the new flag:

```bash
cd /opt/psapp
./installation-scripts/upgrade.sh --enable-local-eseal
```

The script prints its progress as it runs. What you should see:

```
========================================
PadSign Upgrade
========================================

Step 1/6: Backing up...
  Backups created
Step 2/6: Updating image tags...
Step 3/6: Ensuring DOCUMENT_ROUTING config...
  DOCUMENT_ROUTING already present
Step 4/6: Ensuring signed-output volume...
  Volume mount already present
Step 4b/6: Enabling local e-sealing...
  Demo stamping artifacts staged at ./dmss-digital-stamping-service/
  Compose service block appended (gated by profiles: [local-eseal])
  Patched dmss-container-and-signature-services/application.yml baseUrl
  Pinned Spring Security creds on container-signature
  Inserted STAMP_MODE=local + STAMP_LOCAL in config.js
  Wrote COMPOSE_PROFILES=local-eseal to .env
Step 5/6: Pulling images and restarting...
   ...docker pull / up output...
Step 6/6: Verifying...
   ...health check output...
```

If you're re-running the script on a deployment that already went
through Step 4b at least once, some lines will read "already present"
instead of the verbs above - for example:

```
Step 4b/6: Enabling local e-sealing...
  Stamping artifacts already present (preserved)
  Compose service block already present
  Container-signature baseUrl already patched (or non-default)
  Spring Security creds already pinned
  STAMP_MODE already set to "local" in config.js
  .env already activates local-eseal profile
```

Either output is healthy - `Step 4b` is intentionally idempotent so
re-running the upgrade is always safe.

**What the script did:**

1. **Backed up** `docker-compose.yml` and `config/config.js` to
   `.bak` files in place (rollback safety).
2. Did not change any image tags (Step 2) - you didn't pass
   `--server-tag` or `--client-tag` so existing pins on `ps-server` and
   `ps-client` are preserved. Skip this if you only ran `--enable-local-eseal`.
3. Confirmed `DOCUMENT_ROUTING` already in `config.js` (it should be).
4. Confirmed `signed-output` volume mount already in compose.
5. **Step 4b is the new part.** Six sub-steps:
   - Copied `application.yml`, `seal/seal.p12`, and `seal/README.md`
     from `installation-scripts/assets/dmss-digital-stamping-service/`
     into a new `dmss-digital-stamping-service/` directory at the
     repo root. These get bind-mounted into the new stamping container.
   - Appended a new `dmss-digital-stamping-service:` service block to
     `docker-compose.yml`. The block carries `profiles: ["local-eseal"]`
     so it never starts on a plain `docker compose up -d` - it only
     starts when the `local-eseal` profile is active.
   - Edited `dmss-container-and-signature-services/application.yml`:
     changed `digital-stamping-service.baseUrl` from
     `http://host.docker.internal:8084/api` (host-based USB-token
     signer - what some deployments use) to
     `http://dmss-digital-stamping-service:8084/api` (the new in-network
     stamping container).
   - Added `SPRING_SECURITY_USER_NAME=user` and
     `SPRING_SECURITY_USER_PASSWORD=changeit` env vars on the
     `dmss-container-and-signature-services` service, so the HTTP Basic
     auth between ps-server and container-signature has stable known
     credentials (the default is a random UUID password that changes
     every restart, which is impossible to script against).
   - Added two fields to `config/config.js`: `STAMP_MODE: "local"` and
     a `STAMP_LOCAL: { url, username, password, timeoutMs }` block.
     These tell ps-server's `/api/stamp` handler to route through the
     local stamping stack instead of the cloud e-sealing service.
   - Wrote `COMPOSE_PROFILES=local-eseal` to `.env` so all subsequent
     `docker compose up -d` invocations automatically include the new
     stamping service.
6. **Pulled** the `trustlynx/digital-stamping-service:24.0.3.0` image
   (~830 MB; first pull only). Created and started
   `dmss-digital-stamping-service`. Recreated
   `dmss-container-and-signature-services` and `ps-server` so they
   pick up the patched config and env vars. **No other services
   restart.**

After the script finishes, verify the new container is running:

```bash
docker compose ps
```

You should see `dmss-digital-stamping-service` listed with status `Up`,
in addition to the services that were already running.

If you see `dmss-digital-stamping-service` is `Restarting` or
`Exited`, check its logs: `docker compose logs dmss-digital-stamping-service`.
The first-run failures are almost always one of: missing `seal.p12`,
keystore password in `application.yml` not matching the actual P12
password, or an alias mismatch (`alias:` in `application.yml` not present
inside the keystore).

**When can I declare the stack healthy?** The new container takes ~10
seconds to finish Spring Boot startup. Wait until both of these return
true, then proceed to Phase 3:

```bash
# Stamping container reports Spring Boot ready:
docker compose logs --tail 50 dmss-digital-stamping-service \
    | grep -q 'Started Application' && echo "stamping: ready"

# Container-signature (which was recreated) is also back up:
docker compose logs --tail 50 dmss-container-and-signature-services \
    | grep -q 'Started Application' && echo "container-signature: ready"
```

If you don't see "Started Application" for either after ~60 seconds,
inspect the container's logs with `docker compose logs --tail 200 <service>`
to find the Spring Boot startup exception.

**Can I run this during business hours?** Yes for the demo flow with a
caveat. The pieces that restart during `upgrade.sh --enable-local-eseal`
are: `dmss-container-and-signature-services` (recreated to pick up new
env vars; ~25 second outage) and `ps-server` (restarted; ~3 second
outage). During those windows any in-flight `/api/visual-signature` or
`/api/stamp` call returns 502/503 to the SPA and the user has to retry.
nginx, Keycloak, archive-services, ps-client stay up the whole time.
For production-cert deployments where signing must not be interrupted,
schedule the window outside business hours.

**What if upgrade.sh fails mid-way?** The script is idempotent; the
quickest path is usually to fix the underlying problem and re-run it.
Common mid-run failures:

| Failure | What happened | Recovery |
|---|---|---|
| Docker pull timed out / failed | `Step 5/6` couldn't fetch the stamping image | Verify network, then re-run `./installation-scripts/upgrade.sh --enable-local-eseal`. The earlier idempotent steps will print "already present" and skip ahead. |
| Host ran out of disk during pull | Look for `no space left on device` | Free space (`docker system prune` is a common first action), then re-run the script. |
| `Conflict. The container name "..." is already in use` | A stale container from a previous attempt is hanging around | `docker rm -f dmss-digital-stamping-service` (or whatever name is in the error), then re-run. |
| You SIGINT'd the script during edits | Partial state in `config.js` / compose | The `*.bak` files are still there. Either re-run (idempotent) or `cp docker-compose.yml.bak docker-compose.yml; cp config/config.js.bak config/config.js` and start over. |

If you need to bail out completely after a failed run and return to
pre-feature state, see [Phase 8.c](#phase-8---rollback-recipes) - the
hard rollback works whether or not the upgrade finished.

### Phase 3 - Verify the demo signing flow

Three checks. Run them in order; later checks assume earlier ones passed.

**Check 3.1 - The stamping service serves the demo certificate.** Run
this from the deployment host:

```bash
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

The recipe uses only stdlib `python3` (no extra modules) plus `openssl`,
both already required by `bootstrap.sh`.

Expected output:

```
subject=C=LV, O=Trustlynx, OU=Digital Mind Stamping Service, CN=Trustlynx Local Seal Demo
issuer=C=LV, O=Trustlynx, OU=Digital Mind Stamping Service, CN=Trustlynx Local Seal Demo
notBefore=May 11 13:26:58 2026 GMT
notAfter=Aug 13 13:26:58 2028 GMT
```

If `subject` shows a different CN (or the call fails), the stamping
container is not loading your keystore. Verify that
`dmss-digital-stamping-service/seal/seal.p12` exists on disk, that
`dmss-digital-stamping-service/application.yml` lists the matching
`alias:` (default `seal`) and `password:`, then restart the container:
`docker compose restart dmss-digital-stamping-service`.

**Check 3.2 - ps-server can reach the chain end-to-end.** This check
proves the new `STAMP_MODE: "local"` was picked up and ps-server is
routing through container-signature → stamping. Two ways to do it:

*Option A (preferred):* Open `https://<your-deployment-host>/portal/`,
log in as a test user, upload a PDF, and complete the signing flow
exactly as a real user would. The SPA shows a "Download signed PDF"
link when it's done.

*Option B (CLI shortcut, faster but doesn't exercise the SPA):*

```bash
# This calls container-signature's /api/eseal directly with the demo
# profile, skipping the SPA + ps-server. Useful for a quick smoke test
# but does NOT verify the ps-server side of the chain.
curl -sS -u user:changeit -X POST \
    -F "file=@/path/to/any-small.pdf;type=application/pdf" \
    -o /tmp/demo-signed.pdf -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/LocalDemo
```

Whichever you pick, then in a separate terminal:

```bash
docker compose logs --tail 200 ps-server | grep -E '\[stamp\] mode=|Stamp response status'
```

After Option A you should see something like:

```
[stamp] mode=local url=http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo
[DEBUG] Stamp response status: 200
```

(Option B doesn't go through ps-server, so its `[stamp]` line won't
appear - but its HTTP=200 + non-zero bytes is the equivalent proof.)

The key word in the first line is `mode=local`. If it shows `mode=external`,
ps-server is still on the old config - restart it (`docker compose restart
ps-server`) and re-try.

**Check 3.3 - The signed PDF actually has a signature in it.** Download
the latest archived version of the document you just signed in two
possible ways:

*Option A - via the SPA:* the portal page that shows after signing
includes a "Download signed PDF" link. Save the file as `signed.pdf`.

*Option B - directly from dmss-archive-services on the host:*

```bash
# Find the document ID in ps-server logs from your sign operation, e.g.:
#   [stamp] mode=local docid=ARCH-2026-001234
# Then:
curl -fsS "http://localhost:86/api/document/ARCH-2026-001234/download" -o signed.pdf
```

Port 86 is `dmss-archive-services` host-side. If your deployment moved
that port, check `docker-compose.yml`. If you used Option B in Phase 3.2's
CLI shortcut
(curl-to-container-signature), the result is already at
`/tmp/demo-signed.pdf` - use that path directly.

Then verify the signature dictionary is present:

```bash
grep -aoE '/Type\s*/Sig|/Filter\s*/Adobe\.PPKLite|/ByteRange\s*\[[^]]+\]' signed.pdf
```

Expected output:

```
/Type /Sig
/Filter /Adobe.PPKLite
/ByteRange [0 271790 290736 525]
```

(The exact ByteRange numbers depend on your PDF.) All three lines must
be present. If any is missing, the signature dictionary wasn't embedded
- check `docker compose logs dmss-container-and-signature-services` for
errors.

**Optional: open the signed PDF in Adobe Reader.** Open the file in
Adobe Acrobat Reader DC and look at the Signature Panel (left sidebar).
With the demo cert you will see:

> ⚠ At least one signature has problems.
> Document has not been modified since the signature was applied.
> Signer's identity is unknown because it could not be checked.

That outcome is **expected and correct** for the demo cert - the seal
itself is cryptographically valid, but the demo CA is self-signed and
Adobe doesn't trust it. You will get a green check ("Signed and all
signatures are valid") only after Phase 5 with a real CA-issued cert.

### Phase 4 - Decide what to do next

At this point your stack signs PDFs locally with the demo cert. Three
paths:

- **Move on to production-cert testing (Phase 5).** This is the path
  most customers want. Continue below.
- **Stay on the demo cert** if you only need an internal-test
  environment where the consumer of the signed PDFs doesn't validate
  the trust chain. Skip to [Phase 7](#phase-7---harden-before-exposing-the-stack)
  to harden the deployment before exposing it.
- **Revert and stay on external e-sealing**. If demo signing failed
  Phase 3 checks or you've decided local e-sealing isn't the right
  approach yet, see [Phase 8](#phase-8---rollback-recipes) for the
  reversal options.

### Phase 5 - Set up for production test with your real key and certificate

This phase replaces the demo cert with your own production signing
material and verifies signing still works end to end. It is a *test*
phase even when using the real cert - meaning you confirm signatures
verify correctly in a representative environment before going live.

How long this takes depends on whether you already have a signing
certificate or still need to request one from a public CA (which can
be days or weeks of CA SLA + organisational paperwork).

#### Step 5.1 - Source your signing certificate

Decide what kind of certificate you need:

| Use case | Certificate type | Example providers |
|---|---|---|
| eIDAS-qualified e-seal (legal validity across EU) | Qualified electronic seal cert from a qualified Trust Service Provider (qTSP), issued to a legal-entity identifier (NTRLV / EORI / VAT number) | eParaksts (LV), SK ID Solutions (EE), Certum (PL), DigiCert (multi-country) |
| Code-signing / generic cryptographic seal (no eIDAS claim) | Standard cert from a public CA | Sectigo, DigiCert, GlobalSign, etc. |
| Internal-use only (signing internal docs your own systems verify) | Cert from your internal/private CA | Your org's PKI team |

Make sure the cert you request supports **digital signature** and
optionally **non-repudiation** key usages. Some CAs require you to
specify "qualified seal" or "qualified signature" at issuance time -
the two are different products under eIDAS.

Once your CA fulfils the request you will typically receive:

- A **certificate file** (`.crt` / `.cer` / `.pem`).
- A **private key file** (`.key`, often password-protected).
- Optionally, an **intermediate chain** file (`chain.crt` or similar).

Or you may receive a single **PKCS12 bundle** (`.pfx` / `.p12`) that
already contains all of the above, protected by one password.

#### Step 5.2 - Build a deployment-ready `seal.p12`

Follow [Production setup: deploying with your own key and certificate](#46-production-setup-deploying-with-your-own-key-and-certificate)
to convert whatever your CA delivered into a PKCS12 keystore that the
stamping service can consume. Pick the recipe that matches your
artefact shape (separate files, existing .pfx, or alias rename).
Verify with `keytool -list -v` before continuing.

#### Step 5.3 - Decide on a signature level

The shipped `LocalDemo` profile uses `B_BES` because the demo cert is
self-signed and no TSA will issue a timestamp for it. With a real
CA-issued cert you usually want a higher level.

Open [Step 4 of Production setup](#46-production-setup-deploying-with-your-own-key-and-certificate) and use the table there to pick:

- **`B_BES`** if your cert is from an internal CA OR your verifiers
  don't need eIDAS legal validity.
- **`LT`** if your cert is from a publicly trusted CA AND you want
  long-term verifiability (most production use cases).
- **`LTA`** if you also need archival timestamps (long-retention
  scenarios).

If you pick anything other than `B_BES`, complete
[Wiring TSA and OCSP for LT and LTA signature profiles](#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)
before continuing - your signing will fail without a TSA configured.

#### Step 5.4 - Add a production-specific profile (recommended)

Don't modify the shipped `LocalDemo` profile - keep it intact as a known-good
fallback. Add a new profile (e.g. `AcmeProductionSeal`) following
[Adding a new signing profile end-to-end](#47-adding-a-new-signing-profile-end-to-end).
The 6 steps in that section walk through editing
`documentsigningprofiles.json`, adding a new company in
`dmss-digital-stamping-service/application.yml`, updating
`STAMP_LOCAL.url` in `config.js`, and restarting the right services.

#### Step 5.5 - Rotate the three default credentials

Now is the right time to replace the three `changeit` defaults with
strong unique passwords:

1. **keystore password** - set during keystore creation (see
   [Production setup: deploying with your own key and certificate](#46-production-setup-deploying-with-your-own-key-and-certificate)
   Recipe A/B/C).
2. **`password:` field in `dmss-digital-stamping-service/application.yml`**
   under `providers:` - must match the keystore password from step 1.
3. **`SPRING_SECURITY_USER_PASSWORD` env var on `dmss-container-and-signature-services`**
   in `docker-compose.yml`, plus the matching `STAMP_LOCAL.password`
   in `config/config.js` - these gate the HTTP endpoint
   container-signature exposes; use a *different* strong unique
   password from step 1.

Skipping this step leaves your container-signature endpoint open to
anyone who knows the deployment convention. Don't skip it.

#### Step 5.6 - Smoke-test the production cert

Use the same three checks as Phase 3, but adapted for the production
profile:

```bash
# 5.6.1 - Cert endpoint serves your real cert. Replace <YourCompany>
#         with the company name you added in Step 5.4.
# Note: the stamping service has no HTTP auth itself; the Spring Security
# credentials you rotated above gate container-signature, not stamping.
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/<YourCompany> \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

Confirm `subject` matches the CN/DN your CA issued and `issuer` matches
the CA's name. Critically, `subject` must **not** still say "Trustlynx
Local Seal Demo" - if it does, the stamping container is still serving
the demo cert (the swap didn't take effect, see Phase 8 for rollback or
re-check Step 5.2 / 5.4).

```bash
# 5.6.2 - End-to-end sign through ps-server. Pick a test PDF.
#         Replace <ProductionProfile> with the profile name from Step 5.4.
curl -sS -u user:<your-new-spring-security-password> -X POST \
    -F "file=@/path/to/test.pdf;type=application/pdf" \
    -o /tmp/prod-test.pdf \
    -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/<ProductionProfile>

# Verify the output is a signed PDF:
grep -aoE '/Type\s*/Sig|/Filter\s*/Adobe\.PPKLite|/ByteRange' /tmp/prod-test.pdf
```

**Step 5.6.3 - Sign through the actual SPA flow.** This is what real
users will do, so it's the most relevant check. Open the portal:

```
https://<your-deployment-host>/portal/
```

Log in with a test user, upload a small PDF (or open one of the demo
forms), and complete the signing flow as you normally would. Then:

```bash
# Watch ps-server logs as the request comes in:
docker compose logs -f --tail 50 ps-server | grep -E '\[stamp\]|Stamp response'
# Expect:  [stamp] mode=local url=http://dmss-container-and-signature-services:8092/api/eseal/document/profile/<ProductionProfile>
#          [DEBUG] Stamp response status: 200

# Pull the latest archived version of the signed document. Replace
# <docid> with the document ID shown after signing (visible in ps-server
# logs and in the SPA's URL bar after upload):
curl -fsS "http://localhost:86/api/document/<docid>/download" -o /tmp/spa-signed.pdf
grep -aoE '/Type\s*/Sig|/Filter\s*/Adobe\.PPKLite' /tmp/spa-signed.pdf
```

If both grep matches print, the SPA-driven sign path is working with
your production cert. If you get `{ stampStatus: "skipped" }` in
ps-server logs instead of a 200, the stamping container or
container-signature is returning an upstream error - inspect their
logs (`docker compose logs --tail 200 dmss-digital-stamping-service`
and `... dmss-container-and-signature-services`) for the underlying
Spring exception.

#### Step 5.7 - Verify the signature externally (the real test)

The smoke tests above prove the *stack* produces a signature. The real
question for a production cert is whether a *verifier* trusts it.

Run the full procedure in
[Verifying signatures end-to-end (beyond the stack)](#410-verifying-signatures-end-to-end-beyond-the-stack):

- Open the signed PDF in Adobe Acrobat Reader DC and check the
  Signature Panel. With a publicly-trusted CA + a TSA-backed LT
  profile, you should now see **"Signed and all signatures are valid"**
  (green check). If you see "valid but the signer's identity is
  unknown", the verifier's trust store doesn't include your CA -
  see the Adobe trust-store discussion in that section.
- Run `pdfsig <signed.pdf>` and confirm both
  `Signature Validation: Signature is Valid` and
  `Certificate Validation: Certificate is Trusted` (the second one is
  what was missing for the demo cert).
- Optionally, run any downstream verifier your customer / counterparty
  actually uses, against the test-signed PDF. This is the only check
  that proves your real-world consumers will accept your signatures.

If any verification fails, the most common causes are: the verifier's
trust store does not include your CA (re-issue your cert from a CA the
verifier already trusts, or have your IT add your CA to the verifier's
trust store); the signature is `B_BES` and the verifier requires `LT` /
`LTA` (see
[Wiring TSA and OCSP for LT and LTA signature profiles](#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles));
or the cert's `keyUsage` is missing `digitalSignature` /
`nonRepudiation` (re-issue with the correct key usage).

### Phase 6 - Plan for go-live

You now have a stack that produces real, externally-valid signatures
on demand. Before opening it up to production traffic:

1. **Schedule the cert-expiry alert.** Set a calendar reminder for
   **60 days before** the cert's `notAfter` date, plus an automated
   probe that calls
   `http://dmss-digital-stamping-service:8084/api/signing/certificate/for/<company>`
   daily and pages on `< 30 days remaining`.
2. **Back up the production keystore.** Encrypted backup, password
   stored separately from the keystore (different storage, different
   access list - see
   [Production setup: deploying with your own key and certificate](#46-production-setup-deploying-with-your-own-key-and-certificate)
   Step 5).
3. **Test the restore** from your backup once. A backup you have not
   verified is not a backup.

### Phase 7 - Harden before exposing the stack

Before opening the stack to production traffic, walk through these
hardening items. The two highest-impact ones if you do nothing else:

- **Restrict the container-signature host port** - bind `84` to
  `127.0.0.1:84:8092` so it's not reachable from the LAN.
- **Confirm the three credentials are rotated** (Step 5.5 above).

### Phase 8 - Rollback recipes

Three levels of revert, ordered from softest to hardest. Use the
softest one that fits your situation.

#### 8.a - Switch back to external e-sealing without removing the local stack

Useful if you want to keep the local stamping container deployed but
have ps-server temporarily route stamping requests to the cloud
service. Same recipe as
[Switching modes after install -> From Local back to External](#45-switching-modes-after-install):
edit `STAMP_MODE` to `"external"` in `config/config.js`, then:

```bash
docker compose restart ps-server
```

After this, every `/api/stamp` request hits the cloud service. The
stamping container is still running but receives no traffic.

#### 8.b - Stop the stamping container too

Frees the resources the stamping container holds (memory, the bind
mounts), but leaves all the new files in place so you can re-enable
later.

1. Open `.env` and remove (or comment out) the
   `COMPOSE_PROFILES=local-eseal` line, so `docker compose` no longer
   includes the stamping service automatically:

   ```
   # .env  (after edit)
   # COMPOSE_PROFILES=local-eseal     <-- line deleted or commented out
   ```

2. Stop the stamping container:

   ```bash
   docker compose --profile local-eseal down dmss-digital-stamping-service
   ```

To re-enable, follow
[Switching modes after install -> From External back to Local](#45-switching-modes-after-install).

#### 8.c - Hard rollback to pre-feature state

Use the `*.bak` files `upgrade.sh` created in Phase 2. This restores
`config/config.js` and `docker-compose.yml` to exactly what they were
before `--enable-local-eseal` ran. The new
`dmss-digital-stamping-service/` directory, the
`installation-scripts/assets/` directory, and the patched
container-signature `application.yml` stay on disk but are no longer
referenced by the active configs.

1. Restore the two `.bak` files:

   ```bash
   cd /opt/psapp
   cp docker-compose.yml.bak docker-compose.yml
   cp config/config.js.bak  config/config.js
   ```

2. Open `.env` and remove the `COMPOSE_PROFILES=` line entirely (it
   came from `upgrade.sh --enable-local-eseal`):

   ```
   # .env  (after edit - the line is gone)
   ```

3. Bring the stack back to the pre-feature state:

   ```bash
   docker compose --profile local-eseal down dmss-digital-stamping-service
   docker compose up -d
   docker compose restart ps-server   # bind-mounted config.js changed; ps-server
                                      # must restart to re-read it
   ```

If you want a *complete* rollback that also removes the new files (only
do this if you are sure you won't re-enable local-eseal soon):

1. Stop the stamping container and delete its on-disk directory:

   ```bash
   docker compose --profile local-eseal down dmss-digital-stamping-service
   rm -rf dmss-digital-stamping-service
   ```

2. Open `dmss-container-and-signature-services/application.yml` and
   change the `digital-stamping-service.baseUrl` line back to the
   pre-feature value:

   ```yaml
   # dmss-container-and-signature-services/application.yml  (around line 148)
   digital-stamping-service:
     baseUrl: http://host.docker.internal:8084/api      # was: http://dmss-digital-stamping-service:8084/api
   ```

3. Apply:

   ```bash
   docker compose up -d
   docker compose restart dmss-container-and-signature-services   # picks up the baseUrl edit
   ```

After any hard rollback, sign a test document via the SPA and confirm
ps-server logs show `[stamp] mode=external` (or that signing simply
works as it did before, depending on which rollback level you used).

---

## 4.5 Switching modes after install

Once the local stack is provisioned, switching between external and local
e-sealing is purely a configuration change. **No scripts to run** - just
edit two files in any text editor (`vi`, `nano`, VS Code over SSH, etc.)
and restart the services that read those files.

There are two files involved:

- `config/config.js` - holds `STAMP_MODE`, which tells `ps-server` which
  e-sealing path to use on every `/api/stamp` request.
- `.env` - holds `COMPOSE_PROFILES`, which tells `docker compose` whether
  to start the `dmss-digital-stamping-service` container.

The two values must agree. The recipes below show exactly which line to
change in each file.

---

### From Local back to External

**File 1 of 2: `config/config.js`**

Open the file in an editor and find the `STAMP_MODE` field near the top
of the `module.exports = {...}` block. Change its value from `"local"` to
`"external"`:

```js
// config/config.js  (excerpt - top of the exported config object)
module.exports = {
  // ...

  //
  // ─── E-SEALING MODE ────────────────────────────────────────────
  //
  STAMP_MODE: "external",   // ← change this line  (was: "local")

  STAMP_LOCAL: {
    // (leave this block in place; it is ignored when STAMP_MODE is "external")
    url:      "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
    username: "user",
    password: "changeit",
  },

  // ...
};
```

Save and close.

**File 2 of 2: `.env`** (next to `docker-compose.yml`)

Open `.env` and **delete** (or comment out with `#`) the
`COMPOSE_PROFILES=local-eseal` line:

```
# .env  (before)
COMPOSE_PROFILES=local-eseal      # ← delete this entire line
```

```
# .env  (after)
# (line removed)
```

Save and close.

**Apply the change**

```bash
docker compose restart ps-server                                          # picks up the config.js edit
docker compose --profile local-eseal down dmss-digital-stamping-service   # optional - stops the now-unused stamping container
```

From now on every `/api/stamp` request from the SPA goes to the external
cloud e-sealing service (`eseal.trustlynx.com`). Confirm with:

```bash
docker compose logs ps-server --tail 20 | grep '\[stamp\] mode='
# expect: [stamp] mode=external ...
```

---

### From External back to Local

(Use this after you have run `bootstrap.sh --enable-local-eseal` or
`upgrade.sh --enable-local-eseal` at least once. The stamping
container's compose service block and the demo keystore must already
exist on disk - the script invocation puts them there.)

**File 1 of 2: `config/config.js`**

Open the file and change `STAMP_MODE` from `"external"` to `"local"`:

```js
// config/config.js  (excerpt)
module.exports = {
  // ...

  //
  // ─── E-SEALING MODE ────────────────────────────────────────────
  //
  STAMP_MODE: "local",      // ← change this line  (was: "external")

  STAMP_LOCAL: {
    url:      "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo",
    username: "user",
    password: "changeit",
    // timeoutMs: 30000,    // optional override of the default 30s upstream timeout
  },

  // ...
};
```

Save and close.

**File 2 of 2: `.env`**

Open `.env` and add the `COMPOSE_PROFILES=local-eseal` line if it is
missing. If `COMPOSE_PROFILES=` already exists with other profiles, add
`local-eseal` to the comma-separated list:

```
# .env  (before - line missing or another profile only)
# (no COMPOSE_PROFILES line)
```

```
# .env  (after - new line added)
COMPOSE_PROFILES=local-eseal      # ← add this line
```

Save and close.

**Apply the change**

```bash
docker compose up -d                # starts the stamping container (now part of the active profile set)
docker compose restart ps-server    # picks up the config.js edit so STAMP_MODE=local takes effect
```

Confirm with:

```bash
docker compose ps | grep dmss-digital-stamping-service    # should now appear as Up
docker compose logs ps-server --tail 20 | grep '\[stamp\] mode='
# expect: [stamp] mode=local ...
```
## 4.6 Production setup: deploying with your own key and certificate

This is the main path for putting local e-sealing into production. The
shipped `dmss-digital-stamping-service/seal/seal.p12` is a self-signed
RSA-2048 demo keystore (alias `seal`, password `changeit`, valid until
2028-08-13). **Do not use it for real signatures.** The recipes below
build a new PKCS12 keystore from whatever artefacts your CA provided and
deploy it into the stamping service.

### Step 1 - Inventory what you have

Your CA (or your internal PKI team) typically delivers signing material in
one of these shapes. Identify yours and follow the matching recipe:

| You have... | Use Recipe |
|---|---|
| separate `cert.crt` (or `.pem` / `.cer`) **and** `private.key` file, optionally a separate `chain.crt` of intermediate CA certs | **A** |
| a single bundle file in PKCS12 format - `.pfx` (typical Windows) or `.p12` (typical Linux/Java), password-protected | **B** |
| an existing `.p12` that uses an alias other than `seal` | **C** |
| a single PEM file that contains the cert AND the key (and maybe the chain) concatenated | split it manually (see *Splitting a PEM bundle* below) then use Recipe A |

If your private key is itself password-protected (asks for a passphrase
when you try to read it), keep that passphrase handy - the recipes accept
it where needed.

The recipes use `openssl` and `keytool` (from the JDK). Both are already
required by `bootstrap.sh`. Replace `<your-keystore-password>` with a
strong password you choose; do not reuse it from any other system.

### Recipe A - From separate `cert.crt` + `private.key` (+ optional `chain.crt`)

```bash
# Without an intermediate-CA chain:
openssl pkcs12 -export \
    -in    cert.crt \
    -inkey private.key \
    -name  seal \
    -out   seal.p12 \
    -passout pass:<your-keystore-password>

# With an intermediate-CA chain (recommended - most verifiers need the
# full chain to validate your signature):
openssl pkcs12 -export \
    -in       cert.crt \
    -inkey    private.key \
    -certfile chain.crt \
    -name     seal \
    -out      seal.p12 \
    -passout pass:<your-keystore-password>
```

Flags explained:

- `-export` - write a PKCS12 file (the default mode is the opposite).
- `-in cert.crt` - your end-entity certificate (the one matching your private key).
- `-inkey private.key` - the matching private key.
- `-certfile chain.crt` - intermediate CA cert(s), concatenated in PEM
  form (intermediate first, root last). Omit if you have no chain to bundle.
- `-name seal` - the alias inside the keystore. The stamping service looks
  for `seal` by default; using any other name forces an `application.yml`
  edit later (see *Step 4*).
- `-out seal.p12` - output filename.
- `-passout pass:…` - the password protecting the keystore. Anything
  password-shaped works; avoid `changeit` and similar known defaults.

If your `private.key` is itself encrypted with its own passphrase, openssl
will prompt you for it - or you can pass `-passin pass:<key-passphrase>`
non-interactively.

### Recipe B - From an existing `.pfx` / `.p12`

The most common case: your CA gave you a `cert.pfx` and a password for it.
If the existing keystore already uses `seal` as the alias, you only need
to copy the file and set the right password in `application.yml` -
**skip to Step 3**.

If the alias inside the `.pfx` is something else (typical CAs use long
identifiers like the CN of the subject), one option is to rename in place
- see Recipe C. The cleanest option is to re-export:

```bash
# Convert to PEM intermediates, then re-export with alias 'seal'.
# Keeps the same key and cert; only changes the alias and password.
openssl pkcs12 -in source.pfx -nokeys  -passin pass:<source-pwd> -out _tmp_cert.pem
openssl pkcs12 -in source.pfx -nocerts -passin pass:<source-pwd> \
    -nodes -out _tmp_key.pem
openssl pkcs12 -export \
    -in    _tmp_cert.pem \
    -inkey _tmp_key.pem \
    -name  seal \
    -out   seal.p12 \
    -passout pass:<your-keystore-password>
rm _tmp_cert.pem _tmp_key.pem
```

The two intermediate files contain unencrypted key material - delete them
immediately after the export and run on a workstation you trust (not a
shared CI runner).

### Recipe C - Rename the alias inside an existing `.p12`

If you'd rather keep the existing `.p12` byte-for-byte (only changing the
internal alias name to `seal`), `keytool` can do this in place:

```bash
keytool -changealias \
    -keystore  source.p12 \
    -storetype PKCS12 \
    -storepass <source-pwd> \
    -alias     <existing-alias-name> \
    -destalias seal

# Then rename or copy:
cp source.p12 seal.p12
```

`keytool -list -keystore source.p12 -storepass <source-pwd>` (see Step 2)
tells you what the existing alias name is.

### Splitting a PEM bundle

Some CAs deliver one file containing cert, key, and chain concatenated.
Split it before running Recipe A:

```bash
# Extract certificate (and chain if present) into cert.crt:
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' bundle.pem > cert.crt
# Extract private key (first key block):
awk '/-----BEGIN .* PRIVATE KEY-----/,/-----END .* PRIVATE KEY-----/' bundle.pem > private.key
```

### Step 2 - Verify the new keystore

Before deploying, confirm the keystore actually contains what you expect:

```bash
# What aliases are inside? Should list one entry named 'seal'.
keytool -list -keystore seal.p12 -storepass <your-keystore-password>

# Detailed view of the 'seal' entry - subject DN, issuer DN, validity dates,
# key algorithm, the public-cert chain.
keytool -list -v -keystore seal.p12 -storepass <your-keystore-password> -alias seal

# Full chain dump in OpenSSL format (useful for spotting missing intermediates).
openssl pkcs12 -in seal.p12 -info -nokeys -passin pass:<your-keystore-password>
```

What to check:

- **Alias** equals `seal` (or whatever you'll set in `application.yml`).
- **Subject DN** matches the identity you want to appear on signed PDFs
  (the CN typically becomes the "Signed by" name shown by Adobe Reader).
- **Issuer DN** matches the CA that issued your cert.
- **Validity** - `notAfter` is far enough in the future that you have
  time to plan rotation.
- **Key algorithm** - typically `RSA` 2048+ or `EC` (ECDSA). digidoc4j
  supports both.
- **Chain length** - for non-self-signed certs you should see at least
  two certificates in the chain dump (your end-entity cert + at least
  one intermediate). If `openssl pkcs12 -info` shows only one cert, your
  signatures will probably fail external trust validation; rebuild with
  `-certfile chain.crt`.

### Step 3 - Deploy the new keystore

```bash
cd /opt/psapp   # wherever the deployment lives

# Stop only the stamping container (no service interruption to ps-server
# or container-signature beyond brief signing unavailability).
docker compose stop dmss-digital-stamping-service

# Replace the demo PKCS12 with yours.
cp /path/to/your/seal.p12 dmss-digital-stamping-service/seal/seal.p12

# Make sure permissions are tight; the keystore is a secret.
chmod 600 dmss-digital-stamping-service/seal/seal.p12

# Update the stamping service config to match your password (and alias if
# different from 'seal'). Open the file:
vi dmss-digital-stamping-service/application.yml
#   change:    password: changeit
#   to:        password: <your-keystore-password>
#   if your alias is not 'seal', also change:
#                alias: seal   →   alias: <your-alias>

# Bring the stamping container back up.
docker compose --profile local-eseal up -d dmss-digital-stamping-service
```

Smoke test that the new cert is what the service serves:

```bash
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

The printed subject must match what you saw in Step 2; if it shows the
demo cert's DN (`CN=Trustlynx Local Seal Demo`) then the keystore swap
did not take effect - check the file path and that the container actually
restarted.

### Step 4 - Pick the right `signatureProfile` for your certificate

The shipped `LocalDemo` profile uses `B_BES`, which is the only level
that works with the self-signed demo cert. Once your cert is in place
you most likely want a higher level. Decide based on what your CA is:

| Your CA | Suggested profile | Why |
|---|---|---|
| Publicly-trusted CA listed in an EU member-state TSL (eIDAS-qualified TSP) | `LT` (for most use cases) or `LTA` (for long-retention archives) | Produces eIDAS-grade advanced/qualified signatures. Needs TSA + OCSP wiring - see next section. |
| Public CA, but not on an EU TSL | `LT` | Cryptographically equivalent, but not eIDAS-qualified. Still recognised by Adobe Reader and most PDF verifiers. |
| Internal / private CA (your own org's PKI) | `B_BES` | LT/LTA need OCSP/TSA wiring AND a verifier that trusts your internal CA. B_BES sidesteps both. |
| You don't know | `B_BES` to start | Get the flow working end-to-end first. Move to LT later by following the next section. |

Don't change the shipped `LocalDemo` profile - it's the safe demo path.
Create your own profile instead:
[Adding a new signing profile end-to-end](#47-adding-a-new-signing-profile-end-to-end).
If you need timestamping (anything above B_BES), continue to:
[Wiring TSA and OCSP for LT and LTA signature profiles](#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles).

### Step 5 - Storing the keystore password

The keystore password ends up in `dmss-digital-stamping-service/application.yml`
(in plaintext, since Spring needs to read it at startup). Apply the same
treatment as any production secret:

- Do **not** commit the production `application.yml` to source control.
  Keep it on the deployment host only. The committed default in this repo
  is the demo password - that's intentional and safe.
- Make the file readable only by the user that owns the docker daemon
  (or by `root`): `chmod 600 dmss-digital-stamping-service/application.yml`.
- Keep an offline copy of the keystore password separate from the
  keystore itself - different storage, different access list. If you
  use a secret manager (Vault, AWS Secrets Manager, etc.) the password
  goes there; the keystore can live on disk or also in the secret manager.
- Decide a rotation cadence and document it in your internal runbook.
- Never reuse the keystore password for any other system.

---

## 4.7 Adding a new signing profile end-to-end

You usually want a profile that's distinct from the shipped `LocalDemo`
demo, so the demo and your production behaviour can coexist (and you can
keep `LocalDemo` working as a known-good smoke test). The profile name
appears in the URL that `ps-server` posts to, so it doubles as your
"signing identity" in logs and audits.

Pick a profile name and a company name. They can be the same, but the two
fields play different roles:

- **Profile name** - the value in
  `documentsigningprofiles.json` `.name` and in the URL path segment.
  Used to look up signature settings (signatureProfile, visual signature).
- **Company name** - the value in `documentsigningprofiles.json`
  `.esealCompany` and in stamping's `application.yml`
  `stamping.companies[].name`. Used to look up which keystore to sign with.

For this walkthrough we use `AcmeProductionSeal` as the profile name and
`AcmeProd` as the company name.

### Step 1 - Stage the new keystore

Follow [Production setup](#46-production-setup-deploying-with-your-own-key-and-certificate)
to produce your `.p12` keystore. Drop it next to the demo one with a
descriptive filename (so you can tell the two apart):

```bash
cp /path/to/seal.p12 dmss-digital-stamping-service/seal/acme-prod.p12
chmod 600 dmss-digital-stamping-service/seal/acme-prod.p12
```

### Step 2 - Add a company in the stamping service config

Edit `dmss-digital-stamping-service/application.yml`. Add a second entry
to `stamping.companies` (keep the existing `TrustLynx` entry in place so
the demo continues to work):

```yaml
stamping:
  companies:
    - name: "TrustLynx"           # demo - unchanged
      providers:
        - name: P12
          engine: P12
          keystore: file:/seal/seal.p12
          password: changeit
          alias: seal

    - name: "AcmeProd"            # NEW
      providers:
        - name: P12
          engine: P12
          keystore: file:/seal/acme-prod.p12
          password: <your-keystore-password>
          alias: seal             # or your real alias from the new keystore
```

### Step 3 - Add a profile in the container-signature config

Edit `dmss-container-and-signature-services/documentsigningprofiles.json`.
Add a new profile object to the array (the existing `LocalDemo`,
`TrustLynx`, `TrustLynxLV`, `TrustLynxLV_ASICE` entries stay):

```jsonc
{
  "name": "AcmeProductionSeal",
  "esealCompany": "AcmeProd",
  "pdfSigningSigner": {
    "pdfSignatureIsVisible": true,
    "signatureProfile": "LT",
    "pdfSignatureVisuals": {
      "signatureText": "Signed by {cn}\nAt date: {date}"
    }
  }
}
```

Common knobs:

- `signatureProfile`: `B_BES` / `LT` / `LTA`. For `LT` or `LTA`, complete
  [Wiring TSA and OCSP](#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)
  first.
- `pdfSignatureIsVisible`: `true` to render a visible signature stamp on
  the PDF; `false` for an invisible cryptographic-only signature.
- `pdfSignatureVisuals.signatureText`: template; `{cn}` resolves to the
  cert subject CN, `{date}` to the signing timestamp.
- `pdfSignatureVisuals.signatureImage`: base64-encoded PNG to overlay
  (see how the existing `TrustLynx` profile uses this in the same file).
- `esealAsContainer`: set `true` to produce an ASiC-E container instead
  of a sealed PDF. Leave omitted/false for the typical PDF flow.

Validate the JSON before restarting (a typo will silently break ALL
profiles in this file, because Jackson aborts the deserialisation):

```bash
python3 -m json.tool < dmss-container-and-signature-services/documentsigningprofiles.json > /dev/null \
    && echo "JSON OK"
```

### Step 4 - Point ps-server at the new profile

Edit `config/config.js`. Change `STAMP_LOCAL.url` so the path segment
matches your new profile name:

```js
STAMP_LOCAL: {
  url: "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/AcmeProductionSeal",
  username: "user",
  password: "<your-spring-security-password>",
  timeoutMs: 30000
}
```

### Step 5 - Restart the affected services

```bash
# Stamping reloads its keystore on restart; container-signature reloads the
# profile JSON; ps-server reloads config.js. nginx and archive stay running.
docker compose restart \
    dmss-digital-stamping-service \
    dmss-container-and-signature-services \
    ps-server
```

### Step 6 - Smoke test the new profile

```bash
# Stamping should now return your real cert when asked for AcmeProd:
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/AcmeProd \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject

# End-to-end sign a sample PDF (replace /path/to/sample.pdf):
curl -sS -u user:<your-spring-security-password> \
    -X POST -F "file=@/path/to/sample.pdf;type=application/pdf" \
    -o sealed.pdf \
    -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/AcmeProductionSeal

# Confirm the output is a real signed PDF:
grep -aoE '/Type\s*/Sig|/Filter\s*/Adobe\.PPKLite' sealed.pdf
```

### Running multiple companies at once

This pattern scales to as many companies/profiles as you need. Each new
keystore goes in `dmss-digital-stamping-service/seal/`, each new company
gets an entry in `application.yml`, each new profile gets an entry in the
JSON. The URL path segment chooses which profile is used per request, so
`ps-server` can call any of them depending on what flow triggered the
seal - though out of the box `ps-server` always uses the one profile
named in `STAMP_LOCAL.url`. Wiring per-flow profile selection is custom
work outside the scope of this guide.

---

## 4.8 Wiring TSA and OCSP for LT and LTA signature profiles

`B_BES` is a self-contained signature: the signing service just signs the
PDF hash with your private key, embeds the result, done. The verifier
needs your certificate's chain to trust it, but no live network calls
during signing.

`LT` and `LTA` are different. They embed three additional things into the
signature:

1. A **timestamp** from a TSA (timestamp authority) proving when the
   signature was made.
2. **OCSP responses** for each certificate in your trust chain, proving
   none had been revoked at signing time.
3. (For `LTA` only) **archival timestamps** that keep the validation data
   verifiable as cryptographic algorithms age out.

This means the signing host must reach a TSA and one or more OCSP
responders at signing time. If those services are unreachable, your `LT`
sign request will fail with something like `ServiceAccessDeniedException`
or `OcspException` and ps-server's 5xx graceful-skip returns
`{ stampStatus: "skipped" }` to the SPA.

### Picking a TSA

Some commonly-used public TSAs (none are required by this stack - pick
whichever your CA, your jurisdiction, or your service contract specifies):

| TSA endpoint | Typical use | Auth |
|---|---|---|
| `http://tsa.sk.ee` | Estonia SK ID Solutions - qualified TSA for eIDAS | none |
| `http://demo.sk.ee/tsa` | SK demo / non-production | none |
| `http://tsa-com.eparaksts.lv/` | Latvia eParaksts - qualified TSA | none for testing, paid contract for production volumes |
| `http://public-qlts.certum.pl/qts-17` | Poland Certum - qualified TSA | none |
| Your own internal TSA | If you operate one (e.g., for an internal-CA setup) | depends on your TSA - Basic auth header is the typical case |

For eIDAS-qualified signatures, your TSA must itself be listed as
qualified in an EU member-state TSL. Anything else is "advanced" rather
than "qualified".

If your CA is private/internal, you generally also need a private/internal
TSA - otherwise the qualified TSAs above will refuse to timestamp your
hash (some check the requester, most don't, but the resulting timestamp
won't chain to your CA's trust list anyway).

### Configuring the TSA in `application.yml`

`dmss-container-and-signature-services/application.yml` already has a
`timestamp.timestampProviders` block. The default contains three SK
entries (production + demo); customise to your situation:

```yaml
timestamp:
  timestampProviders:
    - tspSource: http://tsa.sk.ee
    # If you need Basic auth:
    # - tspSource: https://your-internal-tsa.example.com/tsp
    #   authentications:
    #     - protocol: https
    #       host:     your-internal-tsa.example.com
    #       port:     443
    #       scheme:   Basic
    #       realm:    YourRealm
    #       username: your-tsa-user
    #       password: your-tsa-password
```

If you replace the list rather than append, restart container-signature
to pick it up: `docker compose restart dmss-container-and-signature-services`.

Smoke-test reachability from inside the container:

```bash
docker exec dmss-container-and-signature-services \
    curl -fsS -X POST -H "Content-Type: application/timestamp-query" \
    --data-binary '' http://tsa.sk.ee
# expect a binary response or "no content"; key is no DNS/network error
```

A connection refused or unknown-host error here means the TSA is not
reachable from your deployment host - usually a firewall / outbound proxy
issue. Check `digidoc4j:` `proxyConfiguration` and the `trustlynx:
useProxyForInternalServices` flag if your environment routes through a
proxy.

### Configuring OCSP and the trust list

OCSP responder URLs are typically published in the certificates
themselves (the AIA - Authority Information Access - extension). With
`digidoc4j.configuration.preferAiaOcsp: true` (the default in this
deployment), the library uses whatever OCSP URL is embedded in the cert
chain, so you usually don't need to configure anything explicitly.

If you do need a custom OCSP setup - or if you're using a private CA whose
certs don't carry AIA - uncomment the relevant lines in
`dmss-container-and-signature-services/digidoc4j-custom.yaml`:

```yaml
# Trusted list location (overrides the default EU LOTL):
# TSL_LOCATION: https://your-tsl-host.example.com/your-tsl.xml
# OCSP responder (used when AIA is not present in the cert):
# OCSP_SOURCE: http://ocsp.your-ca.example.com/
# SSL truststore for HTTPS connections to your TSA / OCSP:
# SSL_TRUSTSTORE_PATH:     file:/confs/ssl_tsl_truststore.p12
# SSL_TRUSTSTORE_PASSWORD: <your-truststore-password>
# Restrict TSL acceptance to specific countries (two-letter codes, _T suffix for test):
# TRUSTED_TERRITORIES: EE, LV
```

Restart container-signature after any change here. The keys are read
once at startup.

### PROD vs TEST digidoc4j mode

`digidoc4j.configuration.mode` in `application.yml` (default `PROD`)
controls which TSL the library consults. In `PROD` mode digidoc4j only
trusts certificates whose chain is rooted in a qualified EU TSL; in
`TEST` mode it accepts development CAs and test TSLs (`tsl-mp-test-EE.xml`,
`Test_Root_CA.cer`, etc., already bundled in
`dmss-container-and-signature-services/digidoc4j-custom.yaml` as
commented references).

For production use stay on `PROD`. For internal tests with self-signed
certs, switch temporarily to `TEST` - but never sign customer-bound
artefacts in `TEST` mode.

---

## 4.9 Verifying it works

After bootstrap or upgrade with `--enable-local-eseal`:

```bash
docker compose ps | grep dmss-digital-stamping-service       # should show Up

# Stamping is reachable inside the docker network from container-signature
docker exec dmss-container-and-signature-services \
    bash -c 'exec 3<>/dev/tcp/dmss-digital-stamping-service/8084 && echo OK'

# The demo cert resolves end-to-end
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('cert[:80]:', d['cert'][:80])"
# expected: cert[:80]: 308203ec308202d4a003020102...

# Sign a demo PDF through the SPA (RUN_STAMPING_REQUEST=true in constants.json)
# and confirm:
docker compose logs ps-server | grep -E '\[stamp\] mode=local'
docker compose logs ps-server | grep -E 'Stamp response status: 200'
```

Download the latest archived version of the signed document and confirm the
PDF contains a signature dictionary (`/Type /Sig` + `/Filter /Adobe.PPKLite`).

---

## 4.10 Verifying signatures end-to-end (beyond the stack)

The smoke test above only proves the stack *produces* a signature
dictionary. It does not prove the signature is **valid** in the eyes of
a real-world PDF verifier (Adobe Reader, a downstream archive, a court).
Run these additional checks before declaring local e-sealing production-ready.

### Adobe Reader (the canonical PDF verifier)

1. Open the signed PDF in **Adobe Acrobat Reader DC**.
2. Open the **Signature Panel** (left sidebar - pen icon, or
   `View → Show/Hide → Navigation Panes → Signatures`).
3. Expand the signature entry. You should see one of three outcomes:

   - ✅ **"Signed and all signatures are valid"** - green check.
     Acrobat trusts your cert chain and the signature math.
   - ⚠ **"At least one signature has problems"** - usually means
     "valid but the signer's identity is unknown / not trusted by
     Acrobat's trust store". This is the expected state for the shipped
     **demo cert** and for any signature whose chain doesn't reach a
     publicly-trusted root. Click *Signature Properties → Show Signer's
     Certificate → Trust* to see the chain. Cryptographically valid, just
     not anchored in Adobe's default trust store.
   - ❌ **"At least one signature is invalid"** - bad. The signed
     hash doesn't match, or the cert was revoked, or the trust chain is
     broken in a way verifier flagged as fatal. Compare the cert subject
     in the panel against what
     `/api/signing/certificate/for/<company>` returns; if they differ,
     something else is signing the PDF.

### CLI: `pdfsig` (Poppler)

`pdfsig` (from the Poppler tools) is the quickest CLI check. Most
distros package it as `poppler-utils` (Debian/Ubuntu) or `poppler`
(macOS Homebrew).

```bash
pdfsig sealed.pdf
# Expect output similar to:
#   Digital Signature Info of: sealed.pdf
#   Signature #1:
#     - Signer Certificate Common Name: <your cert CN>
#     - Signer full Distinguished Name: <your cert subject DN>
#     - Signing Time: <date>
#     - Signing Hash Algorithm: SHA-256
#     - Signature Type: adbe.pkcs7.detached
#     - Signed Ranges: [0 - 271790], [290736 - 290736]
#     - Total document signed: yes
#     - Signature Validation: Signature is Valid.
#     - Certificate Validation: ...
```

The last two lines are the meaningful ones:

- **Signature Validation: Signature is Valid** - cryptographic integrity is
  good. Anything else (Invalid, Decoding Error) means the signed hash
  doesn't reconcile with the embedded signature.
- **Certificate Validation** - `Certificate is Trusted` if your CA is in
  the local trust store, `Certificate issuer isn't Trusted` for the demo
  cert and for any private-CA scenario. Trust is a property of the
  verifier's trust store, not of the signature itself.

### Detached / programmatic verification

For automated downstream verifiers (an internal "I will only accept
signatures I issued" service, for example), use digidoc4j's CLI or the
DSS demo tool. Both consume a PDF and emit a structured validation
report (XML or JSON). That output is what your downstream automation
should make trust decisions on; do not parse `pdfsig` text output.

### What "good" looks like for the demo cert

The shipped demo cert is self-signed, so Adobe Reader and `pdfsig` will
both report "signature valid, certificate not trusted". That outcome is
expected - the seal itself is cryptographically sound, but no verifier
trusts an arbitrary self-signed CA. To get to "valid + trusted":

- Replace the demo cert with a CA-issued one
  ([Production setup](#46-production-setup-deploying-with-your-own-key-and-certificate)).
- Use an LT (or higher) profile and wire up TSA + OCSP
  ([Wiring TSA and OCSP](#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)).
- Confirm your CA's root certificate is in the verifier's trust store.

  *Adobe Reader (per-user import):*
  1. Export your CA's root certificate to a `.cer` file (your CA's
     download page will offer it).
  2. In Adobe Acrobat Reader DC: `Edit → Preferences → Signatures →
     Identities & Trusted Certificates → More` → `Trusted Certificates`
     → `Import`.
  3. Browse to the `.cer` file, select it, click `Import`.
  4. In the next dialog tick `Use this certificate as a trusted root`
     and (if you want) `Certified documents` and `Dynamic content`.
     Click `OK`.
  5. Re-open the signed PDF - the Signature Panel should now show
     the green check.

  *System-wide trust (so every PDF tool picks it up, not just Adobe):*
  on Windows, add to the Trusted Root Certification Authorities store
  via `certmgr.msc`; on macOS, drop into Keychain Access and mark
  "Always Trust"; on Debian/Ubuntu, copy to `/usr/local/share/ca-certificates/`
  and run `sudo update-ca-certificates`. The exact mechanism is OS-side,
  not part of this stack.

  *Internal CA case:* if you signed with a cert from your own internal
  CA, the only verifiers who will ever return "trusted" are ones whose
  trust stores you control. End-user Adobe Reader on a stranger's
  machine will always show "valid but untrusted" for internal-CA
  signatures - that's expected, not a stack defect.

