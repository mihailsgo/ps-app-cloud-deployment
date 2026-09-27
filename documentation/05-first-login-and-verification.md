# 5. First login and verification

Right after an install, whether with the wizard or with `bootstrap.sh`, work through these pages
in order. They take you from the first login to proof that the deployment signs documents.

1. [5.1 First login](05-01-first-login.md): open the portal and the Keycloak admin console, and get
   a user to log in with.
2. [5.2 Validating configuration](05-02-validating-configuration.md): `validate-config.sh`, the
   offline consistency and security check of every configuration file.
3. [5.3 Post-deploy checks](05-03-post-deploy-checks.md): `postdeploy-check.sh`, which adds live
   checks against the running stack (Keycloak, served configuration, API protection, TLS).
4. [5.4 Signing smoke test](05-04-signing-smoke-test.md): `signing-smoke.sh`, which signs one
   synthetic document as a real user without it reaching your routing destinations.

Run all commands on the host from `/opt/padsign`, as your operator account
([2.1 Host and software](02-01-host-and-software.md)). The examples use `padsign.example.com` and
the company role `Example Corp`; use your own values.

After that, harden the deployment for production: [6. Production hardening](06-production-hardening.md).

## Sub-sections

- [5.1 First login](05-01-first-login.md)
- [5.2 Validating configuration](05-02-validating-configuration.md)
- [5.3 Post-deploy checks](05-03-post-deploy-checks.md)
- [5.4 Signing smoke test](05-04-signing-smoke-test.md)
