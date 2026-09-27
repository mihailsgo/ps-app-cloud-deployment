# 2. Prerequisites

Prepare these before you start either install path ([3. Deployment Wizard](03-install-with-the-wizard.md)
or [4. Command line](04-install-from-the-command-line.md)). Both paths need exactly the same host.

## Checklist

- [ ] A 64-bit x86 (amd64) Linux host with at least 4 vCPU, 6-8 GB RAM and 10 GB free disk
      ([2.1](02-01-host-and-software.md)).
- [ ] Docker Engine with the Compose v2 plugin: `docker compose version` works ([2.1](02-01-host-and-software.md)).
- [ ] `git`, `bash`, `awk`, `perl`, `python3`, `curl`, `openssl` and GNU `grep` installed
      ([2.1](02-01-host-and-software.md)).
- [ ] An operator account that can run `docker` without `sudo`, and `/opt/padsign` owned by it
      ([2.1](02-01-host-and-software.md)).
- [ ] A DNS name for PadSign, for example `padsign.example.com`, pointing at the host
      ([2.2](02-02-dns-and-tls-certificates.md)).
- [ ] A TLS certificate for that name as a full-chain PEM file, with its unencrypted PEM private key
      ([2.2](02-02-dns-and-tls-certificates.md)).
- [ ] Ports 80 and 443 free on the host and reachable by your users; port 8443 closed to the network
      ([2.3](02-03-network-and-firewall.md)).
- [ ] Outbound HTTPS from the host to Docker Hub, `quay.io` and the signing trust services
      ([2.3](02-03-network-and-firewall.md)).
- [ ] The release tag to install, from TrustLynx.
- [ ] Your company name as it should appear as the Keycloak company role (for example `Example Corp`),
      and a strong password for the Keycloak admin account.

## Sub-sections

- [2.1 Host and software](02-01-host-and-software.md)
- [2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md)
- [2.3 Network and firewall](02-03-network-and-firewall.md)
