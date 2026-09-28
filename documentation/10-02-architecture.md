# 10.2 Architecture

This page shows how a seal request moves through the stack in each mode, and
which configuration value each step reads. Use it to find where a failing seal
breaks.

In both modes the flow starts in the portal. After the signer signs, and only
if `RUN_STAMPING_REQUEST` is `true` in `config/constants.json`, the portal
calls `ps-server`'s `/api/stamp`. `ps-server` downloads the latest version of
the document from the archive and sends it to the e-sealer that `STAMP_MODE`
selects. It then stores the sealed PDF as a new archive version and runs
document routing, if you have enabled it.

## External mode

The stamping container does not run.

```
portal ──HTTPS──▶ nginx:443 ──▶ ps-server /api/stamp
                                   │  POST multipart {file}
                                   │  X-API-KEY / X-COMPANY-ID / X-COMPANY-SECRET
                                   ▼
                          STAMP_API_URL (cloud e-sealing service)
                                   │  sealed PDF
                                   ▼
                  ps-server ──▶ dmss-archive-services (new version) ──▶ DOCUMENT_ROUTING (optional)
```

## Local mode

The cloud call is replaced by two containers inside the stack.

```
portal ──HTTPS──▶ nginx:443 ──▶ ps-server /api/stamp
                                   │  POST multipart {file}
                                   │  Authorization: Basic STAMP_LOCAL.username:password
                                   ▼
        dmss-container-and-signature-services:8092 /api/eseal/document/profile/<P>
                                   │  (Docker network)
                                   ▼
        dmss-digital-stamping-service:8084
            GET  /api/signing/certificate/for/<C>   → certificate (hex)
            POST /api/sign/digest/as/<C>            → signature (hex)
                                   │
                                   ▼
        /seal/*.p12  (bind-mounted read-only from ./dmss-digital-stamping-service/seal/)

container-signature puts the signature into the PDF and returns it to ps-server,
which archives and routes it exactly as in external mode.
```

`<P>` is the last part of `STAMP_LOCAL.url`. It must be the `name` of a profile
in `dmss-container-and-signature-services/documentsigningprofiles.json`. `<C>`
is that profile's `esealCompany`. It must match a `name` under
`stamping.companies` in `dmss-digital-stamping-service/application.yml`. The
shipped pair is `<P>` = `LocalDemo` and `<C>` = `TrustLynx`.

Ports:

- Container-signature listens on 8092 inside the Docker network. It is also
  published on the host as `127.0.0.1:84`, for diagnostics run on the host.
- nginx also proxies container-signature's API publicly at `/container/api/`.
  The Spring Security user that `ps-server` authenticates as protects it, so
  rotate that password (see [10.6](10-06-production-key-and-certificate.md))
  or restrict the route (see [6.1 Route protection](06-01-route-protection.md)).
- The stamping service listens on 8084 inside the Docker network only. It has
  no host port on purpose, so it cannot clash with a USB-token signer already
  running on host port 8084.

## How a local request resolves

For a request to
`http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo`:

1. Container-signature finds `LocalDemo` in `documentsigningprofiles.json`:
   ```json
   { "name": "LocalDemo", "esealCompany": "TrustLynx",
     "pdfSigningSigner": { "pdfSignatureIsVisible": false, "signatureProfile": "B_BES" } }
   ```
2. It reads `digital-stamping-service.baseUrl` from its `application.yml`. The
   shipped value is `http://host.docker.internal:8084/api`, a signer on the
   Docker host. Enabling local e-sealing changes it to
   `http://dmss-digital-stamping-service:8084/api`.
3. It calls `GET …/signing/certificate/for/TrustLynx` on the stamping service.
4. The stamping service finds `TrustLynx` under `stamping.companies`:
   ```yaml
   - name: "TrustLynx"
     providers:
       - name: P12
         engine: P12
         keystore: file:/seal/seal.p12
         password: changeit
         alias: seal
   ```
5. It opens `/seal/seal.p12` with that password and returns the certificate
   stored under the alias `seal`.
6. Container-signature prepares the PDF's signature field, computes the
   digest, and calls `POST …/sign/digest/as/TrustLynx`.
7. The stamping service signs the digest with the private key from the same
   entry.
8. Container-signature puts the signature into the PDF and returns the sealed
   PDF to `ps-server`.

Only `LocalDemo` works with the demo keystore out of the box. The other shipped
profiles (`TrustLynx`, `TrustLynxLV`, `TrustLynxLV_ASICE`) have no
`signatureProfile`, so they use the default `LT` level, which needs a TSA and
OCSP. The two `TrustLynxLV` profiles also name a company that the stamping
configuration does not define.

## What happens when a link breaks

Any of these makes container-signature return a 5xx error:

- a profile name that is not in the JSON
- an `esealCompany` that the stamping configuration does not define
- an alias that is not in the keystore
- a keystore password that does not match

`ps-server` tries the call up to three times, then logs `[stamp] upstream
unavailable, continuing without stamp` and answers the portal with `200 {
stampStatus: "skipped" }`. The portal treats a skipped seal as a failed
signing: it marks the seal step as failed, shows *Error in stamping service
response*, and reports a signing error to ps-server. The visually signed
document stays in the archive, but **it is not sealed**. Only enabled webhook
strategies run, with a `document.signing_error` event; filesystem routing
does not ([11](11-document-routing-and-receive-back.md#when-routing-runs)).

If seal calls keep failing, `ps-server`'s circuit breaker opens. Stamp requests
then fail at once with `503 STAMP_CIRCUIT_OPEN` until the breaker closes again.
The portal shows the same error, with `(HTTP 503)`.

Each call to container-signature has a 30-second timeout. Change it with
`STAMP_LOCAL.timeoutMs`.

To find the cause, read the logs of the two DMSS containers:

```bash
docker compose logs --tail 200 dmss-container-and-signature-services
docker compose logs --tail 200 dmss-digital-stamping-service
```
