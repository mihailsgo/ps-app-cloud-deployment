# 36.2 Starting the wizard

## Hard requirement: run this from the project root

```bash
cd /opt/psapp    # wherever this repo lives on your host
docker compose --profile wizard up -d wizard
```

You must `cd` into the project root first — do not run this from any other
directory. The wizard mounts the project directory into itself at the exact
same absolute path it lives at on the host (`${PWD}:${PWD}` in
`docker-compose.yml`), and it also mounts `/var/run/docker.sock` so it can
run `docker compose` commands of its own. Those two facts together mean:
when the wizard later runs `docker compose pull && docker compose up -d` on
your behalf, that command is actually executed by your **host's** Docker
daemon (via the mounted socket) — and the daemon needs the project directory
to be at the same path the wizard container sees, or it can't resolve the
stack's own relative bind mounts (`./config/config.js`, `./signed-output`,
etc.). Running the `up` command from anywhere other than the project root
breaks this alignment.

## Getting the access token

```bash
docker logs padsign-wizard
```

Look for a line like:

```
Access token: 3f9a1c2e...
```

It's regenerated every time the container starts. Copy it into the browser's
unlock screen.

## Opening the wizard

```
https://<this-host's-address>:8443
```

Port `8443` is not used by anything else in this stack. Accept the
self-signed certificate warning (see
[36.1 Concepts and access model](36-01-concepts-and-access-model.md) for why
that's expected).

## Stopping it

The wizard is not required to stay running. Once you've verified a
deployment and don't expect to run an upgrade soon:

```bash
docker compose stop wizard
```

Restart it (`docker compose --profile wizard up -d wizard`) whenever you
need it again — nothing about the deployment depends on it staying up.
