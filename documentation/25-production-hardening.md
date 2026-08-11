# 25. Production Hardening

This is the consolidated pre-go-live security checklist. Related deep dives:
[22. Security and Route Protection](22-security-and-route-protection.md) (nginx
route lockdown) and [36.5 Security considerations](36-05-security-considerations.md)
(Deployment Wizard specifics).

Credentials and secrets:

- Replace all sample secrets and keystore passwords. The stack ships demo
  defaults on purpose so the demo "just works": the Keycloak admin password
  (`admin`, replaced by `bootstrap.sh --admin-pass`; changing it *later* is
  non-trivial — see [37.5](37-05-known-gaps-keycloak-admin-password-rotation.md))
  and, with local e-sealing, three `changeit` credentials (rotation recipe:
  [4.4, Step 4.5](04-04-existing-deployment-upgrade-an-already-deployed-instance.md)).
- Treat any secrets present in this repository as placeholders only; rotate them prior to deployment.
- Use strong generated secrets for the Keycloak backend client.
- Delete the demo `test` user before production use.

Network and TLS:

- Always use HTTPS in production (the stack terminates TLS in NGINX).
- Use managed TLS (for example, certbot/ACME or cloud load balancer) and rotate certificates. Also verify the renewed certificate is actually being *served* — a renewal that copies a new file into place but fails to reload NGINX leaves the old certificate live until it expires, and every file-level check passes throughout. See [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md).
- Restrict admin endpoints and the Keycloak admin console to trusted networks.
- Limit management/actuator exposure to internal networks.
- Tighten CORS in `config/config.js` and `config/constants.json` to explicit origins.
- Consider placing the public NGINX behind a cloud or hardware load balancer.

Operations:

- Enable persistent databases for DMSS Archive Services and other stateful components.
- Configure Keycloak for production (HTTPS, hostname, external DB if needed).
- Keep Keycloak and the other images updated.
- Regularly check authentication logs.
- Regularly back up the `keycloak_data` volume and any persistent stores you configure.

---
