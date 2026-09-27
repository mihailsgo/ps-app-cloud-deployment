# 14.5 Support

Where to get help with a PadSign deployment, and what to send so the problem can be solved quickly.

## Help yourself first

- [12. Troubleshooting](12-troubleshooting.md) for problems with the running stack, and
  [3.4 Troubleshooting the wizard](03-04-troubleshooting-the-wizard.md) for the wizard.
- [13. FAQ](13-faq.md) for common questions.
- `./installation-scripts/validate-config.sh --host padsign.example.com` and
  `./installation-scripts/postdeploy-check.sh --host padsign.example.com` point at most
  configuration mistakes ([5. First login and verification](05-first-login-and-verification.md)).

## Contact TrustLynx support

Write to **[support@trustlynx.com](mailto:support@trustlynx.com)** for anything this
documentation does not solve: licences and release tags, image approvals, signing and e-sealing
certificates, and product defects. Report security vulnerabilities to the same address
([SECURITY.md](../SECURITY.md)); do not open a public issue for them. Include:

- the release tag you installed (`git -C /opt/padsign describe --tags`);
- what you did, what you expected and what happened;
- the exact command and its complete output, or the log from the wizard's **Copy log** button;
- a status snapshot: `./installation-scripts/monitor-status.sh --host padsign.example.com`;
- `docker compose ps` and the relevant service logs, for example
  `docker compose logs --tail 200 ps-server`.

Before you send anything, remove secrets from it: passwords, API keys, the Keycloak backend client
secret, private keys and the contents of `.env` or `config/config.js`. Never send a `*.bak` file;
it holds the same secrets as the file it backs up.

## Third-party documentation

- [Keycloak documentation](https://www.keycloak.org/documentation), including the
  [JavaScript adapter](https://www.keycloak.org/securing-apps/javascript-adapter)
- [Docker Engine installation](https://docs.docker.com/engine/install/)
- [Docker Compose documentation](https://docs.docker.com/compose/)
- [nginx documentation](https://nginx.org/en/docs/)
