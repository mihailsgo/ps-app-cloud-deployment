# 4.2 Architecture deep-dive

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

## How a request resolves end-to-end

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

