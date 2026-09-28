# 10.1 Concepts and glossary

Local e-sealing signs the PDF inside a container on your own host. It uses a
private key and certificate that you control, so the document is not sent to a
cloud signing service. The output is a standard signed PDF that Adobe Reader
and other PDF verifiers can check.

This page explains the terms used in the rest of section 10.

## Terms

| Term | Meaning |
|---|---|
| **Certificate** | A file, usually `.crt`, `.cer` or `.pem`, issued by a Certificate Authority (CA). It holds the public key and the identity it belongs to: organisation, country and validity dates. |
| **Private key** | The secret half of the certificate's key pair, usually a `.key` PEM file that may have a passphrase. It must not leave the signing host. |
| **PKCS12** (`.p12` / `.pfx`) | One password-protected file that holds a private key, its certificate and, optionally, the intermediate-CA chain. The stamping service reads its key in this format. |
| **Alias** | The name of one key-and-certificate entry inside a keystore. The shipped configuration uses the alias `seal`. |
| **PEM** | A text format for keys and certificates (`-----BEGIN CERTIFICATE-----` …). `openssl` converts PEM files to PKCS12. |
| **CA (Certificate Authority)** | The organisation that issues your certificate. Public CAs chain to a globally trusted root. Private or internal CAs do not. |
| **Trust chain** | The certificates from your signing certificate, through any intermediate CAs, up to a trusted root. A verifier needs the whole chain to trust a signature. |
| **Signature profile** | The signature level produced by container-signature: `B_BES` (basic and self-contained), `LT` (long-term, includes a timestamp and revocation data) or `LTA` (LT plus archival timestamps). |
| **PAdES** | The ETSI standard family for PDF signatures. Its levels are `PAdES_BASELINE_B`, `_T`, `_LT` and `_LTA`, each adding more long-term evidence than the one before. |
| **ASiC-E** | A zip-based container that holds files together with their detached signatures. A profile can produce one instead of a sealed PDF (`esealAsContainer`). The shipped local-sealing profile does not. |
| **TSA / TSP** | Timestamp Authority / Timestamp Protocol. A network service that signs a hash together with the current time. `LT` and `LTA` need one. |
| **OCSP** | Online Certificate Status Protocol. A network service that says whether a certificate has been revoked. `LT` and `LTA` embed OCSP responses in the signature. |
| **TSL** | Trust Service List. The XML list, published by each EU member state, of its qualified trust service providers (CAs and TSAs). |
| **eIDAS** | EU Regulation 910/2014. It defines what counts as a *qualified* electronic seal: broadly, one from a qualified CA, made at `LT`/`LTA` level with a qualified TSA. |
| **digidoc4j** | The signing library inside container-signature. It is configured in the `digidoc4j:` section of `dmss-container-and-signature-services/application.yml` and in `digidoc4j-custom.yaml`. |
| **Container-signature** | Short name for the `dmss-container-and-signature-services` container. It builds the signed PDF. |
| **Stamping service** | Short name for the `dmss-digital-stamping-service` container. It holds the keystore and has two endpoints: `GET /api/signing/certificate/for/<company>` returns the certificate, and `POST /api/sign/digest/as/<company>` signs a digest. |
| **Profile** | An entry in `dmss-container-and-signature-services/documentsigningprofiles.json`. Its `name` is used in the request URL. Its `esealCompany` names the stamping company to sign with. It also holds the signature level and the visible-signature settings. |
| **Company** | An entry under `stamping.companies` in `dmss-digital-stamping-service/application.yml`. It pairs a name with one or more `providers`, and each provider points at a keystore. |

## Choosing a signature level

| Level | Needs TSA | Needs OCSP | Legal status (EU eIDAS) |
|---|---|---|---|
| `B_BES` (`PAdES_BASELINE_B`) | no | no | Basic electronic seal. Cryptographically valid but not qualified. Suitable for internal workflows, demos and non-regulated business. |
| `LT` (`PAdES_BASELINE_LT`) | **yes** | **yes** | Advanced electronic seal with the validation data embedded. With a qualified CA and a qualified TSA, it can be a qualified e-seal. |
| `LTA` (`PAdES_BASELINE_LTA`) | **yes** | **yes** | Like `LT`, plus archival timestamps, so the seal can still be verified after the algorithms it uses become outdated. Choose it for long-retention archives. |

Container-signature's default level is `pdf.defaultSignatureLevel:
PAdES_BASELINE_LT` in its `application.yml`. Any profile without its own
`signatureProfile` uses that default. The shipped `LocalDemo` profile sets
`B_BES`, because no TSA timestamps the self-signed demo certificate. To choose
a level for your own certificate, see
[10.6 Production key and certificate](10-06-production-key-and-certificate.md#step-6-choose-the-signature-level).
