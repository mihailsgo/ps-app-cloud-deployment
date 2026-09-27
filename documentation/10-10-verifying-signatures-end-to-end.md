# 10.10 Verifying signatures end-to-end

[10.9](10-09-verifying-it-works.md) shows that the stack produces a seal. This
page shows whether real-world verifiers, such as Adobe Reader, a downstream
archive or a counterparty, accept that seal. Do these checks before you use
local e-sealing in production, and again after every certificate change.

## Adobe Acrobat Reader

1. Open the sealed PDF and open the **Signature Panel**.
2. Expand the signature. You will see one of three results:
   - **"Signed and all signatures are valid"** (green). Adobe trusts both the
     certificate chain and the signature.
   - **"At least one signature has problems"**. This usually means the
     signature is valid but Adobe's trust store does not include your CA. This
     is the expected result for the demo certificate and for internal CAs. To
     inspect the chain, open *Signature Properties → Show Signer's Certificate*.
   - **"At least one signature is invalid"**. The document was changed after
     sealing, the certificate was revoked, or the chain is broken. Compare the
     certificate in the panel with the one the stamping service serves
     ([10.9, check 3](10-09-verifying-it-works.md#3-the-stamping-service-serves-the-expected-certificate)).

## pdfsig (command line)

`pdfsig` is part of Poppler (`poppler-utils` on Debian/Ubuntu):

```bash
pdfsig sealed.pdf
```

The two lines that matter are:

- `Signature Validation: Signature is Valid.` This means the signed bytes
  match the signature. Any other value means the document or the signature is
  damaged.
- `Certificate Validation:` This is `Certificate is Trusted.` only if your CA
  is in the local trust store. The demo certificate and internal CAs show
  `Certificate issuer isn't Trusted.`. Trust belongs to the verifier's trust
  store, not to the signature.

## Automated verification

If another system decides whether to accept seals, it should use a validator
that produces a structured report (XML or JSON), such as the EU DSS
demonstration/validation tool or the digidoc4j command-line utility. Base
automated decisions on that report, not on the text output of `pdfsig`.

## From "valid" to "valid and trusted"

The demo certificate always shows as valid but not trusted: the seal is sound,
but no verifier trusts a self-signed certificate. To get a trusted result:

1. Seal with a CA-issued certificate ([10.6](10-06-production-key-and-certificate.md)).
2. For long-term validity, use `LT` or `LTA`, with a TSA and OCSP
   ([10.8](10-08-tsa-and-ocsp-for-lt-and-lta.md)).
3. Make sure the verifier trusts your CA's root:
   - **Adobe Reader, per user.** Go to *Edit → Preferences → Signatures →
     Identities & Trusted Certificates → More → Trusted Certificates → Import*.
     Import the CA root certificate (`.cer`), tick **Use this certificate as a
     trusted root**, then reopen the PDF.
   - **System-wide.** On Windows, use `certmgr.msc` → Trusted Root
     Certification Authorities. On macOS, add it in Keychain Access and set it
     to "Always Trust". On Debian/Ubuntu, copy it to
     `/usr/local/share/ca-certificates/` (as `.crt`) and run
     `sudo update-ca-certificates`.

With an internal CA, only verifiers whose trust stores you control will ever
report "trusted". A recipient's Adobe Reader will always show "valid but
untrusted" for these seals. That is expected and not a fault in the stack.

## Common failures

| Result | Likely cause | Fix |
|---|---|---|
| Valid but untrusted, with a public CA | The chain is missing from the keystore | Build it again with `-certfile chain.crt` ([10.6 Step 2](10-06-production-key-and-certificate.md#step-2-check-the-keystore)) |
| The verifier requires long-term validation | The profile is `B_BES` | Use `LT`/`LTA` and connect a TSA and OCSP ([10.8](10-08-tsa-and-ocsp-for-lt-and-lta.md)) |
| The certificate is rejected for signing | The key usage lacks digitalSignature or nonRepudiation | Ask the CA to issue it again with the right key usage |
