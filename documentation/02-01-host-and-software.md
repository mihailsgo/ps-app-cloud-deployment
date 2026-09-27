# 2.1 Host and software

This page lists what the host needs before you install: operating system and size, Docker, the
command-line tools the installation scripts use, and the account you run them as.

## Operating system and CPU architecture

- **Linux**, 64-bit, any current distribution that Docker Engine supports (for example Ubuntu LTS,
  Debian, or a RHEL-compatible distribution). Windows and macOS are not deployment targets.
- **x86-64 (amd64).** The PadSign images are published for `linux/amd64` only, so ARM hosts
  (for example AWS Graviton or Ampere) cannot run the stack.
- A distribution with GNU userland. Minimal BusyBox-based systems such as Alpine are not suitable:
  the scripts use GNU `grep -P`.

## Sizing

| Resource | Recommended minimum |
|---|---|
| CPU | 4 vCPU |
| Memory | 6-8 GB RAM |
| Disk | 10 GB free for images, volumes and signed-document output, plus room for your document volume |

What runs: three Java (Spring Boot) DMSS services, a fourth when local e-sealing is enabled,
Keycloak (also Java), ps-server (Node.js) and two nginx containers. The Java services dominate
memory use and start-up time. On a cold start they all start together and take a few minutes to
report healthy.

Signed documents accumulate in `/opt/padsign/docs/` (the archive's file store) and, with filesystem
routing, in `/opt/padsign/signed-output/`. Size the disk for the number of documents you keep, and
back those directories up ([9.11](09-11-start-at-boot-backups-and-customized-hosts.md)).

## Docker Engine and Compose v2

Install Docker Engine and the Compose v2 plugin from Docker's own repositories, following the page
for your distribution:

- Install Docker Engine: <https://docs.docker.com/engine/install/>
- Linux post-installation steps (the `docker` group, start on boot):
  <https://docs.docker.com/engine/install/linux-postinstall/>

Docker's packages include `docker-compose-plugin`, which provides `docker compose`. Some
distribution-packaged Docker builds do not include it, and the old standalone `docker-compose` (v1)
does not work: the stack relies on Compose v2 features such as profiles. Use Docker Engine 20.10 or
newer; a current release is best. Docker Desktop is not needed.

Check both, and make sure the daemon starts at boot:

```bash
docker version
docker compose version        # must print "Docker Compose version v2..."
sudo systemctl enable --now docker
```

## Command-line tools

`bootstrap.sh` checks for `docker`, `awk`, `perl`, `python3`, `curl` and `openssl` and stops with
`ERROR: Missing dependency: <name>` if one is missing. You also need `git` and GNU `grep`:

| Tool | Used for |
|---|---|
| `bash` (4 or newer) | All installation scripts |
| `git` | Cloning the deployment package and upgrading it |
| `awk`, `perl` | Rewriting configuration files for your hostname and features |
| `python3` | JSON and YAML handling, secret checks, image digest checks |
| `curl` | Health and redirect checks |
| `openssl` | Certificate validation and TLS checks |
| GNU `grep` | Pattern matching with `grep -P` |

Most server distributions already have all of them. To install any that are missing:

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y git curl openssl perl python3 gawk grep

# RHEL, Rocky, AlmaLinux
sudo dnf install -y git curl openssl perl python3 gawk grep
```

Check:

```bash
for c in bash git awk perl python3 curl openssl docker; do
  command -v "$c" >/dev/null || echo "missing: $c"
done
echo x | grep -qP 'x' && echo "grep -P: OK"
```

Optional: `cosign` v3 or newer lets `validate-config.sh` verify the signatures of the PadSign images
([5.2 Validating configuration](05-02-validating-configuration.md#image-signatures)).

## The operator account

Run all installation and operations scripts from `/opt/padsign`, always as the same account: a
regular administrator account that can run `docker` without `sudo`.

```bash
sudo usermod -aG docker "$USER"     # then log out and back in
docker ps                           # must work without sudo

sudo mkdir -p /opt/padsign
sudo chown "$USER": /opt/padsign
```

Then clone the release into `/opt/padsign` as described in
[3.1 Starting the wizard](03-01-starting-the-wizard.md) or
[4. Install from the command line](04-install-from-the-command-line.md).

Things to know about this account:

- **Membership of the `docker` group is equivalent to root access on the host.** Give it only to the
  people who administer PadSign.
- **The scripts do not need `sudo`.** The directories containers write into (`docs/` and
  `signed-output/`) must belong to the uid each container runs as. When your account cannot change
  their owner itself, the scripts do it through a short-lived container of the same image.
- **Keep using the same account.** Backups the scripts write (`*.bak`, rollback snapshots) are
  readable by their owner only, so upgrades and rollbacks should run as the account that installed,
  or as root.
- **`config/config.js` holds secrets.** The scripts restrict it to mode 640 with the group the
  ps-server image runs as, but only when the account running them is root, has that image's uid, or
  is a member of that group. Otherwise they leave it readable, say so, and `validate-config.sh`
  warns. How to tighten it: [6. Production hardening](06-production-hardening.md#5-files-and-permissions).
- **Running the scripts as root also works.** `bootstrap.sh` then gives `.env` to the owner of
  `/opt/padsign`, so that account can still run `docker compose`. Do not start the Deployment Wizard
  with `sudo docker compose`; see [3.1](03-01-starting-the-wizard.md).
