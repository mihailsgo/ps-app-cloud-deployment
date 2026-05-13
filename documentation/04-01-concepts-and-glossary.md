# 4.1 Concepts and glossary

Local e-sealing is a way to put a cryptographic signature (a "seal") onto a
PDF before it leaves the server. Instead of sending the document out to a
cloud signing service, the signing happens inside a Docker container you
control, using a private key and certificate that live on your host. The
result is the same kind of signed PDF that Adobe Reader and other PDF
readers can verify.

If you have never worked with PDF signatures or digital-signature
infrastructure before, these terms appear repeatedly in the rest of this
guide:

| Term | Meaning |
|---|---|
| **Certificate (cert)** | A file (usually `.crt`, `.cer`, or `.pem`) issued by a Certificate Authority (CA). Contains the public key plus identity info (company name, country, validity dates). |
| **Private key** | The matching secret half of the certificate's key pair. Usually a `.key` file (PEM-encoded), sometimes password-protected. Must never leave the signing host. |
| **PKCS12** (`.p12` / `.pfx`) | A single file format that bundles a private key + certificate (+ optional intermediate-CA chain) together, protected by one password. The stamping service consumes its key+cert in this format. |
| **Alias** | A name pointing at one specific key+cert entry inside a PKCS12/JKS keystore. The stamping service uses the alias `seal` by default - your keystore must have an entry with that name (or you edit the config to point at a different alias). |
| **PEM** | A text-encoded format for keys and certs (`-----BEGIN CERTIFICATE-----` ... `-----END CERTIFICATE-----`). Convertible to PKCS12 with `openssl`. |
| **CA (Certificate Authority)** | The organisation that issues your certificate. Public CAs (Sectigo, DigiCert, eParaksts, SK ID Solutions, etc.) chain to a globally trusted root; private/internal CAs do not. |
| **Trust chain** | The sequence of certificates from your signing cert up through intermediate CAs to a trusted root. Any verifier needs the full chain to validate a signature. |
| **signatureProfile** | The "level" of signature digidoc4j produces. The relevant ones for PDF signing are `B_BES` (basic, self-contained), `LT` (long-term, includes a timestamp), and `LTA` (long-term + archival). |
| **PAdES** | "PDF Advanced Electronic Signatures" - the ETSI standard family for PDF signatures. `PAdES_BASELINE_B`, `PAdES_BASELINE_T`, `PAdES_BASELINE_LT`, `PAdES_BASELINE_LTA` are progressive levels of preservation. The default in `application.yml` is `PAdES_BASELINE_LT`. |
| **ASiC-E** | "Associated Signature Container - Extended" - a zip-based container format that holds one or more files plus their detached signatures. Used for sealing non-PDF artefacts; not the default for the local-eseal flow. |
| **TSA / TSP** | "TimeStamp Authority" / "TimeStamp Protocol". A network service that signs `(hash, current-time)` and returns a timestamp token. Required for `LT` / `LTA` signature levels. |
| **OCSP** | "Online Certificate Status Protocol". A network service the verifier queries to check whether a certificate has been revoked. Required for `LT` / `LTA`. |
| **TSL** | "Trust Service List". An XML document, maintained by each EU member state, listing the qualified Trust Service Providers (CAs, TSAs) accepted as eIDAS-qualified. digidoc4j consults TSLs in PROD mode to decide which issuers it will validate against. |
| **eIDAS** | EU Regulation 910/2014. Defines what counts as a *qualified* electronic signature / seal - broadly, a signature whose cert was issued by a qualified CA and whose long-term integrity is provable. Only `LT`/`LTA` signatures with a qualified CA + qualified TSA satisfy eIDAS. |
| **digidoc4j** | The Java library container-signature uses to actually produce the signature. Configured via `dmss-container-and-signature-services/digidoc4j-custom.yaml` and the `digidoc4j:` section of `application.yml`. |
| **Container-signature** | Short name we use in this guide for the `dmss-container-and-signature-services` container. It is the service that orchestrates document sealing. |
| **Stamping service** | Short name for `dmss-digital-stamping-service`. It holds the keystore and answers two endpoints: `GET /api/signing/certificate/for/<company>` and `POST /api/sign/digest/as/<company>`. |
| **Profile** | An entry in `documentsigningprofiles.json` that bundles a name (used in the URL), an `esealCompany` (which must match a company in the stamping service's config), and visual + signature settings. |
| **Company** | An entry in the stamping service's `application.yml` (under `stamping.companies`) that pairs a name with one or more `providers` (each with its own keystore). |

## Picking a signature level

| Profile | Self-contained? | Needs TSA? | Needs OCSP? | Legal status (EU eIDAS) |
|---|---|---|---|---|
| `B_BES` (`PAdES_BASELINE_B`) | yes | no | no | Basic electronic signature. Cryptographically valid; not qualified. Suitable for internal workflows, demos, non-regulated business. |
| `LT` (`PAdES_BASELINE_LT`) | yes after TSA | **yes** | **yes** | Advanced electronic signature with long-term validation data embedded. Qualifies for eIDAS *advanced* level; with a qualified CA + qualified TSA, qualifies as a qualified e-seal. |
| `LTA` (`PAdES_BASELINE_LTA`) | yes, with archival timestamps | **yes** | **yes** | Like LT, plus archival timestamps so the signature stays verifiable as algorithms age. Best for long-retention archives. |

**Default in `dmss-container-and-signature-services/application.yml`:**
`pdf.defaultSignatureLevel: PAdES_BASELINE_LT`. The shipped `LocalDemo`
profile overrides this to `B_BES` so the demo certificate works without a
TSA - see [Production setup: deploying with your own key and certificate](04-06-production-setup-deploying-with-your-own-key-and-certificate.md#46-production-setup-deploying-with-your-own-key-and-certificate)
for how to choose for your real cert.

---

