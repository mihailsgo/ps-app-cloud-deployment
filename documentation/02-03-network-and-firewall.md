# 2.3 Network and firewall

This page lists which ports PadSign uses on the host, which of them must be reachable from the
network, and which outbound connections the host needs. The port bindings come from
`docker-compose.yml`.

## Inbound

| Port | Service | Open to | Purpose |
|---|---|---|---|
| 443/tcp | nginx | Signers' tablets and browsers, integrations (Virtual Printer, Manager, API clients) | Everything: portal, API, login |
| 80/tcp | nginx | Same as 443 | Redirects to HTTPS. Also the Let's Encrypt HTTP challenge if you use it ([2.2](02-02-dns-and-tls-certificates.md)) |
| 22/tcp | SSH | Administrators only | Administration, and the tunnel to the Deployment Wizard |
| 8443/tcp | wizard | **Nobody.** Keep it closed | Deployment Wizard, reached through an SSH tunnel |

The wizard publishes port 8443 on all of the host's interfaces while it runs. Do not open it in any
firewall. Reach it through SSH from your workstation instead:

```bash
ssh -L 8443:localhost:8443 user@padsign.example.com
# then browse to https://localhost:8443
```

Details: [3.1 Starting the wizard](03-01-starting-the-wizard.md).

## Ports bound to loopback or not published

These are not reachable from the network and need no firewall rule:

| Service | Host binding | Inside the Docker network |
|---|---|---|
| Keycloak | `127.0.0.1:8080` | 8080 |
| dmss-archive-services | `127.0.0.1:86` | 8090 |
| dmss-container-and-signature-services | `127.0.0.1:84` | 8092 |
| ps-server | none | 3001 |
| ps-client | none | 80 |
| dmss-archive-services-fallback | none | 8095 |
| dmss-digital-stamping-service (local e-sealing only) | none | 8084 |

The loopback ports are there for diagnostics run on the host itself. To use one from your
workstation, tunnel it, for example `ssh -L 8080:localhost:8080 user@padsign.example.com`. The
stamping service deliberately has no host port, so it never collides with a USB-token signing
service that may already listen on host port 8084.

`validate-config.sh` fails if any service other than `nginx` and `wizard` is published on a
non-loopback interface ([5.2 Validating configuration](05-02-validating-configuration.md)).

## Ports that must be free on the host

Before installing, make sure nothing else listens on 80, 443, 8080, 84 or 86 (and 8443 when you use
the wizard):

```bash
sudo ss -ltnp | grep -E ':(80|443|8080|84|86|8443)\b'
```

No output means they are free.

## Docker and host firewalls

Docker publishes container ports by adding its own packet-filtering rules, and traffic to published
ports does not pass through the input rules of host firewalls such as `ufw` or `firewalld`. A
`ufw deny 8443` does not close the wizard's port. Enforce the table above in a network firewall in
front of the host (for example a cloud security group), or with rules in Docker's `DOCKER-USER`
chain. See Docker's documentation:
<https://docs.docker.com/engine/network/packet-filtering-firewalls/>.

## Outbound

The host needs outbound HTTPS (443/tcp) to:

| Destination | Why |
|---|---|
| Docker Hub and `quay.io` | Pulling the images (PadSign, DMSS and nginx from Docker Hub; Keycloak from `quay.io`) during install and upgrade |
| The repository you cloned from | `git pull` during upgrades |
| The external e-sealing service (`STAMP_API_URL` in `config/config.js`) | E-sealing in external mode, the default |
| Trust services used by `dmss-container-and-signature-services` | Trust lists (downloaded at start-up), OCSP responders and time-stamping authorities, as configured in its `application.yml` |
| Your webhook endpoints | Document routing webhooks, if you configure them ([11](11-document-routing-and-receive-back.md)) |
| Let's Encrypt | Certificate issuance and renewal, if you use it |

If outbound traffic must go through a proxy, configure it for the Docker daemon so pulls work
(<https://docs.docker.com/engine/daemon/proxy/>). The DMSS signature service has its own proxy
settings in `dmss-container-and-signature-services/application.yml`; contact TrustLynx support if
you need them.

## Docker network address range

The stack runs on one Docker bridge network whose subnet Docker chooses from its default pools
(usually in `172.16.0.0/12`). If that range overlaps a network your users or integrations are on,
replies to them are routed into Docker instead. Set `default-address-pools` in
`/etc/docker/daemon.json` to a free range before the first install.
