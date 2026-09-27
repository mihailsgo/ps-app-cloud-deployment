# 16.1 Update Server Config

ps-server reads its Keycloak settings from `KEYCLOAK_CONFIG` in `config/config.js`. `keycloak-bootstrap.sh` fills it in for you; for a manual setup, set it like this:

```javascript
module.exports = {
  // ... other config
  KEYCLOAK_CONFIG: {
    realm: "padsign",
    "auth-server-url": "https://<host>/auth",
    resource: "padsign-backend",
    credentials: {
      secret: "<padsign-backend client secret>"
    },
    "bearer-only": true
  }
};
```

- `resource` is the backend client from [14.6](14-06-create-client-for-backend-manual.md), and `secret` is its client secret from the **Credentials** tab.
- The key must be `KEYCLOAK_CONFIG`. A `keycloak: { ... }` block is ignored, and ps-server then rejects every portal call.
- `config/config.js` is bind-mounted, so apply the change with `docker compose restart ps-server` (Node caches the file; `up -d` alone does not re-read it).
