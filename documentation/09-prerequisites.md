# 9. Prerequisites

**Platform:** the supported deployment target is a **Linux** host (any
distribution that runs Docker). Windows tooling mentioned in this guide
(`nginx/mkcert.exe`, `keycloak-bootstrap.ps1`) exists for development
convenience only.

Host requirements:

- Docker Engine 20+ with **Compose v2** — `docker compose version` must work;
  compose *profiles* are load-bearing for optional features (local e-sealing,
  the Deployment Wizard).
- Command-line tools the installation scripts check for: `bash`, `awk`, `perl`,
  `python3`, `curl`, `openssl` (all pre-installed on most server
  distributions). Production e-seal keystore work additionally uses `keytool`
  (bundled with any JRE) — see
  [4.6 Production setup](04-06-production-setup-deploying-with-your-own-key-and-certificate.md).
- A DNS name you control (production) or a local hostname mapping (development).
- TLS certificate and key for your hostname (PEM). Self-signed is acceptable
  for local testing. Format requirements:
  [11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md).
- Open host ports: 80, 443, 8080, 3001, 84, 86, 93 — plus 8443 if you use the
  [Deployment Wizard](36-deployment-wizard.md).
- Suggested resources: 4 vCPU, 6-8 GB RAM, and at least 10 GB free disk for
  images, volumes, and signed-document output.

Optional (local development):

- mkcert (included as `nginx/mkcert.exe` for Windows) to generate a locally trusted certificate.

---
