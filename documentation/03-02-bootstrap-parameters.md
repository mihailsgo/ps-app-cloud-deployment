# 3.2 Bootstrap parameters

| Parameter | Required | Description |
|---|---|---|
| `--host` | Yes | Hostname for the deployment (e.g., `padsign.client.com`) |
| `--company-role` | Yes | Company name / Keycloak realm role (e.g., `"Acme"`) |
| `--admin-pass` | Yes | Keycloak admin password (must be strong for production) |
| `--cert-crt` / `--cert-key` | No | TLS certificate files (or place in `installation-scripts/certs/`) |
| `--realm` | No | Keycloak realm name (default: `padsign`) |
| `--admin-user` | No | Keycloak admin username (default: `admin`) |
| `--users` | No | Additional users: `"user1:pass1:role,user2:pass2:role"` |
| `--enable-routing` | No | Enable filesystem document routing after signing |
| `--enable-demo` | No | Enable DEMO mode in client |
| `--enable-local-eseal` | No | Provision local e-sealing (stamping container + demo PKCS12) and set `STAMP_MODE=local`. External e-sealing remains the default when this flag is omitted. **Requires `mihailsgordijenko/ps-server:3.26` or newer** - earlier tags ignore the `STAMP_MODE` field. See [Enabling local e-sealing](04-enabling-local-e-sealing.md#4-enabling-local-e-sealing). |

