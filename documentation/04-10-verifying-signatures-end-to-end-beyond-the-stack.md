# 4.10 Verifying signatures end-to-end (beyond the stack)

The smoke test above only proves the stack *produces* a signature
dictionary. It does not prove the signature is **valid** in the eyes of
a real-world PDF verifier (Adobe Reader, a downstream archive, a court).
Run these additional checks before declaring local e-sealing production-ready.

## Adobe Reader (the canonical PDF verifier)

1. Open the signed PDF in **Adobe Acrobat Reader DC**.
2. Open the **Signature Panel** (left sidebar - pen icon, or
   `View → Show/Hide → Navigation Panes → Signatures`).
3. Expand the signature entry. You should see one of three outcomes:

   - ✅ **"Signed and all signatures are valid"** - green check.
     Acrobat trusts your cert chain and the signature math.
   - ⚠ **"At least one signature has problems"** - usually means
     "valid but the signer's identity is unknown / not trusted by
     Acrobat's trust store". This is the expected state for the shipped
     **demo cert** and for any signature whose chain doesn't reach a
     publicly-trusted root. Click *Signature Properties → Show Signer's
     Certificate → Trust* to see the chain. Cryptographically valid, just
     not anchored in Adobe's default trust store.
   - ❌ **"At least one signature is invalid"** - bad. The signed
     hash doesn't match, or the cert was revoked, or the trust chain is
     broken in a way verifier flagged as fatal. Compare the cert subject
     in the panel against what
     `/api/signing/certificate/for/<company>` returns; if they differ,
     something else is signing the PDF.

## CLI: `pdfsig` (Poppler)

`pdfsig` (from the Poppler tools) is the quickest CLI check. Most
distros package it as `poppler-utils` (Debian/Ubuntu) or `poppler`
(macOS Homebrew).

```bash
pdfsig sealed.pdf
# Expect output similar to:
#   Digital Signature Info of: sealed.pdf
#   Signature #1:
#     - Signer Certificate Common Name: <your cert CN>
#     - Signer full Distinguished Name: <your cert subject DN>
#     - Signing Time: <date>
#     - Signing Hash Algorithm: SHA-256
#     - Signature Type: adbe.pkcs7.detached
#     - Signed Ranges: [0 - 271790], [290736 - 290736]
#     - Total document signed: yes
#     - Signature Validation: Signature is Valid.
#     - Certificate Validation: ...
```

The last two lines are the meaningful ones:

- **Signature Validation: Signature is Valid** - cryptographic integrity is
  good. Anything else (Invalid, Decoding Error) means the signed hash
  doesn't reconcile with the embedded signature.
- **Certificate Validation** - `Certificate is Trusted` if your CA is in
  the local trust store, `Certificate issuer isn't Trusted` for the demo
  cert and for any private-CA scenario. Trust is a property of the
  verifier's trust store, not of the signature itself.

## Detached / programmatic verification

For automated downstream verifiers (an internal "I will only accept
signatures I issued" service, for example), use digidoc4j's CLI or the
DSS demo tool. Both consume a PDF and emit a structured validation
report (XML or JSON). That output is what your downstream automation
should make trust decisions on; do not parse `pdfsig` text output.

## What "good" looks like for the demo cert

The shipped demo cert is self-signed, so Adobe Reader and `pdfsig` will
both report "signature valid, certificate not trusted". That outcome is
expected - the seal itself is cryptographically sound, but no verifier
trusts an arbitrary self-signed CA. To get to "valid + trusted":

- Replace the demo cert with a CA-issued one
  ([Production setup](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate)).
- Use an LT (or higher) profile and wire up TSA + OCSP
  ([Wiring TSA and OCSP](04-08-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles.md#48-wiring-tsa-and-ocsp-for-lt-and-lta-signature-profiles)).
- Confirm your CA's root certificate is in the verifier's trust store.

  *Adobe Reader (per-user import):*
  1. Export your CA's root certificate to a `.cer` file (your CA's
     download page will offer it).
  2. In Adobe Acrobat Reader DC: `Edit → Preferences → Signatures →
     Identities & Trusted Certificates → More` → `Trusted Certificates`
     → `Import`.
  3. Browse to the `.cer` file, select it, click `Import`.
  4. In the next dialog tick `Use this certificate as a trusted root`
     and (if you want) `Certified documents` and `Dynamic content`.
     Click `OK`.
  5. Re-open the signed PDF - the Signature Panel should now show
     the green check.

  *System-wide trust (so every PDF tool picks it up, not just Adobe):*
  on Windows, add to the Trusted Root Certification Authorities store
  via `certmgr.msc`; on macOS, drop into Keychain Access and mark
  "Always Trust"; on Debian/Ubuntu, copy to `/usr/local/share/ca-certificates/`
  and run `sudo update-ca-certificates`. The exact mechanism is OS-side,
  not part of this stack.

  *Internal CA case:* if you signed with a cert from your own internal
  CA, the only verifiers who will ever return "trusted" are ones whose
  trust stores you control. End-user Adobe Reader on a stranger's
  machine will always show "valid but untrusted" for internal-CA
  signatures - that's expected, not a stack defect.

