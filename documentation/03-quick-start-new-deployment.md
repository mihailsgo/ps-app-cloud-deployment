# 3. Quick Start (New Deployment)

**Before you start** — have these four things ready (the deploy itself takes
about 15 minutes once they are):

1. A **Linux host** with Docker Engine 20+ and Compose v2 — full requirements in [9. Prerequisites](09-prerequisites.md)
2. **DNS** for your chosen hostname pointing at the host
3. A **TLS certificate** (full chain) and **unencrypted private key**, staged as
   `installation-scripts/certs/<host>.crt` and `.key` — format details in [11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md)
4. **Port 443 free** (the stack also binds 80, 8080, 3001, 84, 86, 93 — see [9. Prerequisites](09-prerequisites.md))

Then deploy PadSign with one command (the `chmod` is needed once per fresh
clone — the scripts ship without the executable bit):

```bash
chmod +x ./installation-scripts/*.sh
./installation-scripts/bootstrap.sh \
  --host padsign.client.com \
  --company-role "ClientName" \
  --admin-pass "StrongKeycloakAdminPass" \
  --cert-crt ./installation-scripts/certs/padsign.client.com.crt \
  --cert-key ./installation-scripts/certs/padsign.client.com.key
```

> Prefer a browser over the CLI? See [36. Deployment Wizard](36-deployment-wizard.md) —
> an optional guided UI that wraps this same script, with inline TLS-cert
> validation and live progress instead of raw terminal output.

## Sub-sections

- [3.1 What bootstrap does (step by step)](03-01-what-bootstrap-does-step-by-step.md)
- [3.2 Bootstrap parameters](03-02-bootstrap-parameters.md)
