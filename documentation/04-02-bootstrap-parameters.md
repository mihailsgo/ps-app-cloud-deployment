# 4.2 Bootstrap parameters

Every option `installation-scripts/bootstrap.sh` accepts. The same list is printed by
`./installation-scripts/bootstrap.sh --help`.

## Required

| Parameter | Description |
|---|---|
| `--host <name>` | Hostname users open PadSign at, for example `padsign.example.com`. Must match the TLS certificate. |
| `--company-role <name>` | Your company name. Becomes a Keycloak realm role that PadSign users are given, for example `"Example Corp"`. |
| `--admin-pass <password>` | Keycloak admin password. Instead of this flag, export `KEYCLOAK_ADMIN_PASSWORD` (see [4](04-install-from-the-command-line.md#3-run-bootstrap)): a flag is visible to every local user in `ps` for the whole run. Keycloak reads it only on its first start. It is stored in `.env` (mode 600) as `KEYCLOAK_FIRST_BOOT_ADMIN_PASSWORD`, never in `docker-compose.yml`. The script warns if it is `admin`. |

## Optional

| Parameter | Default | Description |
|---|---|---|
| `--cert-crt <file>` / `--cert-key <file>` | `installation-scripts/certs/<host>.crt` / `.key` | Full-chain certificate and unencrypted private key (PEM). |
| `--realm <name>` | `padsign` | Keycloak realm name. Keep the default: this option only names the realm in Keycloak, while `config/config.js`, `config/constants.json` and `config/keycloak.js` keep `padsign`, so another name also needs those three files edited by hand. |
| `--admin-user <name>` | `admin` (or `KEYCLOAK_ADMIN` if set) | Keycloak admin user name. |
| `--users "<user:pass:role>,..."` | none | Extra Keycloak users, comma-separated, each `username:password:role`. The role is optional and is created if it does not exist, for example `"alice:S3cret-1:padsign-admin,bob:S3cret-2:psapp-integration"`. Spaces are removed, so passwords cannot contain spaces, commas or colons. The passwords are on the command line (visible in `ps`); change them in the Keycloak admin console afterwards if that matters on your host. |
| `--enable-routing` | not passed | Turns on filesystem document routing: signed documents are saved under `signed-output/` ([11](11-document-routing-and-receive-back.md)). The shipped `config/config.js` already has routing and its `filesystem` strategy on, so the flag only matters for a `config.js` that has no `DOCUMENT_ROUTING` block or has it switched off. Leaving it out does not turn routing off; to do that, run `toggle-features.sh --disable-routing` after the install ([9.4](09-04-toggling-features.md)). |
| `--enable-demo` | off | Turns on demo mode in the client app. Not for production. |
| `--enable-local-eseal` | off | Sets up local e-sealing: the `dmss-digital-stamping-service` container with a demo seal keystore, and `STAMP_MODE: "local"`. The portal only requests a seal when `RUN_STAMPING_REQUEST` is `true` in `config/constants.json`, which the flag does not change; set it after the install ([10.3](10-03-fresh-install.md#after-bootstrap)). Without the flag, e-sealing uses the external e-sealing service ([10. Local e-sealing](10-local-e-sealing.md)). |
| `--allow-self-signed` | off | Skips the certificate chain check, for self-signed test certificates. The format, key-match, expiry and hostname checks still run. |
| `-h`, `--help` | | Prints the usage text and exits. |

Any other option stops the script with `ERROR: Unknown arg` (exit 2).

## Environment variables

| Variable | Used for |
|---|---|
| `KEYCLOAK_ADMIN_PASSWORD` | Admin password when `--admin-pass` is not given. The recommended way to pass it. |
| `KEYCLOAK_ADMIN` | Admin user name when `--admin-user` is not given. |

The feature flags can be changed after the install with `installation-scripts/toggle-features.sh`
([9.4 Toggling features](09-04-toggling-features.md)); you do not need to re-run bootstrap.
