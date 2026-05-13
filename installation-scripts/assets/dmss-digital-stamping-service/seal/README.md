# Demo seal certificate

**This is a DEMO self-signed certificate. Do NOT use for production signatures.**

The `seal.p12` PKCS12 keystore in this folder is shipped so that local e-sealing
works out of the box right after `--enable-local-eseal` deployment. It contains
an RSA-2048 self-signed certificate:

| Property      | Value                                                            |
| ------------- | ---------------------------------------------------------------- |
| Subject       | `CN=Trustlynx Local Seal Demo, OU=Digital Mind Stamping Service, O=Trustlynx, C=LV` |
| Issuer        | (self-signed, same as subject)                                   |
| Validity      | until 2028-08-13                                                 |
| Key algorithm | RSA, 2048-bit                                                    |
| Alias         | `seal`                                                           |
| Password      | `changeit`                                                       |
| Key usage     | digitalSignature, nonRepudiation                                 |

## Replacing with a real certificate

1. Produce a PKCS12 keystore containing your real key + cert chain. The alias
   inside the keystore should be `seal` (or update `alias:` in
   `../application.yml` to match).
2. Stop the stamping service: `docker compose stop dmss-digital-stamping-service`
3. Replace `seal.p12` with your file.
4. If the password differs from `changeit`, update `password:` in
   `../application.yml`.
5. Start it back up: `docker compose up -d dmss-digital-stamping-service`
6. Verify: `curl -fsS http://localhost:8084/api/signing/certificate/for/TrustLynx`
   should return a `cert` field whose decoded subject matches your new cert.

Real signatures generally also require:

- A trusted CA chain (B_BES profile works as-is; LT / LTA / PAdES_BASELINE_LT
  profiles need timestamping and OCSP — wire those in via
  `container-signature-service`'s digidoc4j config, not here).
- Coordination with the appropriate `documentsigningprofiles.json` entry in
  `../../dmss-container-and-signature-services/` so the profile name's
  `esealCompany` resolves to a company defined in `../application.yml`.

## How the shipped seal.p12 was generated

This is purely informational — you do NOT need to regenerate. But if
your demo keystore expires (after 2028-08-13) or you want a fresh demo
identity for a different evaluation purpose, here's the exact recipe
that produced the shipped file:

```bash
# 1. Generate a self-signed RSA-2048 cert + matching unencrypted PEM key.
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout seal_key.pem \
    -out    seal_cert.pem \
    -subj '/C=LV/O=Trustlynx/OU=Digital Mind Stamping Service/CN=Trustlynx Local Seal Demo' \
    -addext 'keyUsage=critical,digitalSignature,nonRepudiation' \
    -addext 'extendedKeyUsage=clientAuth,emailProtection'

# 2. Bundle into a PKCS12 keystore with alias 'seal' and password 'changeit'.
openssl pkcs12 -export \
    -in    seal_cert.pem \
    -inkey seal_key.pem \
    -name  seal \
    -passout pass:changeit \
    -out   seal.p12

# 3. Sanity-check.
keytool -list -keystore seal.p12 -storepass changeit
# Expect: 1 entry, name 'seal', PrivateKeyEntry.

# 4. (Optional) Discard the intermediate PEM files. They are not needed
# at runtime; only seal.p12 is bind-mounted into the stamping container.
rm seal_key.pem seal_cert.pem
```

Production keystores follow a similar shape, but the key + cert come
from a real CA rather than `openssl req -x509`. See the deployment
guide's "Production setup: deploying with your own key and certificate"
section for the production recipes.
