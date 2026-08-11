# 6.1 What validate-config checks

1. **File existence** - verifies `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, `docker-compose.yml` exist
2. **Syntax** - validates `constants.json` is valid JSON, `docker-compose.yml` passes `docker compose config`
3. **Feature checks** - `DOCUMENT_ROUTING` in config.js, `signed-output` volume mount in compose, `signed-output/` directory exists, nginx root→`/portal/` redirect
4. **Hostname consistency** (if `--host` provided) - verifies `server_name` in nginx, `KEYCLOAK_URL` in constants.json, and `auth-server-url` in config.js all match
5. **Image tags** - shows current ps-server and ps-client versions from docker-compose.yml, checks README release snapshot matches
6. **Running containers** (if Docker is available) - verifies running images match docker-compose.yml tags

---

