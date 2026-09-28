# 10.8 TSA and OCSP for LT and LTA

This page connects the timestamp and revocation services that `LT` and `LTA`
profiles need. A `B_BES` seal needs neither, so skip this page if you only use
`B_BES`.

A `B_BES` seal is self-contained: the digest is signed with your key and put
into the PDF. `LT` and `LTA` put more evidence into the signature:

1. A **timestamp** from a TSA, which proves when the seal was made.
2. **OCSP responses** for the certificates in your chain, which prove that
   none had been revoked at that moment.
3. For `LTA` only, an **archival timestamp**, so the seal can still be checked
   after its algorithms become outdated.

Container-signature must therefore reach a TSA and the OCSP responders at the
moment it seals. If it cannot, the seal fails, and `ps-server` logs `[stamp]
upstream unavailable, continuing without stamp`. The document is then left
unsealed (see [10.2](10-02-architecture.md#what-happens-when-a-link-breaks)).
Allow outbound HTTP/HTTPS from the host to these services
([2.3 Network and firewall](02-03-network-and-firewall.md)).

## Choosing a TSA

Use the TSA that your CA, your jurisdiction or your contract requires. For
example:

| TSA | Notes |
|---|---|
| `http://tsa.sk.ee` | SK ID Solutions (EE), qualified. This is the shipped default. |
| `http://demo.sk.ee/tsa` | SK test service. Not for production. |
| `https://tsa-com.eparaksts.lv/` | eParaksts (LV), qualified. Uses Basic authentication; there is a commented example in `application.yml`. |
| Your own TSA | Typical for an internal-CA setup |

Check the exact URL and the terms of use with the provider. A seal counts as
eIDAS-*qualified* only if the TSA is also on an EU trusted list. With an
internal CA you normally also need an internal TSA.

## Setting the TSA

The TSA is set under `timestamp.timestampProviders` in
`dmss-container-and-signature-services/application.yml`. The shipped file has
one active entry and a commented example with authentication:

```yaml
timestamp:
  timestampProviders:
    -
      tspSource:  http://tsa.sk.ee
    #-
    #  tspSource: https://tsa-com.eparaksts.lv/
    #  authentications:
    #    - protocol: https
    #      host: tsa-com.eparaksts.lv
    #      port: 443
    #      scheme: Basic
    #      realm: KeyOneSystem
    #      username: username
    #      password: password
```

Change the list, then restart container-signature. Wait until it shows
`(healthy)` again:

```bash
docker compose restart dmss-container-and-signature-services
```

Check that the TSA can be reached from inside the container:

```bash
docker compose exec -T dmss-container-and-signature-services \
    curl -sS -o /dev/null -w "HTTP=%{http_code}\n" -X POST \
    -H "Content-Type: application/timestamp-query" --data-binary '' http://tsa.sk.ee
```

Any HTTP status means the TSA answered. An empty request is expected to get an
error status. `Could not resolve host` or `Connection refused` means DNS or the
firewall is blocking it. If outbound traffic has to go through a proxy, the
commented `http:` `proxyhost`/`proxyport` block in the same `application.yml`
is the place to start. Contact TrustLynx support if you need help with a proxy
setup.

## OCSP and the trusted list

Most certificates carry their OCSP responder's URL in the Authority
Information Access (AIA) extension. With `digidoc4j.configuration.preferAiaOcsp:
true`, which is the shipped setting, that URL is used, so you normally need to
configure nothing.

For a private CA whose certificates have no AIA, or for a custom trusted list,
set these keys in `dmss-container-and-signature-services/digidoc4j-custom.yaml`.
The shipped file has them all commented out:

```yaml
TSL_LOCATION: "https://tsl.example.com/your-tsl.xml"      # trusted list to use instead of the EU list of lists
OCSP_SOURCE: "http://ocsp.example.com/"                   # OCSP responder when the certificate has no AIA
SSL_TRUSTSTORE_PATH: "file:/confs/ssl_tsl_truststore.p12" # truststore for HTTPS to the TSL/TSA/OCSP
SSL_TRUSTSTORE_TYPE: "PKCS12"
SSL_TRUSTSTORE_PASSWORD: "<truststore password>"
TRUSTED_TERRITORIES: "EE, LV"                             # only accept these countries' trusted lists
```

Container-signature reads the file only at start-up, so restart it after every
change.

## PROD and TEST mode

`digidoc4j.configuration.mode` in `application.yml` is `PROD` in the shipped
file. In `PROD` mode, the library trusts only chains rooted in the EU trusted
lists. `TEST` mode also accepts test CAs and test trusted lists. It is meant
for trying things out, for example with a test CA. Never seal real documents in
`TEST` mode.
