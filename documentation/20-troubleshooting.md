# 20. Troubleshooting

Start from your symptom:

| Symptom | Where to look |
|---|---|
| Browser: `Failed to load module script` for `/portal/keycloak.js` | [20.1 Common Issues](20-01-common-issues.md), issue 0 |
| Login fails, "Invalid redirect URI", CORS errors | [20.1 Common Issues](20-01-common-issues.md), issues 1–3 |
| Containers won't start, a port is already in use | [20.1 Common Issues](20-01-common-issues.md), issue 4 |
| Browser TLS warning, wrong hostname on the certificate | [20.1 Common Issues](20-01-common-issues.md), issue 5 |
| Certificate was renewed on disk but the old one is still served | [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md) |
| Services can't reach each other (e.g. ps-server → DMSS) | [20.1 Common Issues](20-01-common-issues.md), issue 6 |
| E-sealing silently skipped (`stampStatus: "skipped"` in the response) | [4.2 Architecture deep-dive](04-02-architecture-deep-dive.md) (failure chain) and [4.9 Verifying it works](04-09-verifying-it-works.md) |
| Deployment Wizard problems (access token, port 8443, stuck progress) | [36.6 Troubleshooting the wizard](36-06-troubleshooting-the-wizard.md) |
| "Is my configuration consistent?" | [6. Validating Configuration](06-validating-configuration.md) |

## Sub-sections

- [20.1 Common Issues](20-01-common-issues.md)
