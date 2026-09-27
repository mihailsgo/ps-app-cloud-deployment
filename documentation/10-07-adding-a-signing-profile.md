# 10.7 Adding a signing profile

This page adds a company and a profile of your own, next to the shipped demo.
With both in place, `LocalDemo` stays available as a known-good test while
production seals use your keystore and signature settings. The profile name
appears in the URL `ps-server` calls and in the logs.

A company and a profile have different jobs:

- The **profile name** is the `name` in `documentsigningprofiles.json` and the
  last part of the URL. It selects the signature level and the
  visible-signature settings.
- The **company name** is the profile's `esealCompany`, and the matching
  `stamping.companies[].name` in the stamping `application.yml`. It selects the
  keystore to sign with.

The two names can be the same. This page uses `ExampleCoSeal` for the profile
and `ExampleCo` for the company.

## Step 1: Put the keystore in place

Build the keystore as described in [10.6](10-06-production-key-and-certificate.md),
steps 1 and 2. Then copy it next to the demo keystore and restrict who can read
it, as in 10.6 Step 3:

```bash
cd /opt/padsign
cp /path/to/production.p12 dmss-digital-stamping-service/seal/exampleco.p12
```

## Step 2: Add the company

In `dmss-digital-stamping-service/application.yml`, add an entry under
`stamping.companies`. Keep the `TrustLynx` entry, so the demo still works:

```yaml
stamping:
  companies:
    - name: "TrustLynx"              # demo, unchanged
      providers:
        - name: P12
          engine: P12
          keystore: file:/seal/seal.p12
          password: changeit
          alias: seal

    - name: "ExampleCo"              # new
      providers:
        - name: P12
          engine: P12
          keystore: file:/seal/exampleco.p12
          password: <keystore password>
          alias: seal                # the alias inside exampleco.p12
```

## Step 3: Add the profile

In `dmss-container-and-signature-services/documentsigningprofiles.json`, add
an object to the array. Keep the existing entries.

```json
{
  "name": "ExampleCoSeal",
  "esealCompany": "ExampleCo",
  "pdfSigningSigner": {
    "pdfSignatureIsVisible": true,
    "signatureProfile": "LT",
    "pdfSignatureVisuals": {
      "signatureText": "Sealed by {cn}\nAt date: {date}"
    }
  }
}
```

Settings you can change:

- `signatureProfile`: `B_BES`, `LT` or `LTA`. If you leave it out, the profile
  uses container-signature's default, `PAdES_BASELINE_LT`. `LT` and `LTA` need
  a TSA and OCSP, so set those up first
  ([10.8](10-08-tsa-and-ocsp-for-lt-and-lta.md)).
- `pdfSignatureIsVisible`: `true` draws a visible seal box on the page.
  `false` adds an invisible seal, which is how `LocalDemo` is set.
- `pdfSignatureVisuals.signatureText`: the text in the seal box. `{cn}` becomes
  the certificate's CN, and `{date}` the time of sealing.
- `pdfSignatureVisuals.signatureImage`: a base64-encoded PNG to show in the
  seal box. The shipped `TrustLynx` profile has an example.
- `esealAsContainer`: `true` produces an ASiC-E container instead of a sealed
  PDF. Leave it out for PDFs.

Check the JSON before restarting. A single syntax error breaks every profile
in the file:

```bash
python3 -m json.tool dmss-container-and-signature-services/documentsigningprofiles.json >/dev/null && echo "JSON OK"
```

## Step 4: Point ps-server at the profile

In `config/config.js`, end `STAMP_LOCAL.url` with the new profile name. Also
use the rotated Spring Security password
([10.6 Step 5](10-06-production-key-and-certificate.md#step-5-rotate-the-demo-passwords)):

```js
STAMP_LOCAL: {
  url: "http://dmss-container-and-signature-services:8092/api/eseal/document/profile/ExampleCoSeal",
  username: "user",
  password: "<Spring Security password>",
  timeoutMs: 30000
},
```

## Step 5: Restart the three services

```bash
docker compose restart dmss-digital-stamping-service dmss-container-and-signature-services ps-server
docker compose ps       # wait until all three show (healthy)
```

After a restart, the stamping service reads its keystores again,
container-signature reads the profile file again, and `ps-server` reads
`config.js` again.

## Step 6: Test the profile

The stamping service should now return your certificate for `ExampleCo`:

```bash
docker compose exec -T dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/ExampleCo \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer
```

Next, seal a sample PDF directly through container-signature. Port 84 is bound
to `127.0.0.1`, so run this on the deployment host itself, or through
`ssh -L 84:localhost:84 <host>`:

```bash
curl -sS -u user:'<Spring Security password>' -X POST \
    -F "file=@/path/to/sample.pdf;type=application/pdf" \
    -o /tmp/sealed.pdf -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/ExampleCoSeal
grep -aoE '/Type\s*/Sig|/ByteRange\s*\[[^]]+\]' /tmp/sealed.pdf
```

Finally, sign a document in the portal. Download its sealed version from the
archive, which is bound to `127.0.0.1:86`:

```bash
docker compose logs --tail 200 ps-server | grep -E '\[stamp\] mode=|Stamp response status'
# expect: [stamp] mode=local url=.../profile/ExampleCoSeal   and   Stamp response status: 200
curl -fsS "http://localhost:86/api/document/<docid>/download" -o /tmp/portal-sealed.pdf
```

Then check the signature with an external verifier
([10.10](10-10-verifying-signatures-end-to-end.md)).

## More than one company

Repeat these steps for each extra company: add a keystore in `seal/`, an entry
in `application.yml` and a profile in the JSON. `ps-server` always seals with
the one profile named in `STAMP_LOCAL.url`. To choose a profile per flow or per
customer, contact TrustLynx support.
