# 17.1 Keycloak Container Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `KEYCLOAK_ADMIN` | Admin username | `admin` |
| `KEYCLOAK_ADMIN_PASSWORD` | Admin password | `admin` |
| `KC_HOSTNAME` | Keycloak hostname | `padsign.trustlynx.com` |
| `KC_HTTP_RELATIVE_PATH` | Auth path | `/auth` |
| `KC_PROXY` | Proxy mode | `edge` |

> `KEYCLOAK_ADMIN_PASSWORD` is only read on Keycloak's **first** boot against an
> empty volume — see [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)
> for changing it on a live deployment.

