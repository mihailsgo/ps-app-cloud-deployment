# 14.1 Start Keycloak Container

The Keycloak container is defined in `docker-compose.yml`:

```yaml
keycloak:
  image: quay.io/keycloak/keycloak:26.7.4
  environment:
    - KEYCLOAK_ADMIN=admin
    - KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD:-admin}
    - KC_HOSTNAME=<host>
    - KC_HTTP_RELATIVE_PATH=/auth
    - KC_PROXY=edge
    - KC_HOSTNAME_STRICT=false
    - KC_HOSTNAME_STRICT_HTTPS=false
    - KC_PROXY_HEADERS=xforwarded
  command: start-dev
  ports:
    - "8080:8080"
  restart: unless-stopped
  volumes:
    - keycloak_data:/opt/keycloak/data
```

> **Demo default - change before production.** `admin` is the out-of-the-box
> demo value, used when `.env` does not set `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`.
> `bootstrap.sh` writes the password you give it into `.env` (git-ignored,
> mode 600), never into the tracked `docker-compose.yml`: see
> [17.1](17-01-keycloak-container-environment-variables.md), which also moves
> an inline value an older bootstrap left there. Note that Keycloak only reads
> this variable on its **first** boot against an empty volume - see
> [37.5 Known gap: Keycloak admin password rotation](37-05-known-gaps-keycloak-admin-password-rotation.md)
> for changing it later. Hardening checklist:
> [25. Production Hardening](25-production-hardening.md).

