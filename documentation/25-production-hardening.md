# 25. Production Hardening

- Replace all sample secrets and keystore passwords.
- Use managed TLS (for example, certbot/ACME or cloud load balancer) and rotate certificates. Also verify the renewed certificate is actually being *served* — a renewal that copies a new file into place but fails to reload NGINX leaves the old certificate live until it expires, and every file-level check passes throughout. See [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md).
- Enable persistent databases for DMSS Archive Services and other stateful components.
- Configure Keycloak for production (HTTPS, hostname, external DB if needed).
- Tighten CORS in `config/config.js` and `config/constants.json` to explicit origins.
- Limit management/actuator exposure to internal networks.
- Consider placing the public NGINX behind a cloud or hardware load balancer.

---

