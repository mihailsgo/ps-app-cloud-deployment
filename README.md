# PadSign deployment package

This repository installs and runs **PadSign 2.0**, TrustLynx's web-based PDF signing solution, on
your own Linux host with Docker Compose. It contains everything the stack needs at run time
(the compose file, configuration, nginx, Keycloak setup) and the scripts that install, upgrade,
validate and roll it back. The application itself ships as signed, digest-pinned Docker images.

## Install in five steps

The **Deployment Wizard** is the easiest way: a browser UI that checks your certificate, installs
the stack and shows live progress. Before you start, prepare the host, a DNS name and a TLS
certificate as described in [2. Prerequisites](documentation/02-prerequisites.md).

1. **Get the release** you were given by TrustLynx into `/opt/padsign`:

   ```bash
   sudo mkdir -p /opt/padsign && sudo chown "$USER": /opt/padsign
   git clone --branch <release-tag> https://gitlab.com/trustlynx-public/padsign-2.0.git /opt/padsign
   ```

2. **Start the wizard** from that directory:

   ```bash
   cd /opt/padsign && docker compose --profile wizard up -d wizard
   ```

3. **Copy the access token** from its start-up banner:

   ```bash
   docker logs padsign-wizard
   ```

4. **Open the wizard** through an SSH tunnel from your workstation, then browse to
   `https://localhost:8443`:

   ```bash
   ssh -L 8443:localhost:8443 <user>@<your-padsign-host>
   ```

5. **Follow the steps** in the browser: hostname, certificate, features, review, deploy. The full
   guide with screenshots is [3. Install with the Deployment Wizard](documentation/03-install-with-the-wizard.md).

**Prefer a terminal?** One script does the same install:
[4. Install from the command line](documentation/04-install-from-the-command-line.md)
(`installation-scripts/bootstrap.sh`).

**After the install**, log in and check the deployment
([5. First login and verification](documentation/05-first-login-and-verification.md)), then work
through [6. Production hardening](documentation/06-production-hardening.md) before real use.

## Documentation

1. [Overview](documentation/01-overview.md)
   - [1.1 Architecture](documentation/01-01-architecture.md)
   - [1.2 How signing works](documentation/01-02-how-signing-works.md)
2. [Prerequisites](documentation/02-prerequisites.md)
   - [2.1 Host and software](documentation/02-01-host-and-software.md)
   - [2.2 DNS and TLS certificates](documentation/02-02-dns-and-tls-certificates.md)
   - [2.3 Network and firewall](documentation/02-03-network-and-firewall.md)
3. [Install with the Deployment Wizard](documentation/03-install-with-the-wizard.md) (recommended)
   - [3.1 Starting the wizard](documentation/03-01-starting-the-wizard.md)
   - [3.2 Walkthrough](documentation/03-02-walkthrough.md)
   - [3.3 How the wizard works](documentation/03-03-how-the-wizard-works.md)
   - [3.4 Troubleshooting the wizard](documentation/03-04-troubleshooting-the-wizard.md)
4. [Install from the command line](documentation/04-install-from-the-command-line.md)
   - [4.1 What bootstrap does](documentation/04-01-what-bootstrap-does.md)
   - [4.2 Bootstrap parameters](documentation/04-02-bootstrap-parameters.md)
5. [First login and verification](documentation/05-first-login-and-verification.md)
   - [5.1 First login](documentation/05-01-first-login.md)
   - [5.2 Validating configuration](documentation/05-02-validating-configuration.md)
   - [5.3 Post-deploy checks](documentation/05-03-post-deploy-checks.md)
   - [5.4 Signing smoke test](documentation/05-04-signing-smoke-test.md)
6. [Production hardening](documentation/06-production-hardening.md)
   - [6.1 Route protection](documentation/06-01-route-protection.md)
7. [Configuration reference](documentation/07-configuration-reference.md)
   - [7.1 Essentials](documentation/07-01-essentials.md)
   - [7.2 How configuration is loaded](documentation/07-02-how-configuration-is-loaded.md)
   - [7.3 Client: config/constants.json](documentation/07-03-client-constants-json.md)
   - [7.4 Server: config/config.js](documentation/07-04-server-config-js.md)
   - [7.5 The /api/registerPDF integration API](documentation/07-05-register-pdf-api.md)
   - [7.6 Environment variables and .env](documentation/07-06-environment-variables.md)
8. [Keycloak](documentation/08-keycloak.md)
   - [8.1 Automated setup](documentation/08-01-automated-setup.md)
   - [8.2 Token audience for introspection](documentation/08-02-token-audience.md)
   - [8.3 Admin password and break-glass recovery](documentation/08-03-admin-password-and-break-glass.md)
   - [8.4 Manual setup (fallback only)](documentation/08-04-manual-setup.md)
9. [Operations](documentation/09-operations.md)
   - [9.1 Changing the hostname](documentation/09-01-changing-hostname.md)
   - [9.2 Renewing the TLS certificate](documentation/09-02-renewing-the-tls-certificate.md)
   - [9.3 Monitoring the served certificate](documentation/09-03-monitoring-the-served-certificate.md)
   - [9.4 Toggling features](documentation/09-04-toggling-features.md)
   - [9.5 Upgrading](documentation/09-05-upgrading.md)
   - [9.6 What upgrade does](documentation/09-06-what-upgrade-does.md)
   - [9.7 Previewing upgrade changes](documentation/09-07-previewing-upgrade-changes.md)
   - [9.8 Rollback](documentation/09-08-rollback.md)
   - [9.9 Health checks and startup](documentation/09-09-health-checks-and-startup.md)
   - [9.10 Monitoring and alerting](documentation/09-10-monitoring-and-alerting.md)
   - [9.11 Start at boot, backups and customized hosts](documentation/09-11-start-at-boot-backups-and-customized-hosts.md)
10. [Local e-sealing](documentation/10-local-e-sealing.md)
    - [10.1 Concepts and glossary](documentation/10-01-concepts-and-glossary.md)
    - [10.2 Architecture](documentation/10-02-architecture.md)
    - [10.3 Fresh install](documentation/10-03-fresh-install.md)
    - [10.4 Existing deployment](documentation/10-04-existing-deployment.md)
    - [10.5 Switching modes](documentation/10-05-switching-modes.md)
    - [10.6 Production key and certificate](documentation/10-06-production-key-and-certificate.md)
    - [10.7 Adding a signing profile](documentation/10-07-adding-a-signing-profile.md)
    - [10.8 TSA and OCSP for LT and LTA](documentation/10-08-tsa-and-ocsp-for-lt-and-lta.md)
    - [10.9 Verifying it works](documentation/10-09-verifying-it-works.md)
    - [10.10 Verifying signatures end-to-end](documentation/10-10-verifying-signatures-end-to-end.md)
11. [Document routing and receive-back](documentation/11-document-routing-and-receive-back.md)
12. [Troubleshooting](documentation/12-troubleshooting.md)
    - [12.1 Common issues](documentation/12-01-common-issues.md)
13. [FAQ](documentation/13-faq.md)
    - [13.1 How are many documents sent at (almost) the same time handled?](documentation/13-01-many-documents-at-once.md)
    - [13.2 What happens if ps-server is unavailable when `registerPDF` is called?](documentation/13-02-ps-server-unavailable.md)
    - [13.3 How are repeated or parallel processing of the same document handled?](documentation/13-03-repeated-and-parallel-processing.md)
    - [13.4 What software is used on the tablets?](documentation/13-04-tablet-software.md)
    - [13.5 What is the integration flow from a third-party system, and what comes back after signing?](documentation/13-05-third-party-integration-flow.md)
    - [13.6 What is the format of the signed document, and how do the signature and seal appear?](documentation/13-06-signed-document-format.md)
14. [Reference](documentation/14-reference.md)
    - [14.1 File map](documentation/14-01-file-map.md)
    - [14.2 Deployment and integration architecture](documentation/14-02-deployment-and-integration-architecture.md)
    - [14.3 Release snapshot](documentation/14-03-release-snapshot.md)
    - [14.4 AI agent deployment skill](documentation/14-04-ai-agent-deployment-skill.md)
    - [14.5 Support](documentation/14-05-support.md)
    - [14.6 Image approval and digest pinning](documentation/14-06-image-approval-and-digest-pinning.md)

Release notes: [CHANGELOG.md](CHANGELOG.md).
