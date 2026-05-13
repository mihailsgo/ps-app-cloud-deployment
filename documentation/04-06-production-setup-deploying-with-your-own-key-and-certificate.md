# 4.6 Production setup: deploying with your own key and certificate

This is the main path for putting local e-sealing into production. The
shipped `dmss-digital-stamping-service/seal/seal.p12` is a self-signed
RSA-2048 demo keystore (alias `seal`, password `changeit`, valid until
2028-08-13). **Do not use it for real signatures.** The recipes below
build a new PKCS12 keystore from whatever artefacts your CA provided and
deploy it into the stamping service.

## Step 1 - Inventory what you have

Your CA (or your internal PKI team) typically delivers signing material in
one of these shapes. Identify yours and follow the matching recipe:

| You have... | Use Recipe |
|---|---|
| separate `cert.crt` (or `.pem` / `.cer`) **and** `private.key` file, optionally a separate `chain.crt` of intermediate CA certs | **A** |
| a single bundle file in PKCS12 format - `.pfx` (typical Windows) or `.p12` (typical Linux/Java), password-protected | **B** |
| an existing `.p12` that uses an alias other than `seal` | **C** |
| a single PEM file that contains the cert AND the key (and maybe the chain) concatenated | split it manually (see *Splitting a PEM bundle* below) then use Recipe A |

If your private key is itself password-protected (asks for a passphrase
when you try to read it), keep that passphrase handy - the recipes accept
it where needed.

The recipes use `openssl` and `keytool` (from the JDK). Both are already
required by `bootstrap.sh`. Replace `<your-keystore-password>` with a
strong password you choose; do not reuse it from any other system.

## Recipe A - From separate `cert.crt` + `private.key` (+ optional `chain.crt`)

```bash
# Without an intermediate-CA chain:
openssl pkcs12 -export \
    -in    cert.crt \
    -inkey private.key \
    -name  seal \
    -out   seal.p12 \
    -passout pass:<your-keystore-password>

# With an intermediate-CA chain (recommended - most verifiers need the
# full chain to validate your signature):
openssl pkcs12 -export \
    -in       cert.crt \
    -inkey    private.key \
    -certfile chain.crt \
    -name     seal \
    -out      seal.p12 \
    -passout pass:<your-keystore-password>
```

Flags explained:

- `-export` - write a PKCS12 file (the default mode is the opposite).
- `-in cert.crt` - your end-entity certificate (the one matching your private key).
- `-inkey private.key` - the matching private key.
- `-certfile chain.crt` - intermediate CA cert(s), concatenated in PEM
  form (intermediate first, root last). Omit if you have no chain to bundle.
- `-name seal` - the alias inside the keystore. The stamping service looks
  for `seal` by default; using any other name forces an `application.yml`
  edit later (see *Step 4*).
- `-out seal.p12` - output filename.
- `-passout pass:…` - the password protecting the keystore. Anything
  password-shaped works; avoid `changeit` and similar known defaults.

If your `private.key` is itself encrypted with its own passphrase, openssl
will prompt you for it - or you can pass `-passin pass:<key-passphrase>`
non-interactively.

## Recipe B - From an existing `.pfx` / `.p12`

The most common case: your CA gave you a `cert.pfx` and a password for it.
If the existing keystore already uses `seal` as the alias, you only need
to copy the file and set the right password in `application.yml` -
**skip to Step 3**.

If the alias inside the `.pfx` is something else (typical CAs use long
identifiers like the CN of the subject), one option is to rename in place
- see Recipe C. The cleanest option is to re-export:

```bash
# Convert to PEM intermediates, then re-export with alias 'seal'.
# Keeps the same key and cert; only changes the alias and password.
openssl pkcs12 -in source.pfx -nokeys  -passin pass:<source-pwd> -out _tmp_cert.pem
openssl pkcs12 -in source.pfx -nocerts -passin pass:<source-pwd> \
    -nodes -out _tmp_key.pem
openssl pkcs12 -export \
    -in    _tmp_cert.pem \
    -inkey _tmp_key.pem \
    -name  seal \
    -out   seal.p12 \
    -passout pass:<your-keystore-password>
rm _tmp_cert.pem _tmp_key.pem
```

The two intermediate files contain unencrypted key material - delete them
immediately after the export and run on a workstation you trust (not a
shared CI runner).

## Recipe C - Rename the alias inside an existing `.p12`

If you'd rather keep the existing `.p12` byte-for-byte (only changing the
internal alias name to `seal`), `keytool` can do this in place:

```bash
keytool -changealias \
    -keystore  source.p12 \
    -storetype PKCS12 \
    -storepass <source-pwd> \
    -alias     <existing-alias-name> \
    -destalias seal

# Then rename or copy:
cp source.p12 seal.p12
```

`keytool -list -keystore source.p12 -storepass <source-pwd>` (see Step 2)
tells you what the existing alias name is.

## Splitting a PEM bundle

Some CAs deliver one file containing cert, key, and chain concatenated.
Split it before running Recipe A:

```bash
# Extract certificate (and chain if present) into cert.crt:
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' bundle.pem > cert.crt
# Extract private key (first key block):
awk '/-----BEGIN .* PRIVATE KEY-----/,/-----END .* PRIVATE KEY-----/' bundle.pem > private.key
```

## Step 2 - Verify the new keystore

Before deploying, confirm the keystore actually contains what you expect:

```bash
# What aliases are inside? Should list one entry named 'seal'.
keytool -list -keystore seal.p12 -storepass <your-keystore-password>

# Detailed view of the 'seal' entry - subject DN, issuer DN, validity dates,
# key algorithm, the public-cert chain.
keytool -list -v -keystore seal.p12 -storepass <your-keystore-password> -alias seal

# Full chain dump in OpenSSL format (useful for spotting missing intermediates).
openssl pkcs12 -in seal.p12 -info -nokeys -passin pass:<your-keystore-password>
```

What to check:

- **Alias** equals `seal` (or whatever you'll set in `application.yml`).
- **Subject DN** matches the identity you want to appear on signed PDFs
  (the CN typically becomes the "Signed by" name shown by Adobe Reader).
- **Issuer DN** matches the CA that issued your cert.
- **Validity** - `notAfter` is far enough in the future that you have
  time to plan rotation.
- **Key algorithm** - typically `RSA` 2048+ or `EC` (ECDSA). digidoc4j
  supports both.
- **Chain length** - for non-self-signed certs you should see at least
  two certificates in the chain dump (your end-entity cert + at least
  one intermediate). If `openssl pkcs12 -info` shows only one cert, your
  signatures will probably fail external trust validation; rebuild with
  `-certfile chain.crt`.

## Step 3 - Deploy the new keystore

```bash
cd /opt/psapp   # wherever the deployment lives

# Stop only the stamping container (no service interruption to ps-server
# or container-signature beyond brief signing unavailability).
docker compose stop dmss-digital-stamping-service

# Replace the demo PKCS12 with yours.
cp /path/to/your/seal.p12 dmss-digital-stamping-service/seal/seal.p12

# Make sure permissions are tight; the keystore is a secret.
chmod 600 dmss-digital-stamping-service/seal/seal.p12

# Update the stamping service config to match your password (and alias if
# different from 'seal'). Open the file:
vi dmss-digital-stamping-service/application.yml
#   change:    password: changeit
#   to:        password: <your-keystore-password>
#   if your alias is not 'seal', also change:
#                alias: seal   →   alias: <your-alias>

# Bring the stamping container back up.
docker compose --profile local-eseal up -d dmss-digital-stamping-service
```

Smoke test that the new cert is what the service serves:

```bash
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

The printed subject must match what you saw in Step 2; if it shows the
demo cert's DN (`CN=Trustlynx Local Seal Demo`) then the keystore swap
did not take effect - check the file path and that the container actually
restarted.

## Step 4 - Pick the right `signatureProfile` for your certificate

The shipped `LocalDemo` profile uses `B_BES`, which is the only level
that works with the self-signed demo cert. Once your cert is in place
you most likely want a higher level. Decide based on what your CA is:

| Your CA | Suggested profile | Why |
|---|---|---|
| Publicly-trusted CA listed in an EU member-state TSL (eIDAS-qualified TSP) | `LT` (for most use cases) or `LTA` (for long-retention archives) | Produces eIDAS-grade advanced/qualified signatures. Needs TSA + OCSP wiring - see next section. |
| Public CA, but not on an EU TSL | `LT` | Cryptographically equivalent, but not eIDAS-qualified. Still recognised by Adobe Reader and most PDF verifiers. |
| Internal / private CA (your own org's PKI) | `B_BES` | LT/LTA need OCSP/TSA wiring AND a verifier that trusts your internal CA. B_BES sidesteps both. |
| You don't know | `B_BES` to start | Get the flow working end-to-end first. Move to LT later by following the next section. |

Don't change the shipped `LocalDemo` profile - it's the safe demo path.
Create your own profile instead:
[Adding a new signing profile end-to-end](04-07-adding-a-new-signing-profile-end-to-end.md#47-adding-a-new-signing-profile-end-to-end).
If you need timestamping (anything above B_BES), continue to:
[Wiring TSA and OCSP for LT and LTA signature profiles](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles).

## Step 5 - Storing the keystore password

The keystore password ends up in `dmss-digital-stamping-service/application.yml`
(in plaintext, since Spring needs to read it at startup). Apply the same
treatment as any production secret:

- Do **not** commit the production `application.yml` to source control.
  Keep it on the deployment host only. The committed default in this repo
  is the demo password - that's intentional and safe.
- Make the file readable only by the user that owns the docker daemon
  (or by `root`): `chmod 600 dmss-digital-stamping-service/application.yml`.
- Keep an offline copy of the keystore password separate from the
  keystore itself - different storage, different access list. If you
  use a secret manager (Vault, AWS Secrets Manager, etc.) the password
  goes there; the keystore can live on disk or also in the secret manager.
- Decide a rotation cadence and document it in your internal runbook.
- Never reuse the keystore password for any other system.

---

