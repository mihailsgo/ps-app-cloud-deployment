# 7. Architecture

Services defined in `docker-compose.yml`:

- NGINX: Public entrypoint on ports 80/443; routes to backend services and Keycloak.
- Keycloak: Identity provider; exposed on port 8080 and proxied at `/auth` through NGINX.
- PS Client: SPA served by its own NGINX; proxied by the public NGINX at `/portal`.
- PS Server: Backend API consumed by PS Client; proxied by the public NGINX at `/api`.
- DMSS Container and Signature Services: PDF/container operations, signing flows, Smart-ID/Mobile-ID.
- DMSS Archive Services: Archive API; configured with in-memory DB by default.
- DMSS Archive Services Fallback: Filesystem-based fallback archive; stores files in `./docs`.

High-level routing:

- `https://<host>/portal/...` -> `ps-client`
- `https://<host>/auth/...` -> `keycloak`
- `https://<host>/api/...` -> `ps-server`
- `https://<host>/container/api/...` -> `dmss-container-and-signature-services`
- `https://<host>/archive/api/...` -> `dmss-archive-services` (fallback to `dmss-archive-services-fallback` as configured)

Diagrams:

- [34.1 Deployment and integration architecture](34-01-deployment-and-integration-architecture.md) — layered view with network boundaries
- [34.2 Signing and stamping execution flow](34-02-signing-and-stamping-execution-flow.md)
- [34.3 Very high-level component view](34-03-very-high-level-component-view.md) (also shown in [2. Overview](02-overview.md))
- [23. Data Flow](23-data-flow.md) — request and signing sequence diagrams
- [4.2 Architecture deep-dive](04-02-architecture-deep-dive.md) — e-sealing request paths, external vs local mode

---

