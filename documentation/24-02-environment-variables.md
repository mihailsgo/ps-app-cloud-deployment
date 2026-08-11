# 24.2 Environment Variables

Environment variables are documented in
[17. Environment Variables](17-environment-variables.md).

For production, the one that matters most is the Keycloak admin password — set
it at install time via `bootstrap.sh --admin-pass` (changing it later is
non-trivial: [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md)). The
full pre-go-live checklist is [25. Production Hardening](25-production-hardening.md).
