# 4.4 Existing deployment (upgrade an already-deployed instance)

This is the section to follow if your PadSign deployment is currently
running on a repo version from **before** this feature was added (any
version where `installation-scripts/upgrade.sh` does **not** have the
`--enable-local-eseal` flag, and `config/config.js` does **not** have
`STAMP_MODE` / `STAMP_LOCAL` fields). It walks you through, in order:

- enabling local e-sealing with the **demo cert** that ships in the repo,
- verifying the demo signing works end to end,
- replacing the demo cert with your **own production key + certificate**
  and verifying that too.

The flow is non-destructive: external mode keeps working until you
explicitly switch `STAMP_MODE` to `"local"`. Every step is reversible
either via the `*.bak` files the script creates or with a small config
edit.

### Prerequisite: ps-server image version

Local e-sealing is implemented in the ps-server source (the
`STAMP_STRATEGIES` dispatch table inside `/api/stamp`). **The ps-server
image must be `mihailsgordijenko/ps-server:3.26` or newer.** Earlier
tags (`:3.25` and below) silently ignore the `STAMP_MODE` config field
and always call the external cloud e-sealing service - meaning local
mode appears to be installed (the stamping container starts, configs
look right) but signing still goes to the cloud.

How to check what your deployment is running:

```bash
grep mihailsgordijenko/ps-server docker-compose.yml
# Expect: image: 'mihailsgordijenko/ps-server:3.26'  (or newer)
```

If the tag is older than `3.26`, you must bump it *together with*
`--enable-local-eseal` so the upgrade script updates both in one
atomic step. The combined invocation looks like this (substitute the
newest published tag if there is one):

```bash
./installation-scripts/upgrade.sh --server-tag 3.26 --enable-local-eseal
```

ps-client (`mihailsgordijenko/ps-client:8.36`) is unchanged - the SPA
calls `/api/stamp` the same way in both modes, so no `--client-tag`
is needed for local e-sealing.

## Phase 1 - Update the deployment scripts and configs

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

## Phase 2 - Enable local e-sealing with the demo cert

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
pre-feature state, restore the two `.bak` files the script created
in Step 1:

```bash
cd /opt/psapp
cp docker-compose.yml.bak docker-compose.yml
cp config/config.js.bak  config/config.js
```

Then open `.env` and remove the `COMPOSE_PROFILES=local-eseal` line,
and bring the stack back up:

```bash
docker compose --profile local-eseal down dmss-digital-stamping-service
docker compose up -d
docker compose restart ps-server
```

The hard rollback works whether or not the upgrade finished.

## Phase 3 - Verify the demo signing flow

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
signatures are valid") only after Phase 4 with a real CA-issued cert.

## Phase 4 - Set up for production test with your real key and certificate

This phase replaces the demo cert with your own production signing
material and verifies signing still works end to end. It is a *test*
phase even when using the real cert - meaning you confirm signatures
verify correctly in a representative environment before going live.

How long this takes depends on whether you already have a signing
certificate or still need to request one from a public CA (which can
be days or weeks of CA SLA + organisational paperwork).

### Step 4.1 - Source your signing certificate

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

### Step 4.2 - Build a deployment-ready `seal.p12`

Follow [Production setup: deploying with your own key and certificate](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate)
to convert whatever your CA delivered into a PKCS12 keystore that the
stamping service can consume. Pick the recipe that matches your
artefact shape (separate files, existing .pfx, or alias rename).
Verify with `keytool -list -v` before continuing.

### Step 4.3 - Decide on a signature level

The shipped `LocalDemo` profile uses `B_BES` because the demo cert is
self-signed and no TSA will issue a timestamp for it. With a real
CA-issued cert you usually want a higher level.

Open [Step 4 of Production setup](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate) and use the table there to pick:

- **`B_BES`** if your cert is from an internal CA OR your verifiers
  don't need eIDAS legal validity.
- **`LT`** if your cert is from a publicly trusted CA AND you want
  long-term verifiability (most production use cases).
- **`LTA`** if you also need archival timestamps (long-retention
  scenarios).

If you pick anything other than `B_BES`, complete
[Wiring TSA and OCSP for LT and LTA signature profiles](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)
before continuing - your signing will fail without a TSA configured.

### Step 4.4 - Add a production-specific profile (recommended)

Don't modify the shipped `LocalDemo` profile - keep it intact as a known-good
fallback. Add a new profile (e.g. `AcmeProductionSeal`) following
[Adding a new signing profile end-to-end](04-07-adding-a-new-signing-profile-end-to-end.md#47-adding-a-new-signing-profile-end-to-end).
The 6 steps in that section walk through editing
`documentsigningprofiles.json`, adding a new company in
`dmss-digital-stamping-service/application.yml`, updating
`STAMP_LOCAL.url` in `config.js`, and restarting the right services.

### Step 4.5 - Rotate the three default credentials

Now is the right time to replace the three `changeit` defaults with
strong unique passwords:

1. **keystore password** - set during keystore creation (see
   [Production setup: deploying with your own key and certificate](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate)
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

### Step 4.6 - Smoke-test the production cert

Use the same three checks as Phase 3, but adapted for the production
profile:

```bash
# 5.6.1 - Cert endpoint serves your real cert. Replace <YourCompany>
#         with the company name you added in Step 4.4.
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
the demo cert (the swap didn't take effect - re-check Step 4.2 / 4.4).

```bash
# 5.6.2 - End-to-end sign through ps-server. Pick a test PDF.
#         Replace <ProductionProfile> with the profile name from Step 4.4.
curl -sS -u user:<your-new-spring-security-password> -X POST \
    -F "file=@/path/to/test.pdf;type=application/pdf" \
    -o /tmp/prod-test.pdf \
    -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/<ProductionProfile>

# Verify the output is a signed PDF:
grep -aoE '/Type\s*/Sig|/Filter\s*/Adobe\.PPKLite|/ByteRange' /tmp/prod-test.pdf
```

**Step 4.6.3 - Sign through the actual SPA flow.** This is what real
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

### Step 4.7 - Verify the signature externally (the real test)

The smoke tests above prove the *stack* produces a signature. The real
question for a production cert is whether a *verifier* trusts it.

Run the full procedure in
[Verifying signatures end-to-end (beyond the stack)](04-10-verifying-signatures-end-to-end-beyond-the-stack.md#410-verifying-signatures-end-to-end-beyond-the-stack):

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
[Wiring TSA and OCSP for LT and LTA signature profiles](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles));
or the cert's `keyUsage` is missing `digitalSignature` /
`nonRepudiation` (re-issue with the correct key usage).
