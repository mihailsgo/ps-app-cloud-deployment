# 9. Prerequisites

**Platform:** the supported deployment target is a **Linux** host (any
distribution that runs Docker). Windows tooling mentioned in this guide
(`nginx/mkcert.exe`) exists for development convenience only. On a
Windows development machine, run the bash scripts from Git Bash or WSL.

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
- Open host ports: 80, 443 — plus 8443 if you use the
  [Deployment Wizard](36-deployment-wizard.md). Keycloak (8080), the DMSS archive
  and container/signature services (86, 84) are bound to `127.0.0.1` only, for
  local operator diagnostics — see [22. Security and Route Protection](22-security-and-route-protection.md).
  ps-server (3001) and the DMSS archive fallback service (93) have no host
  binding at all; nginx reaches every internal service over the Docker network.
- Suggested resources: 4 vCPU, 6-8 GB RAM, and at least 10 GB free disk for
  images, volumes, and signed-document output.

Optional (local development):

- mkcert (included as `nginx/mkcert.exe` for Windows) to generate a locally trusted certificate.

---
