# 20.1 Common Issues

## 0. Browser shows `Failed to load module script` for `/portal/keycloak.js`

**Cause**: `/portal/keycloak.js` is missing, and NGINX serves `index.html` (`text/html`) instead of JS.

**Solution**:
1. Ensure `config/keycloak.js` exists.
2. Ensure compose mount exists in `ps-client`:
   - `./config/keycloak.js:/usr/share/nginx/html/portal/keycloak.js:ro`
3. Recreate `ps-client`:
   - `docker compose up -d ps-client`
4. Hard refresh browser (`Ctrl+F5`) or test in Incognito.

## 1. "Invalid redirect URI" Error

**Cause**: Redirect URI doesn't match Keycloak client configuration

**Solution**:
1. Check Keycloak client settings
2. Ensure URIs in `constants.json` match Keycloak configuration
3. Verify domain name is correct

## 2. CORS Errors

**Cause**: Web origins not configured properly

**Solution**:
1. Add your domain to "Web Origins" in Keycloak client
2. Include both with and without trailing slash

## 3. Authentication Fails

**Cause**: Client secret mismatch or configuration error

**Solution**:
1. Verify the backend client secret in `config/config.js` (`KEYCLOAK_CONFIG.credentials.secret`)
2. Check realm name matches (`padsign`)
3. Ensure client IDs are correct (`padsign-client`, `padsign-backend`)

## 4. Port conflicts — containers won't start

**Cause**: Another process already holds one of the host ports the stack binds — 80, 443
(all interfaces), or 8080/84/86 (loopback only; ps-server 3001 and the DMSS fallback
service 93 no longer bind a host port at all — see [22. Security and Route Protection](22-security-and-route-protection.md)).

**Solution**:
1. Find the holder: `sudo ss -ltnp | grep -E ':(80|443|8080|84|86)\b'`
2. Stop the conflicting service, or change the published port in `docker-compose.yml`.

## 5. TLS / hostname mismatch

**Cause**: `server_name` in nginx, the certificate CN/SANs, and the application URLs don't all agree.

**Solution**:
1. Run `./installation-scripts/validate-config.sh --host <host>` — it checks hostname consistency across nginx, `constants.json` and `config.js`.
2. Align `server_name`, certificate CN/SANs, and all application URLs with your actual hostname — see [11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md).
3. Self-signed certificate warnings: trust the local root (mkcert) or install a valid certificate.
4. Certificate renewed but the browser still shows the old one: see [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md).

## 6. Container Communication Issues

**Cause**: A service can't reach another (e.g. ps-server → DMSS). Usually a container is down, still starting, or misconfigured — genuine Docker-network faults are rare.

**Solution**:
1. `docker compose ps` — every service should be `Up`.
2. Read the logs of both sides of the failing call: `docker compose logs -f <service>`.
3. Test connectivity from inside the network, e.g. `docker compose exec keycloak ping ps-server`.
4. DMSS specifically: review `dmss-container-and-signature-services/application.yml` for endpoints and modes (TEST vs PROD), and check that truststores and referenced files exist under `dmss-container-and-signature-services/`.

## 7. Keycloak errors or broken login despite a certificate that "looks fine" in the browser

**Cause**: The supplied `<host>.crt` contains only the leaf certificate, not the full chain (missing intermediate CA certificates). NGINX serves the file as-is via a single `ssl_certificate` directive, so a browser that already trusts/caches the intermediate can look fine while Keycloak's own backchannel requests (e.g. its JWKS fetch) fail TLS verification and login breaks.

**Solution**:
1. Run `./installation-scripts/validate-certs.sh --host <host> --cert-crt <path> --cert-key <path>` — it counts PEM certificate blocks and verifies the chain, failing with a clear message when intermediates are missing. `bootstrap.sh` also runs this automatically before starting any container.
2. Build a fullchain file (leaf + intermediates, in order) — see [11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md) for the exact `cat leaf.crt intermediate.crt > fullchain.crt` recipe and the Let's Encrypt shortcut.
3. Re-run with the corrected fullchain file as `--cert-crt`.

## 8. `docs/` directory permission errors even after `bootstrap.sh`/`upgrade.sh` ran

**Cause**: `bootstrap.sh` and `upgrade.sh` run `mkdir -p docs && chmod 777 docs`, but if Docker already auto-created `docs/` as root on an earlier `docker compose up` (or the mount predates upgrading to v1.0.10+), a non-root operator's `chmod` silently no-ops — the script still reports success, and `docs/` stays writable only by root.

**Solution**:
1. Check ownership: `ls -ld docs/` — if it's owned by `root` and you're not running as root, that's the cause.
2. Fix with: `sudo chown $(id -u):$(id -g) docs/` or `sudo chmod 777 docs/`.
3. Re-run `./installation-scripts/validate-config.sh --host <host>` to confirm it reports `docs directory exists and is writable`.

## General debug commands

```bash
docker compose logs keycloak
docker compose logs ps-server
docker compose logs nginx
curl https://<host>/auth/realms/padsign/.well-known/openid-configuration
```
