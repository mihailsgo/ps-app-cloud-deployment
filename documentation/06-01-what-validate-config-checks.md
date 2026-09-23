# 6.1 What validate-config checks

1. **File existence** - verifies `config/config.js`, `config/constants.json`, `nginx/nginx.conf`, `docker-compose.yml` exist
2. **Syntax** - validates `constants.json` is valid JSON, `docker-compose.yml` passes `docker compose config`
3. **Feature checks** - `DOCUMENT_ROUTING` in config.js, `signed-output` volume mount in compose, `signed-output/` and `docs/` directories exist and are writable, nginx root→`/portal/` redirect
4. **Permission checks** - fails if `signed-output/` or `docs/` is world-writable (mode 777 or anything else granting "other" write); see [installation-scripts/lib/dir-permissions.sh](../installation-scripts/lib/dir-permissions.sh) for the least-privilege modes each one should have instead
5. **Hostname consistency** (if `--host` provided) - verifies `server_name` in nginx, `KEYCLOAK_URL` in constants.json, and `auth-server-url` in config.js all match
6. **Image tags** - shows current ps-server and ps-client versions from docker-compose.yml, checks they match the release snapshot in [1. Release Snapshot](01-release-snapshot.md)
7. **Image digest pinning** - fails unless every image in `release/approved-digests.json` is pinned `tag@sha256:digest` in docker-compose.yml with exactly the approved tag and digest, and unless every image docker-compose.yml references (profile-gated services included) has an entry in `release/approved-digests.json` - a tag-only pin, a changed digest, a relabelled tag, and an image nobody approved all fail. Offline; the registry side is `installation-scripts/check-digest-drift.sh`
8. **Running containers** (if Docker is available) - verifies running images match docker-compose.yml tags

---

