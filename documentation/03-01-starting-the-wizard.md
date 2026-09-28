# 3.1 Starting the wizard

This page takes you from a fresh host to the wizard's unlock screen in your browser. Run the
commands on the PadSign host as a user that can run `docker` without `sudo` (a member of the
`docker` group, see [2.1 Host and software](02-01-host-and-software.md)), except where `sudo` is shown.

## 1. Get the deployment package into /opt/padsign

TrustLynx tells you which release to install. Clone that release tag into `/opt/padsign`:

```bash
sudo mkdir -p /opt/padsign
sudo chown "$USER": /opt/padsign
git clone --branch <release-tag> https://gitlab.com/trustlynx-public/padsign-2.0.git /opt/padsign
```

Replace `<release-tag>` with the latest release tag TrustLynx gives you. If TrustLynx gave you a
different repository URL, use that one. Get both from TrustLynx support if you are not sure.

## 2. Start the wizard from /opt/padsign

```bash
cd /opt/padsign
docker compose --profile wizard up -d wizard
```

Always run this from `/opt/padsign`, never from another directory. The wizard mounts the
deployment directory at the same absolute path inside its container (`${PWD}:${PWD}` in
`docker-compose.yml`) and mounts the host's Docker socket. When it later runs `docker compose` for
you, the host's Docker daemon resolves the stack's relative bind mounts (`./config/config.js`,
`./signed-output`, ...) against that path. Started from another directory, the paths do not line up
and the install fails.

Do not start it with plain `sudo docker compose ...`: `sudo` drops the `PWD` environment variable
that `docker-compose.yml` uses for the wizard's mount.

The wizard only starts when you name its profile. A plain `docker compose up -d` never starts it.

## 3. Read the access token

```bash
docker logs padsign-wizard
```

The start-up banner looks like this:

```
========================================
PadSign Deployment Wizard
  Listening on https://<this-host>:8443
  Access token: 3f9a1c2e...
  (regenerated every container start — copy it into the browser to unlock)

  Certificate valid for:
    names: localhost, ...
    IPs:   127.0.0.1, ...
  ...
========================================
```

Copy the value after `Access token:`. A new token is generated every time the container starts.
Treat it like a password: anyone who has it and can reach port 8443 can run the installer.

## 4. Open an SSH tunnel and browse to the wizard

The wizard container publishes port 8443 on the host's loopback address only
(`"${WIZARD_BIND_ADDRESS:-127.0.0.1}:8443:8443"` in `docker-compose.yml`), so nothing on the network
can reach it. Reach it through SSH instead. On your workstation:

```bash
ssh -L 8443:localhost:8443 user@padsign.example.com
```

Leave that session open, then open this address in a browser on the same workstation:

```
https://localhost:8443
```

If port 8443 is already in use on your workstation, pick another local port, for example
`ssh -L 9443:localhost:8443 user@padsign.example.com` and `https://localhost:9443`.

The browser warns that the connection is not private. That is expected: the wizard serves its own
self-signed certificate, generated fresh on every start and used only for the wizard's own page. It
is not the PadSign certificate you upload later. Accept the warning (in Chrome: **Advanced** ->
**Proceed to localhost**) and continue with [3.2 Walkthrough](03-02-walkthrough.md).

## Reaching the wizard without a tunnel (WIZARD_BIND_ADDRESS)

The SSH tunnel is the recommended way in. If you must browse to the wizard directly at the host's
address, and only from a trusted admin network, publish its port on all interfaces by adding this
line to `.env` in `/opt/padsign` (create the file, mode 600, if it does not exist yet; the install
adds its own lines to it and keeps yours):

```bash
WIZARD_BIND_ADDRESS=0.0.0.0
```

You can also give one specific interface address of the host instead of `0.0.0.0`. The wizard holds
the host's Docker socket, and Docker-published ports bypass host firewalls such as `ufw`
([2.3 Network and firewall](02-03-network-and-firewall.md)), so restrict access to 8443 in a network
firewall in front of the host. While the wizard is published this way,
`validate-config.sh` reports a `WARN` for it
([5.2 Validating configuration](05-02-validating-configuration.md)).

`.env.example` in `/opt/padsign` lists this and every other variable `.env` can hold
([7.6 Environment variables](07-06-environment-variables.md)). Recreate the container to apply the
change, as shown at the end of the next section. Remove the line again, and recreate, to return to
loopback only.

## The wizard's certificate names (WIZARD_TLS_SANS)

The wizard's self-signed certificate always covers `localhost`, `127.0.0.1`, the container's own
hostname and IP addresses, and the `server_name` currently in `nginx/nginx.conf` (after the install,
that is your PadSign hostname).
The start-up banner lists the exact names and IPs under `Certificate valid for:`.

Through the SSH tunnel you browse to `localhost`, which is always covered, so you only see the
"untrusted issuer" warning that every browser lets you click through.

The container cannot see the host's own network address. If you reach the wizard directly at the
host's IP or DNS name instead of through the tunnel, the browser adds a name-mismatch error on top,
which some browsers, mobile ones in particular, will not let you bypass. To add that address to the
certificate, set `WIZARD_TLS_SANS` in `.env` in `/opt/padsign`, listing your names and IPv4
addresses, comma-separated (IPv6 addresses are ignored):

```bash
WIZARD_TLS_SANS=10.0.0.42,padsign-host.internal
```

Then recreate the container from `/opt/padsign` and read the new token:

```bash
docker compose --profile wizard up -d wizard
docker logs padsign-wizard
```

`.env` is not a tracked file, so neither setting gets in the way of an upgrade
([9.5 Upgrading](09-05-upgrading.md)).

## Stopping and restarting the wizard

PadSign does not need the wizard to keep running. Stop it when you have finished an install,
upgrade or settings change:

```bash
cd /opt/padsign
docker compose --profile wizard stop wizard
```

Start it again with `docker compose --profile wizard up -d wizard` from `/opt/padsign`, and read the
new token with `docker logs padsign-wizard`. The service has `restart: unless-stopped`, so if you
leave it running it also comes back after a host reboot.
