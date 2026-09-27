# 7.2 How configuration is loaded

Each configuration file is read at a different moment, so each one needs a
different step before a change takes effect. This page lists them.

## Mounts

The files are bind-mounted from the deployment directory into the
containers (see `docker-compose.yml`):

| Host file | Inside the container |
|-----------|----------------------|
| `./config/config.js` | `ps-server:/usr/src/app/config.js` |
| `./config/constants.json` | `ps-client:/usr/share/nginx/html/portal/constants.json` (read-only) |
| `./config/keycloak.js` | `ps-client:/usr/share/nginx/html/portal/keycloak.js` (read-only) |
| `./config/TLlogo.png` | `ps-client:/usr/share/nginx/html/portal/logo.png` (read-only) |
| `./nginx/nginx.conf` | `nginx:/etc/nginx/conf.d/default.conf` (read-only) |
| `./nginx/certs/` | `nginx:/etc/nginx/certs/` (read-only) |
| `./dmss-archive-services/` | `dmss-archive-services:/confs/` |
| `./dmss-container-and-signature-services/` | `dmss-container-and-signature-services:/confs/` |
| `./dmss-archive-services-fallback/` | `dmss-archive-services-fallback:/dmss-archive-services-fallback/` |
| `./dmss-digital-stamping-service/` | `dmss-digital-stamping-service:/conf/`, and its `seal/` at `/seal/` (both read-only; local e-sealing only) |
| `./signed-output/` | `ps-server:/signed-output/` |
| `./docs/` | `dmss-archive-services-fallback:/docs/` |

Because these are bind mounts, an edit on the host is visible in the
container at once. Whether the process picks it up depends on the file.

## When a change takes effect

| You changed | Takes effect | Command |
|-------------|--------------|---------|
| `config/constants.json` | After ps-client restarts, on the next page load in the browser. The SPA fetches `/portal/constants.json` with a cache-busting query on every load and merges it over its built-in defaults. | `docker compose restart ps-client`, then reload the portal page (on the tablet too). |
| `config/keycloak.js`, `config/TLlogo.png` | After ps-client restarts, on the next page load. | `docker compose restart ps-client`, then reload the portal page. |
| `config/config.js` | When ps-server restarts. Node reads the file once at startup and caches it. | `docker compose restart ps-server` |
| `nginx/nginx.conf`, a certificate in `nginx/certs/` | When nginx restarts. | `docker compose exec nginx nginx -t && docker compose restart nginx` |
| A DMSS `application.yml`, `documentsigningprofiles.json`, a keystore | When that service restarts. | `docker compose restart <service>` |
| `docker-compose.yml` (image, environment, ports, volumes) | When the container is recreated. A restart keeps the old definition. | `docker compose up -d <service>` (or `docker compose up -d` for all) |
| `.env` | When the affected containers are recreated. | `docker compose up -d` |

`config/constants.json`, `config/keycloak.js` and `config/TLlogo.png` are
single-file bind mounts. Many editors and tools save a file by writing a new
file and renaming it over the old one. The container then keeps serving the
old file until it restarts, so restart ps-client after every edit of these
files, even when the change looks as if it arrived without one.

`docker compose up -d` does **not** restart a container whose definition is
unchanged. After editing `config/config.js` you therefore need
`docker compose restart ps-server`. `up -d` alone does nothing for that file.

`KC_HOSTNAME` in `docker-compose.yml` is part of the keycloak container's
definition, so a hand edit needs `docker compose up -d keycloak`. The same
applies to the `KEYCLOAK_ADMIN*` variables, except that Keycloak only uses
those on its first boot against an empty volume
([8.3](08-03-admin-password-and-break-glass.md)).

## Checking what is loaded

- **Client:** open the browser's developer tools, **Network** tab, reload
  the portal and check that `/portal/constants.json` returns your values.
  The console also shows `Using runtime Keycloak config override from
  /portal/keycloak.js`.
- **Server:** ps-server logs its port, document folder and Keycloak realm at
  startup:

  ```bash
  docker compose logs --tail 50 ps-server
  ```

  To read one value as ps-server sees it:

  ```bash
  docker compose exec -T ps-server node -p 'require("/usr/src/app/config.js").ALLOWED_ORIGINS' </dev/null
  ```
