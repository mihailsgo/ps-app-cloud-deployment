# 36.5 Security considerations

## This is the most privileged container in the stack

The wizard is the **first and only** service in this compose file that
mounts `/var/run/docker.sock`. That grants it root-equivalent access to the
host: anything that can reach the wizard's Docker socket can create
privileged containers, mount arbitrary host paths, and read or write
anything the Docker daemon can touch. This is a meaningfully bigger blast
radius than any other container this stack runs, and it's worth treating
that fact with the seriousness it deserves rather than as an implementation
detail.

## Where the actual boundary lives

Mounting the socket is what makes the wizard *useful* (it needs to run
`docker compose` on your behalf) — the mitigation isn't "don't mount the
socket," it's controlling **who can reach the wizard's port and who holds
its token**:

- Not internet-public, not bound to only `127.0.0.1` either — reachable at
  the host's address on the client's own network.
- HTTPS only (self-signed, regenerated every start — see
  [36.1 Concepts and access model](36-01-concepts-and-access-model.md)).
- A random access token, printed to `docker logs padsign-wizard`, required
  to unlock a session. No user/password database to compromise.
- Sessions expire after 2 hours of inactivity.

This is the same shape of control used by comparable tools (Portainer,
Jupyter's token-based first-run) for the same reason: the socket mount is
the capability, and the port+token pair is the gate in front of it.

## Practical recommendations

- **Stop it when you're not using it.** `docker compose stop wizard` once a
  deployment or upgrade is verified. `restart: unless-stopped` means it
  survives a host reboot by default — a reasonable default so the dashboard
  is there when you come back, but you can choose otherwise.
- **Treat the printed token like a credential** for as long as the
  container has been running — anyone who can read `docker logs` for this
  container can unlock it.
- **The Keycloak admin password is visible in the wizard container's
  process listing** for the duration of a bootstrap run — this is not a
  regression; it's exactly as visible as it already is when you run
  `bootstrap.sh --admin-pass ...` by hand from a shell.
- **A finished run's arguments stay in the wizard's memory** so the
  progress screen's **Retry** button can re-run the identical command
  without asking you to re-enter anything. For a bootstrap that includes
  the Keycloak admin password, held in the wizard process (never on disk,
  never in the session cookie, never logged) until the container stops.
  Stopping the wizard when you're done — which the first recommendation
  above already advises — clears it.
- **The mounted project directory also exposes `.git/`** (config, hooks, any
  cached credential helper) to the wizard container. This can't be cleanly
  carved out of a directory bind mount, and trying to isn't worth the
  effort: once socket access is granted, root-equivalent host access is
  already available regardless of what else is mounted alongside it.

## Not a new exposure for anything the CLI scripts already do

Everything the wizard does — writing config files, starting Keycloak,
running `docker compose pull/up` — is exactly what an operator running
`bootstrap.sh`/`upgrade.sh` by hand already does from a shell with the same
level of host access. The wizard doesn't grant new capabilities; it changes
*who* can trigger them (anyone with the token, from the browser) rather than
*what* they can do.
