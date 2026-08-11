# 4.8 Wiring TSA and OCSP for LT and LTA signature profiles

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

## Picking a TSA

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

## Configuring the TSA in `application.yml`

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

## Configuring OCSP and the trust list

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

## PROD vs TEST digidoc4j mode

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

