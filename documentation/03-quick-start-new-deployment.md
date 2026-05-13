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

## Sub-sections

- [3.1 What bootstrap does (step by step)](03-01-what-bootstrap-does-step-by-step.md)
- [3.2 Bootstrap parameters](03-02-bootstrap-parameters.md)

