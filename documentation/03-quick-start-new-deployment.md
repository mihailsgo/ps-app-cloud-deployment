# 3. Quick Start (New Deployment)

One command to deploy PadSign on a new server:

```bash
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

