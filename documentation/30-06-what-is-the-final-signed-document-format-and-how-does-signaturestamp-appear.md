# 30.6 What is the final signed document format, and how does signature/stamp appear?

- Final output remains PDF.
- Visual signature is placed into PDF content via the visual-signature service flow.
- Optional digital stamp is applied via stamping service (`/api/stamp`) when enabled.
- Resulting PDF may include:
  - visible signature graphics/text in document content
  - digital signature/stamp metadata visible in PDF signature panel (viewer-dependent)

