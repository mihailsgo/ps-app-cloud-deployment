# Demo seal certificate

> **Type:** how-to  -  **Audience:** operator, developer
> **Last verified:** 2026-09-27 against main d553db4

What the shipped demo keystore is, how to replace it with a real certificate
and check that the stamping service serves it, and how the demo file was
generated. It does not cover turning local e-sealing on or off (`STAMP_MODE`,
the `local-eseal` compose profile) or the full production setup; see
`documentation/04-enabling-local-e-sealing.md` and
`documentation/04-06-production-setup-deploying-with-your-own-key-and-certificate.md`
in the deployment repo.

**This is a DEMO self-signed certificate. Do NOT use it for production signatures.**

The `seal.p12` PKCS12 keystore in this folder is shipped so that local e-sealing
works out of the box once it is enabled (`--enable-local-eseal` in the
deployment scripts, or `COMPOSE_PROFILES=local-eseal` locally). It contains
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
5. Start it back up: `docker compose --profile local-eseal up -d dmss-digital-stamping-service`
6. Verify, as below.

### Verifying the served certificate

The stamping service has no host port by design (it would collide with a
USB-token signer on host port 8084), and its image has no `curl`, so query it
from `dmss-container-and-signature-services`, which reaches it over the
Docker network and does have `curl`. The service returns the certificate as
hex-encoded DER in the `cert` field. Run from the directory that holds
`docker-compose.yml`; the host needs `python3` and `openssl`:

```bash
docker compose exec -T dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

Replace `TrustLynx` with the company name from `../application.yml` if you
changed it. The printed subject must match your new certificate. If it still
shows `CN=Trustlynx Local Seal Demo`, the swap did not take effect: check the
file path and that the container actually restarted.

Then sign a document with local mode enabled and check ps-server's log:

```bash
docker compose logs ps-server | grep -E '\[stamp\] mode=local|Stamp response status|continuing without stamp'
```

A working seal shows `[stamp] mode=local url=...` followed by
`Stamp response status: 200`. A `[stamp] upstream unavailable, continuing
without stamp` line means the seal failed with a 5xx and the document was
left unsealed. The signing UI still completes in that case, so the log is
the place to check.

## Requirements for real signatures

Real signatures generally also require:

- A trusted CA chain (the B_BES profile works as-is; LT / LTA / PAdES_BASELINE_LT
  profiles need timestamping and OCSP - wire those in via
  `container-signature-service`'s digidoc4j config, not here).
- Coordination with the appropriate `documentsigningprofiles.json` entry in
  `../../dmss-container-and-signature-services/` so the profile name's
  `esealCompany` resolves to a company defined in `../application.yml`.

## How the shipped seal.p12 was generated

You do not need to regenerate it. If the demo keystore expires (after
2028-08-13) or you want a fresh demo identity, this is the recipe that
produced the shipped file:

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

Production keystores follow a similar shape, but the key + cert come from a
real CA rather than `openssl req -x509`. See
`documentation/04-06-production-setup-deploying-with-your-own-key-and-certificate.md`
in the deployment repo for the production recipes.
