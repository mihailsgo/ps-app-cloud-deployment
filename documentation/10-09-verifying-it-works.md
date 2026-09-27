# 10.9 Verifying it works

Run these checks after you enable local e-sealing, replace the keystore, or
change a profile. Together they show that the stack produces sealed PDFs.
Whether an outside verifier *trusts* those seals is covered in
[10.10](10-10-verifying-signatures-end-to-end.md).

Run all commands from `/opt/padsign` on the deployment host.

## 1. The services are up

```bash
docker compose ps dmss-digital-stamping-service dmss-container-and-signature-services ps-server
```

All three should show `(healthy)`. After a restart, the two Java services can
take a few minutes. If the stamping service is `Restarting` or `unhealthy`,
run `docker compose logs --tail 200 dmss-digital-stamping-service`. The usual
causes are a missing keystore file, a `password:` that does not match the
keystore, or an `alias:` that is not in it.

## 2. The configuration is consistent

```bash
grep -E 'STAMP_MODE|profile/' config/config.js     # STAMP_MODE: "local", and the profile URL
grep -E '^COMPOSE_PROFILES' .env                   # contains local-eseal
grep -A1 '^digital-stamping-service:' dmss-container-and-signature-services/application.yml
#   baseUrl: http://dmss-digital-stamping-service:8084/api
grep '"RUN_STAMPING_REQUEST"' config/constants.json # true
```

## 3. The stamping service serves the expected certificate

```bash
docker compose exec -T dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; sys.stdout.buffer.write(bytes.fromhex(json.load(sys.stdin)['cert']))" \
    | openssl x509 -inform DER -noout -subject -issuer -dates
```

If you added your own company, use its name instead of `TrustLynx`. With the
demo keystore, the output is
`subject=C=LV, O=Trustlynx, OU=Digital Mind Stamping Service, CN=Trustlynx Local Seal Demo`,
valid until Aug 13 2028. With your own keystore, the output must show your
certificate.

## 4. Container-signature seals a PDF

Port 84 is bound to `127.0.0.1`. Run this on the host itself, or through
`ssh -L 84:localhost:84 <host>`. Use your Spring Security password and your
profile name if you have changed them:

```bash
curl -sS -u user:changeit -X POST \
    -F "file=@/path/to/any-small.pdf;type=application/pdf" \
    -o /tmp/sealed.pdf -w "HTTP=%{http_code} bytes=%{size_download}\n" \
    http://localhost:84/api/eseal/document/profile/LocalDemo
grep -aoE '/Type\s*/Sig|/ByteRange\s*\[[^]]+\]' /tmp/sealed.pdf
```

Expect `HTTP=200`, a non-zero size, and both `/Type /Sig` and a `/ByteRange
[...]` line. A `401` means the password is wrong. A `5xx` means the profile,
company, alias or keystore does not match; check the container-signature log.

## 5. The portal seals through ps-server

Sign a document in the portal as a normal user would. Then run:

```bash
docker compose logs --tail 200 ps-server | grep -E '\[stamp\]|Stamp response status'
```

A working seal produces:

```
[stamp] mode=local url=http://dmss-container-and-signature-services:8092/api/eseal/document/profile/LocalDemo
[DEBUG] Stamp response status: 200
```

What other results mean:

- **No `[stamp]` line at all.** The portal did not ask for a seal. Set
  `RUN_STAMPING_REQUEST` to `true` in `config/constants.json`, run
  `docker compose restart ps-client`, and reload the portal.
- **`mode=external`.** `ps-server` is still running with the old
  configuration. Check `STAMP_MODE`, then run `docker compose restart ps-server`.
- **`[stamp] upstream unavailable, continuing without stamp`.** The seal
  failed and the document was left unsealed
  ([10.2](10-02-architecture.md#what-happens-when-a-link-breaks)).

To check the file itself, download the latest version from the archive (bound
to `127.0.0.1:86`) and run the `grep` from check 4 on it:

```bash
curl -fsS "http://localhost:86/api/document/<docid>/download" -o /tmp/portal-sealed.pdf
```

With filesystem routing enabled, the sealed copy is also under `signed-output/`.

## 6. It keeps sealing

Seal **more than one** document in a row. Some container-signature images seal
the first document after a restart and then fail every later one. That shows
up as stamp requests that hang and then fail with `503 STAMP_CIRCUIT_OPEN`.
To test the pinned images in an isolated project, without touching the running
stack:

```bash
./installation-scripts/dmss-seal-smoke.sh      # boots the pinned DMSS images, seals 3 times in a row
```

This needs Docker, `python3` and outbound network access. It removes
everything it created when it finishes.

## 7. Full signing smoke test (optional)

`installation-scripts/signing-smoke.sh --with-seal` signs a test PDF through
the public URL, as a temporary user, and applies the deployment's configured
seal. Only use `--with-seal` where a seal on a test document is acceptable: with
a production keystore, it is a real seal by your organisation. See
[5.4 Signing smoke test](05-04-signing-smoke-test.md).
