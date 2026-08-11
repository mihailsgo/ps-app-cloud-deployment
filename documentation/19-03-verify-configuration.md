# 19.3 Verify Configuration

Check these URLs are accessible:

- Keycloak admin: `https://<host>/auth/` — expect the Keycloak welcome/admin page (HTTP `200`)
- Application: `https://<host>/portal/` — expect a redirect to the Keycloak login page

For a scripted check of config consistency, run
`./installation-scripts/validate-config.sh --host <host>`
(see [6. Validating Configuration](06-validating-configuration.md)).
