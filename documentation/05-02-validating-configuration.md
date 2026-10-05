# 5.2 Validating configuration

`installation-scripts/validate-config.sh` checks every configuration file of the deployment for
syntax, consistency with your hostname, leftover demo secrets, file permissions, port exposure and
image pinning. It changes nothing, so you can run it at any time: after the install, after every
configuration change and after every upgrade.

```bash
cd /opt/padsign
./installation-scripts/validate-config.sh --host padsign.example.com
```

`--host` is optional, but without it the hostname consistency checks are skipped. Run it as your
operator account (or root): it has to read `config/config.js`, and it warns first if it cannot.

Each line starts with `OK`, `WARN` or `FAIL`. The script ends with `All checks passed.` and exit code
`0`, or `Some checks FAILED. Review above.` and exit code `1`. Warnings do not fail the run, but read
them: most point at something to fix before production, and each one says how.

The Deployment Wizard runs the same checks on its **Verify** step and on its dashboard.

## What it checks

The sections appear in this order.

**File checks.** `config/config.js`, `config/constants.json`, `nginx/nginx.conf` and
`docker-compose.yml` exist.

**Syntax checks.** `constants.json` is valid JSON, and `docker compose config` accepts the compose
model.

**Feature checks.**

- `DOCUMENT_ROUTING` is present in `config.js` and the `signed-output` mount is in `docker-compose.yml`.
- `signed-output/` and `docs/` exist, everything in them is owned by the uid their container image
  runs as, and neither is world-writable. A FAIL prints the exact `chown`/`chmod` to run. The
  directories checked are the sources of the `/signed-output` and `/docs` mounts in the rendered
  compose model, which are `./signed-output` and `./docs` unless an overlay or override mounts them
  elsewhere. A store the check cannot look at (a named volume, a path the user cannot read, a path
  outside the wizard container) is reported as `INFO`, not `FAIL`
  ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md#storage-outside-the-checkout)).

**Secret hygiene.** It never prints a secret value, only field names and states.

| Check | Result |
|---|---|
| `API_PROTECT_LOGS_ENABLED` is true (ps-server would log raw bearer tokens) | FAIL |
| A `config.js` credential still holds the value shipped in this public repository, or the `CHANGE_ME` placeholder: `REGISTER_PDF_API_KEY`, the Keycloak backend client secret, `STAMP_API_KEY`, `STAMP_COMPANY_ID`, `STAMP_COMPANY_SECRET` | WARN, with the fix. The three `STAMP_*` fields are OK while `STAMP_MODE` is `"local"`, which does not use them. |
| The visual-PDF signing CA (`dmss-container-and-signature-services/dmssrootca.p12`) is the demo CA shipped in the repository | WARN: run `configure-host.sh --host <host> --generate-ca`, then restart `dmss-container-and-signature-services`. The installer generates one per deployment |
| That CA keystore is missing or does not open with the password in its `application.yml` | FAIL |
| `dmss-archive-services` has JWT checking enabled with the shipped secret | FAIL |
| The Keycloak admin password is written inline in `docker-compose.yml`, or falls back to the default `admin` because `.env` does not set `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD` | WARN |
| ps-server's image cannot read `config/config.js` | FAIL, with the exact `chgrp`/`chmod` |
| `config/config.js` or `.env` is world-readable | WARN |
| A TLS key in `nginx/certs/` is world-readable | FAIL |
| The nginx redirect from `/` to `/portal/` is missing | FAIL |

**Port bindings.** Only `nginx` may publish a port on all interfaces. The `wizard` binds to
`127.0.0.1` by default; when `WIZARD_BIND_ADDRESS` in `.env` publishes it on a non-loopback address,
that is a WARN, because it holds the Docker socket and Docker-published ports bypass host firewalls
([3.1](03-01-starting-the-wizard.md#reaching-the-wizard-without-a-tunnel-wizard_bind_address)). Any
other service published on a non-loopback address is a FAIL
([2.3 Network and firewall](02-03-network-and-firewall.md)).

**Hostname consistency** (with `--host`). These must all name your host: `server_name` in
`nginx/nginx.conf`, `KEYCLOAK_URL` in `constants.json`, `auth-server-url` in `config.js`, and
`KC_HOSTNAME` of the `keycloak` service in `docker-compose.yml`. `constants.json` may leave out
`KEYCLOAK_URL`, `KEYCLOAK_REDIRECT_URI` and `KEYCLOAK_POST_LOGOUT_REDIRECT_URI`: that is OK when the
ps-client in `docker-compose.yml` defaults them to its own origin (the `client-origin-defaults`
capability, [7.3](07-03-client-constants-json.md#authentication-keycloak)) and a FAIL when it does
not; a redirect URI that names another host is a WARN. A different `KC_HOSTNAME` is a FAIL:
Keycloak uses it for the login page's URLs and as the token issuer. A WARN if the `nginx` service's
network alias does not include the host. The fix for both is to rewrite the files, then recreate
the two containers (a plain `restart` keeps the old `KC_HOSTNAME` and alias):

```bash
./installation-scripts/configure-host.sh --host <host>
docker compose up -d keycloak nginx
```

See [9.1 Changing hostname](09-01-changing-hostname.md).

**DMSS service addresses.** The five addresses ps-server uses for the archive and container-signature
services in `config.js` ([7.4](07-04-server-config-js.md#how-ps-server-reaches-the-dmss-services)) may
be in-network (`http://dmss-archive-services:8090/api/...`, the shipped form) or public
(`https://<host>/archive/api/...`); both are OK. The check reports which form the host uses and what
that means for the nginx routes ([6.1](06-01-route-protection.md)).

| Check | Result |
|---|---|
| A key holds the other service's address (an archive key pointing at the container service) | FAIL |
| A public address names a host other than `--host` (or the host `nginx.conf` serves) | FAIL |
| In-network and public addresses are mixed | WARN: closing an nginx route breaks the public ones |
| A key holds an address of your own, or is missing | WARN, not checked further |
| `ARCHIVE_PUBLIC_BASE_URL` names another host | WARN: webhook receivers are sent there |
| A webhook strategy is enabled, the addresses are in-network, and `ARCHIVE_PUBLIC_BASE_URL` is missing, or the ps-server tag is older than the `dmss-internal-urls` capability | WARN: payloads carry an in-network `archiveUrl` |

**Image tags.** Prints the ps-server and ps-client tags in `docker-compose.yml`. A FAIL if they differ
from the release in `release/approved-digests.json` ([14.3 Release snapshot](14-03-release-snapshot.md)),
a WARN instead for a version `rollback.sh` restored ([9.8 Rollback](09-08-rollback.md)).

**Image digest pinning.** Every image in the effective compose model (including profile-gated
services and any compose override) must be pinned as `tag@sha256:digest` with exactly the tag and
digest approved in `release/approved-digests.json`, and every approved image must be present.
Anything else is a FAIL.

**Image signatures (cosign).** See [below](#image-signatures).

**Container checks** (when Docker is reachable). The running ps-server and ps-client containers use
the tags in `docker-compose.yml`.

## Image signatures

The ps-server and ps-client images are signed by TrustLynx. `validate-config.sh` verifies the pinned
digest's signature and its signed SBOM and build-provenance attestations against the public key in
`release/cosign.pub`. This needs [cosign](https://github.com/sigstore/cosign) v3 or newer on the host
and access to Docker Hub.

| Situation | Result |
|---|---|
| Signature and both attestations verify | OK |
| Signature or attestation missing, wrong key, or registry unreachable | FAIL |
| cosign not installed, or older than v3 | WARN (FAIL when `PADSIGN_REQUIRE_SIGNATURES=1`) |
| One of the two releases from before signing, listed by digest in `release/unsigned-legacy-images.json` | WARN, exempt |

To install cosign on an amd64 host:

```bash
v=v3.1.3
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${v}/cosign-linux-amd64"
curl -fsSLO "https://github.com/sigstore/cosign/releases/download/${v}/cosign_checksums.txt"
grep ' cosign-linux-amd64$' cosign_checksums.txt | sha256sum -c -
sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

Once it is installed, set `PADSIGN_REQUIRE_SIGNATURES=1` in the environment you run the scripts from
(for example your shell profile), so that removing cosign later cannot silently turn the check into a
warning. `upgrade.sh` runs the same check on the tags you upgrade to and refuses an upgrade whose
signature does not verify.

To check one image by hand:

```bash
ref=mihailsgordijenko/ps-server@sha256:<digest>
cosign verify --key release/cosign.pub --insecure-ignore-tlog=true "$ref"
cosign verify-attestation --key release/cosign.pub --insecure-ignore-tlog=true --type spdxjson "$ref"
cosign verify-attestation --key release/cosign.pub --insecure-ignore-tlog=true --type slsaprovenance1 "$ref"
```

The signatures are not recorded in a public transparency log, which is why `--insecure-ignore-tlog=true`
is passed; the key in `release/cosign.pub` is the trust anchor.

## Browser checks

Two quick checks from any browser:

- `https://<host>/portal/` redirects to the Keycloak login page.
- `https://<host>/auth/admin/` shows the Keycloak admin login.

For the live, over-the-network checks, continue with [5.3 Post-deploy checks](05-03-post-deploy-checks.md).
