# 3. Install with the Deployment Wizard

The Deployment Wizard is a browser UI for installing PadSign. It is the recommended way to do a
first install. It checks your TLS certificate before anything is written, shows each install step
as it runs, and ends with a go-live checklist. After go-live the same wizard gives you a dashboard,
upgrades ([9.5 Upgrading](09-05-upgrading.md)) and post-go-live settings
([9. Operations](09-operations.md)).

The wizard runs the same installation scripts as the command-line install in
[4. Install from the command line](04-install-from-the-command-line.md). Both give the same result,
and you can use the CLI scripts on a host that was installed with the wizard, and the other way round.

## Before you start

- A Linux host that meets [2. Prerequisites](02-prerequisites.md), with Docker Engine and Compose v2.
- A DNS name for PadSign, for example `padsign.example.com`, and a TLS certificate (full chain) and
  unencrypted private key for it ([2.2 DNS and TLS certificates](02-02-dns-and-tls-certificates.md)).
  You upload both in the browser, so have them on the machine you browse from.
- SSH access to the host from your workstation. You reach the wizard through an SSH tunnel, so port
  8443 never has to be open to the network ([2.3 Network and firewall](02-03-network-and-firewall.md)).

## Sub-sections

- [3.1 Starting the wizard](03-01-starting-the-wizard.md)
- [3.2 Walkthrough](03-02-walkthrough.md)
- [3.3 How the wizard works](03-03-how-the-wizard-works.md)
- [3.4 Troubleshooting the wizard](03-04-troubleshooting-the-wizard.md)

When the wizard finishes, continue with [5. First login and verification](05-first-login-and-verification.md).
