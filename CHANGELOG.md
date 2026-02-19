# Changelog

## v1.0.3

- Updated deployment image tag to `ps-client:8.33` in `docker-compose.yml`.
- Updated `README.md` release snapshot references to `ps-client:8.33`.

## v1.0.2

- Updated deployment docs to use `ps-client:8.23`.
- Aligned release snapshot references in `README.md` with `docker-compose.yml`.

## v1.0.1

- Updated release snapshot and compose image references to:
- `ps-server:3.8`
- `ps-client:8.8`
- Updated documentation for newly added client translation/config keys in `config/constants.json`:
- Workflow popup labels and countdown text (`WF_*`, `WF_REFRESH_COUNTDOWN`)
- Stage-specific signing errors (`ERROR_VISUAL_SIGNATURE`, `ERROR_STAMP_RESPONSE`)
- Localized signature payload labels (`SIGNATURE_LABEL_SIGNER`, `SIGNATURE_LABEL_DATE`)

## v1.0.0

- Initial public repository setup
- Comprehensive deployment guide in `README.md`
- Added Security & Route Protection and Data Flow diagrams
- Docker Compose stack: NGINX, Keycloak, PS client/server, DMSS services
- Sensible `.gitignore` to avoid committing certs/keystores and temp data
