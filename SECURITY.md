# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities in PadSign or in this deployment package to
**support@trustlynx.com**, with "SECURITY" in the subject line. Do not open a
public issue, merge request or discussion for a security problem.

Include what you found, the release tag you run (`git describe --tags`), the
steps to reproduce, and the impact you expect. Do not include real passwords,
keys or customer documents; describe them instead.

TrustLynx acknowledges the report and keeps you informed until it is
resolved. Please give us a reasonable time to fix the issue before you
disclose it.

## Supported versions

Security fixes are released for the latest release tag. Upgrade with
`installation-scripts/upgrade.sh` as described in
[9.5 Upgrading](documentation/09-05-upgrading.md).

## Hardening your deployment

A fresh install still carries demo defaults that must be changed before
production use. Work through
[6. Production hardening](documentation/06-production-hardening.md).
