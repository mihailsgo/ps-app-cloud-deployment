# 14.1 Start Keycloak Container

The Keycloak container is defined in `docker-compose.yml`:

```yaml
keycloak:
  image: quay.io/keycloak/keycloak:26.3.2
  environment:
    - KEYCLOAK_ADMIN=admin
    - KEYCLOAK_ADMIN_PASSWORD=admin
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

> **Demo default — change before production.** `KEYCLOAK_ADMIN_PASSWORD=admin`
> is the out-of-the-box demo value; `bootstrap.sh --admin-pass` replaces it at
> install time. Note that Keycloak only reads this variable on its **first**
> boot against an empty volume — see
> [37.5 Known gap: Keycloak admin password rotation](37-05-known-gaps-keycloak-admin-password-rotation.md)
> for changing it later. Hardening checklist:
> [25. Production Hardening](25-production-hardening.md).

