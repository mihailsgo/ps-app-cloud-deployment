# 4.7 Adding a new signing profile end-to-end

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

## Step 1 - Stage the new keystore

Follow [Production setup](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate)
to produce your `.p12` keystore. Drop it next to the demo one with a
descriptive filename (so you can tell the two apart):

```bash
cp /path/to/seal.p12 dmss-digital-stamping-service/seal/acme-prod.p12
chmod 600 dmss-digital-stamping-service/seal/acme-prod.p12
```

## Step 2 - Add a company in the stamping service config

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

## Step 3 - Add a profile in the container-signature config

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
  [Wiring TSA and OCSP](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)
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

## Step 4 - Point ps-server at the new profile

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

## Step 5 - Restart the affected services

```bash
# Stamping reloads its keystore on restart; container-signature reloads the
# profile JSON; ps-server reloads config.js. nginx and archive stay running.
docker compose restart \
    dmss-digital-stamping-service \
    dmss-container-and-signature-services \
    ps-server
```

## Step 6 - Smoke test the new profile

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

## Running multiple companies at once

This pattern scales to as many companies/profiles as you need. Each new
keystore goes in `dmss-digital-stamping-service/seal/`, each new company
gets an entry in `application.yml`, each new profile gets an entry in the
JSON. The URL path segment chooses which profile is used per request, so
`ps-server` can call any of them depending on what flow triggered the
seal - though out of the box `ps-server` always uses the one profile
named in `STAMP_LOCAL.url`. Wiring per-flow profile selection is custom
work outside the scope of this guide.

---

