# 10.6 Production key and certificate

This page replaces the demo keystore with your own signing key and
certificate, and rotates the demo passwords. It is the full procedure. The
short note in `dmss-digital-stamping-service/seal/README.md` is a summary of
it.

The shipped `dmss-digital-stamping-service/seal/seal.p12` is a demo keystore.
**Do not use it for real seals.**

| Property | Value |
|---|---|
| Subject | `CN=Trustlynx Local Seal Demo, OU=Digital Mind Stamping Service, O=Trustlynx, C=LV` |
| Issuer | self-signed (same as the subject) |
| Valid until | 2028-08-13 |
| Key | RSA 2048-bit, key usage digitalSignature and nonRepudiation |
| Alias / password | `seal` / `changeit` |

## Tools you need

- **`openssl`.** It is already a host prerequisite
  ([2.1 Host and software](02-01-host-and-software.md)). Every recipe on this
  page works with `openssl` alone.
- **`keytool`** (optional). It comes with a Java runtime and gives a more
  readable listing of a keystore. No PadSign script needs it, so it is usually
  not on the host. Install a headless JRE, for example
  `sudo apt install openjdk-17-jre-headless`, or run the `keytool` commands on a
  workstation instead.

Build the keystore on a machine you trust. Use a strong keystore password that
you do not use anywhere else. Do not use `changeit`.

## Step 1: Get a certificate

| Use case | Certificate |
|---|---|
| eIDAS-qualified e-seal, legally valid across the EU | A qualified electronic seal certificate from a qualified trust service provider, issued to your legal entity. Examples: eParaksts (LV), SK ID Solutions (EE), Certum (PL). |
| A seal that general PDF verifiers accept, without an eIDAS claim | A document-signing certificate from a public CA |
| Documents that only your own systems verify | A certificate from your internal CA |

The certificate must allow the **digital signature** key usage, and ideally
**non-repudiation** too. A qualified *seal* and a qualified *signature* are
different products, so ask the CA for a seal.

The CA delivers the material in one of these forms. Pick the recipe that
matches:

| You received | Recipe |
|---|---|
| A certificate (`.crt`/`.pem`/`.cer`) and a private key (`.key`), optionally with a chain file | A |
| A single `.pfx` / `.p12` bundle and its password | B |
| A single PEM file with the certificate, key and chain joined together | Split it (below), then use recipe A |

### Recipe A: certificate and key as separate files

```bash
openssl pkcs12 -export \
    -in       cert.crt \
    -inkey    private.key \
    -certfile chain.crt \
    -name     seal \
    -out      production.p12 \
    -passout  pass:'<keystore password>'
```

- `-certfile chain.crt` adds the intermediate CA certificates, in PEM form,
  with the intermediate first. Include them, because most verifiers need the
  whole chain. Leave the option out only if you have no chain file.
- `-name seal` sets the alias. If you choose a different alias, set it as
  `alias:` in Step 3.
- If `private.key` has a passphrase, `openssl` asks for it. To supply it
  without the prompt, add `-passin pass:'<key passphrase>'`.

### Recipe B: a `.pfx` / `.p12` bundle

First find the alias inside it (the `friendlyName` line):

```bash
openssl pkcs12 -in source.pfx -nokeys -passin pass:'<source password>' | grep friendlyName
```

If you like the alias and the password, you can use the file as it is. Go to
Step 2.

Otherwise, export it again with the alias `seal` and your own password:

```bash
umask 077
openssl pkcs12 -in source.pfx -passin pass:'<source password>' -nodes -out _tmp.pem
openssl pkcs12 -export -in _tmp.pem -name seal -out production.p12 \
    -passout pass:'<keystore password>'
shred -u _tmp.pem 2>/dev/null || rm -f _tmp.pem
```

`_tmp.pem` holds the private key unencrypted, so delete it straight away.
Bundles exported from Windows often use old encryption. If `openssl` 3 reports
`unsupported` or `RC2-40-CBC`, add `-legacy` to the first command.

With `keytool`, you can rename the alias in place instead:
`keytool -changealias -keystore source.p12 -storetype PKCS12 -storepass
'<source password>' -alias '<old alias>' -destalias seal`.

### Splitting a PEM bundle

```bash
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' bundle.pem > certs.pem
awk '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/' bundle.pem > private.key
```

`certs.pem` now holds your certificate first, followed by the chain. Pass it as
`-in certs.pem` in recipe A, and leave out `-certfile`.

## Step 2: Check the keystore

```bash
openssl pkcs12 -in production.p12 -nokeys -passin pass:'<keystore password>' \
    | grep -E 'friendlyName|subject=|issuer='
openssl pkcs12 -in production.p12 -nokeys -passin pass:'<keystore password>' \
    | openssl x509 -noout -subject -issuer -dates -ext keyUsage
# optional, with keytool:
keytool -list -v -keystore production.p12 -storetype PKCS12 -storepass '<keystore password>'
```

Check each of these:

- **Alias.** The `friendlyName` of your key entry is `seal`, or the alias you
  will set in Step 3.
- **Subject.** It is the identity that should appear on sealed PDFs. The CN
  usually shows as "Signed by".
- **Issuer.** It is your CA.
- **Validity.** `notAfter` is far enough away to plan the next rotation.
- **Key usage.** It includes Digital Signature.
- **Chain.** Unless the certificate is self-signed, the first command lists at
  least two certificates: yours and at least one intermediate. If it lists only
  yours, build the keystore again with `-certfile`.

## Step 3: Deploy the keystore

You can deploy the keystore in one of two ways:

- **Replace the demo keystore.** Change the keystore and password of the
  shipped `TrustLynx` company, as shown below. `LocalDemo` then seals with your
  certificate. This is the quickest way.
- **Keep the demo and add your own.** Keep the demo company and profile, and
  add a company and profile of your own, following
  [10.7](10-07-adding-a-signing-profile.md). This is better for production,
  because `LocalDemo` stays available as a known-good test.

In both cases, give the file its own name, such as `production.p12`, rather
than overwriting `seal.p12`. `seal.p12` is a tracked file of the release, and a
new file keeps your key out of `git stash` and `git pull` when you upgrade
([9.5](09-05-upgrading.md)).

```bash
cd /opt/padsign
cp /path/to/production.p12 dmss-digital-stamping-service/seal/production.p12
```

Next, restrict who can read the keystore and `application.yml`. The stamping
container must still be able to read both. While the service is still running
on the demo keystore, find the user it runs as:

```bash
docker compose exec dmss-digital-stamping-service id
```

- If it prints `uid=0(root)`, run
  `chmod 600 dmss-digital-stamping-service/seal/production.p12`.
- Otherwise, give the files to that user's group:
  ```bash
  sudo chgrp <gid> dmss-digital-stamping-service/seal/production.p12 dmss-digital-stamping-service/application.yml
  sudo chmod 640   dmss-digital-stamping-service/seal/production.p12 dmss-digital-stamping-service/application.yml
  ```

Edit the provider entry in `dmss-digital-stamping-service/application.yml`:

```yaml
stamping:
  companies:
    - name: "TrustLynx"
      providers:
        - name: P12
          engine: P12
          keystore: file:/seal/production.p12     # was file:/seal/seal.p12
          password: <keystore password>           # was changeit
          alias: seal                             # or your alias
```

Restart the service:

```bash
docker compose restart dmss-digital-stamping-service
docker compose ps dmss-digital-stamping-service      # wait for (healthy)
```

## Step 4: Check the certificate the service serves

The stamping service has no host port, and its image has no `curl`. Ask it
from container-signature, which can reach it over the Docker network. The
reply is the certificate as hex-encoded DER in the `cert` field:

```bash
docker compose exec -T dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

If you added your own company, use its name instead of `TrustLynx`. The subject
must match Step 2. If it still shows `CN=Trustlynx Local Seal Demo`, the change
did not take effect. Check the `keystore:` path and that the container has
restarted.

## Step 5: Rotate the demo passwords

Three demo defaults are set to `changeit`. They guard two different things, so
use a different strong password for each:

| # | Where | What it protects |
|---|---|---|
| 1 | The keystore itself, and `password:` under `providers` in `dmss-digital-stamping-service/application.yml` (the two must match) | The signing key. It is done once you finish Step 3 with a new keystore. |
| 2 | `SPRING_SECURITY_USER_PASSWORD` on `dmss-container-and-signature-services` in `docker-compose.yml` | Container-signature's HTTP API, which includes the e-seal endpoint. nginx also publishes it at `/container/api/`. |
| 3 | `STAMP_LOCAL.password` in `config/config.js` | `ps-server`'s login to that API. It must equal #2. |

To rotate #2 and #3:

```bash
# 1. Put the same new password in both files:
#      docker-compose.yml:  - SPRING_SECURITY_USER_PASSWORD=<new password>
#      config/config.js:    STAMP_LOCAL: { ..., password: "<new password>", ... }
# 2. Recreate container-signature (environment changes need a recreate) and restart ps-server:
docker compose up -d dmss-container-and-signature-services
docker compose restart ps-server
```

If you keep the demo keystore for a while, give it a new password too. Use
`keytool -storepasswd -keystore dmss-digital-stamping-service/seal/seal.p12
-storetype PKCS12`, or export it again with recipe B. Then update `password:`.

Also see the full demo-credential checklist in
[6. Production hardening](06-production-hardening.md).

## Step 6: Choose the signature level

`LocalDemo` uses `B_BES`, the only level that works with the self-signed demo
certificate. With a real certificate:

| Your CA | Level | Notes |
|---|---|---|
| A qualified trust service provider on an EU trusted list | `LT`, or `LTA` for long retention | Needs a TSA and OCSP ([10.8](10-08-tsa-and-ocsp-for-lt-and-lta.md)). |
| A public CA that is not on an EU trusted list | `LT` | Not eIDAS-qualified, but Adobe Reader and most verifiers recognise it. Needs a TSA and OCSP. |
| An internal CA | `B_BES` | LT/LTA also need OCSP, a TSA, and verifiers that trust your CA. |
| Not sure yet | `B_BES` first | Get the flow working end to end, then move up. |

The level is set per profile. To set a level other than `LocalDemo`'s, add
your own profile ([10.7](10-07-adding-a-signing-profile.md)).

## Keeping the secrets safe

- Keep the production keystore and the production `application.yml` on the
  deployment host only. Never commit them to a repository.
- Store the keystore password apart from the keystore, for example in your
  secret manager, and with a different list of people who can access it.
- Decide when you will rotate them. Watch the certificate's expiry date, and
  renew before it passes.
