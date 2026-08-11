# 11.1 TLS Prerequisites (For Installation Scripts)

The installation scripts expect PEM files named after the hostname you pass in `--host`.

- Put certs here (source location):
  - `installation-scripts/certs/<host>.crt`
  - `installation-scripts/certs/<host>.key`
- The scripts copy them to (NGINX bind-mount location):
  - `nginx/certs/<host>.crt`
  - `nginx/certs/<host>.key`
- NGINX reads them inside the container from:
  - `/etc/nginx/certs/<host>.crt`
  - `/etc/nginx/certs/<host>.key`

Certificate file format expectations
- `<host>.crt` MUST be a PEM **fullchain** file: the leaf certificate first, followed by every intermediate CA certificate in chain order. NGINX serves this file as-is via a single `ssl_certificate` directive, so a leaf-only file will break TLS verification for clients that don't already trust the issuing CA via cached intermediates — including Keycloak's own backchannel JWKS fetch, which will silently break login even when browsers may appear to work.
- `<host>.key` must be a PEM private key.

Build a fullchain when your CA gave you separate files:

```bash
cat leaf.crt intermediate.crt [root.crt] > fullchain.crt
```

Let's Encrypt deployments already produce a fullchain at `/etc/letsencrypt/live/<host>/fullchain.pem` — pass that directly.

The bootstrap script validates the certificate before deploying by calling `installation-scripts/validate-certs.sh`. It checks file format, that the cert and key are the same keypair, expiry, hostname (CN / Subject Alternative Names), and chain completeness. For development with a self-signed cert pass `--allow-self-signed` to `bootstrap.sh` (skips chain check only — all other checks still run).

Password-protected private keys
- If the private key is encrypted (has `ENCRYPTED` in the PEM header), NGINX won't be able to start non-interactively.
- Recommended: convert it to an unencrypted key before running the scripts:

```bash
# Example for Let's Encrypt files:
cp /etc/letsencrypt/live/<host>/fullchain.pem installation-scripts/certs/<host>.crt
openssl pkey -in /etc/letsencrypt/live/<host>/privkey.pem -out installation-scripts/certs/<host>.key
```

If you intentionally want to keep an encrypted key, you need to extend `nginx/nginx.conf` with `ssl_password_file` and mount a password file into the container (not implemented by default).

1) Replace server_name and cert paths

- Edit `nginx/nginx.conf` and change:
  - `server_name` to your hostname, e.g. `example.yourdomain.com`.
  - `ssl_certificate` and `ssl_certificate_key` to your certificate files in `nginx/certs`.

2) Provide certificates

- Place your certificate and key files in `nginx/certs/`.
- Ensure file names match those referenced in `nginx/nginx.conf`.

Local option (Windows):

- Generate a local cert: `nginx/mkcert.exe example.local` and then point `ssl_certificate` and `ssl_certificate_key` to the generated files.

3) DNS or hosts entry

- Production: Point your domain's A/AAAA record to the host running this stack.
- Local: Add a hosts entry mapping your hostname to `127.0.0.1` (or the Docker host IP) and use a locally trusted cert.

---

