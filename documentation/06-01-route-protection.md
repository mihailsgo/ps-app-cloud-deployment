# 6.1 Route protection

This page covers which routes nginx exposes, how each one is authenticated,
and how to put the DMSS archive and container APIs behind authentication at
nginx. You do not need to change the applications.

## What is exposed

All external traffic enters through nginx on port 443. Port 80 only
redirects to HTTPS. The routes in `nginx/nginx.conf`:

| Route | Goes to | Authentication |
|-------|---------|----------------|
| `/portal/` | ps-client (the SPA) | The SPA signs users in with Keycloak (public client `padsign-client`, Authorization Code flow) and sends `Authorization: Bearer <token>` to the API. |
| `/auth/` | Keycloak | Login, tokens, account and admin console. |
| `/api/` | ps-server | Depends on the endpoint. Integration endpoints (`/api/registerPDF`, `/api/registerUser`, `/api/registerUserPDF`, `/api/removeUser`, the receive-back `/api/signedPdf*`) take the API key ([7.5](07-05-register-pdf-api.md)). Portal endpoints take a Keycloak bearer token. |
| `/archive/api/` | `dmss-archive-services:8090` | **None by default.** |
| `/container/api/` | `dmss-container-and-signature-services:8092` | **None by default.** |

nginx reaches every service by Docker service name on the internal network.
The DMSS host ports (86, 84) and Keycloak (8080) are bound to `127.0.0.1`, and
ps-server and the fallback archive publish no host port. As a result, the
public ports 80 and 443 are the only way in. Enforce the same at your
firewall ([2.3](02-03-network-and-firewall.md)).

`/archive/api/` and `/container/api/` must stay reachable from inside the
stack, because ps-server calls them through `https://padsign.example.com/...`
(nginx's network alias). Outside callers should either be blocked or be
required to authenticate. The pattern below does that.

## The pattern

- `satisfy any; allow <docker-subnet>; deny all;` plus `auth_basic` on both
  locations. ps-server's internal traffic reaches nginx from the Docker
  subnet and passes on source IP alone. Every outside caller must send
  `Authorization: Basic ...`.
- The Docker subnet also contains the network's gateway address. Requests
  made on the host itself (for example `curl https://localhost/...` or an
  SSH tunnel) reach nginx from that gateway address, so `allow
  <docker-subnet>` lets them through without credentials. The blocks below
  add `deny <DOCKER_GATEWAY>;` before the `allow` to close that gap. Run the
  negative tests in *End-to-end test* from another machine either way.
- The document download route
  `GET /archive/api/document/{docid}/download` also accepts a Keycloak
  bearer token, because the pad browser downloads PDFs with the logged-in
  user's token. An `auth_request` check against Keycloak's `userinfo`
  endpoint handles that. `satisfy any` grants access if any one check
  passes.
- The credentials live in an `htpasswd` file in `nginx/certs/`, which is
  already mounted into the nginx container at `/etc/nginx/certs`.

### Check that the client is new enough first

An older ps-client fetches the download URL without a token, so closing the
route breaks its PDF viewer. The minimum ps-client tag is recorded in
`release/capabilities.json` as `closable-download-route`. Let `upgrade.sh`
check it, and refuse the upgrade, before you close the route:

```bash
# Check the ps-client you run now, without changing anything:
./installation-scripts/upgrade.sh --require-capability closable-download-route --plan-only

# Or upgrade and assert it in one go (<tag> = the approved ps-client tag, see 14.3):
./installation-scripts/upgrade.sh --client-tag <tag> --require-capability closable-download-route
```

The current approved tags are in [14.3 Release snapshot](14-03-release-snapshot.md).

## Steps

### 1. Create the credentials file

Run from the deployment directory. Use bcrypt, with one line per API user:

```bash
cd /opt/padsign
read -rs API_PW   # the password for api-user; nothing is echoed
printf '%s\n' "$API_PW" | docker run --rm -i httpd:2.4 htpasswd -niB api-user > nginx/certs/htpasswd
unset API_PW
sudo chgrp 101 nginx/certs/htpasswd && sudo chmod 640 nginx/certs/htpasswd
```

`-i` makes `htpasswd` read the password from standard input, so it never
appears on a command line (where `ps` would show it). For more users, run
the `htpasswd` line again with `>>` instead of `>`.

nginx's worker processes read this file on every request, and they run as
the image's `nginx` user, not as root. In the official nginx image that user
has uid and gid 101, hence the `chgrp 101`. With mode 640 and any other
group, the workers cannot read the file and every protected request fails
with `500`. To confirm the gid for the image you run:

```bash
docker compose exec nginx id nginx      # expect uid=101(nginx) gid=101(nginx)
```

The official `httpd:2.4` image is used here only to run `htpasswd`. Any
`htpasswd` (package `apache2-utils` / `httpd-tools`) works too.

### 2. Find the Docker subnet

The compose project is named after the deployment directory, so the
network is `padsign_default` for `/opt/padsign`:

```bash
docker network inspect padsign_default --format '{{(index .IPAM.Config 0).Subnet}}'
```

Use the result (for example `172.18.0.0/16`) as `<DOCKER_SUBNET>` below.
Also read the network's gateway address, which you deny explicitly:

```bash
docker network inspect padsign_default --format '{{(index .IPAM.Config 0).Gateway}}'
```

Use the result (for example `172.18.0.1`) as `<DOCKER_GATEWAY>` below.

### 3. Edit `nginx/nginx.conf`

In the `listen 443` server block, replace the `location /archive/api/` and
`location /container/api/` blocks with the four blocks below. The upstreams
are the ones the shipped file uses.

```nginx
    # Download route: ps-server (subnet), external systems (Basic auth)
    # or the pad browser (Keycloak Bearer token). A regex location, so it
    # wins over the /archive/api/ prefix below.
    location ~ ^/archive/api/document/[^/]+/download$ {
        satisfy any;
        deny <DOCKER_GATEWAY>;
        allow <DOCKER_SUBNET>;
        deny all;
        auth_basic "PadSign download API";
        auth_basic_user_file /etc/nginx/certs/htpasswd;
        auth_request /_kc_token;

        rewrite ^/archive/api/(.*)$ /api/$1 break;
        proxy_pass http://dmss-archive-services:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Token check for the route above: Keycloak answers 200 for a valid
    # user token and 401 otherwise.
    location = /_kc_token {
        internal;
        proxy_pass http://keycloak:8080/auth/realms/padsign/protocol/openid-connect/userinfo;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Authorization $http_authorization;
    }

    location /archive/api/ {
        satisfy any;
        deny <DOCKER_GATEWAY>;
        allow <DOCKER_SUBNET>;
        deny all;
        auth_basic "PadSign archive API";
        auth_basic_user_file /etc/nginx/certs/htpasswd;

        proxy_pass http://dmss-archive-services:8090/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /container/api/ {
        satisfy any;
        deny <DOCKER_GATEWAY>;
        allow <DOCKER_SUBNET>;
        deny all;
        auth_basic "PadSign container API";
        auth_basic_user_file /etc/nginx/certs/htpasswd;

        proxy_pass http://dmss-container-and-signature-services:8092/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

The download location uses `rewrite ... break` with a plain `proxy_pass`.
In a regex location, `proxy_pass` cannot carry a URI part, and a
`proxy_pass` built from variables would need a `resolver` directive.

### 4. Test and apply

```bash
docker compose exec nginx nginx -t && docker compose restart nginx
```

Use `restart`, not `nginx -s reload`. A reload can leave old workers serving
the previous configuration for a while.

`configure-host.sh` (run by `update-hostname.sh`, `renew-cert.sh` and
`toggle-features.sh`) rewrites only `server_name`, the certificate paths and
the `location /` redirect in this file, so it keeps your edits.

## End-to-end test

Archive and container routes (Basic auth):

```bash
HOST=https://padsign.example.com
curl -s -o /dev/null -w "no auth:   %{http_code}\n" $HOST/archive/api/document/create
curl -s -o /dev/null -w "bad auth:  %{http_code}\n" -u api-user:wrong $HOST/archive/api/document/create
curl -s -o /dev/null -w "good auth: %{http_code}\n" -u api-user $HOST/archive/api/document/create
```

Expect `401`, `401`, then anything **other** than `401`. This is a bare `GET`
on a `POST`-only path, so a `405` means nginx let the call through. Test
`/container/api/...` the same way.

Download route (use the ID of a document in your archive):

```bash
DOCID=<docid>
curl -s -o /dev/null -w "no creds:  %{http_code}\n" $HOST/archive/api/document/$DOCID/download
curl -s -o /dev/null -w "good auth: %{http_code}\n" -u api-user $HOST/archive/api/document/$DOCID/download
```

Expect `401`, then `200`. To test the pad browser's path, log in to the
portal, open the browser console (F12), run `copy(window.keycloak.token)`,
and then:

```bash
TOKEN=<pasted token>
curl -s -o /dev/null -w "token: %{http_code}\n" -H "Authorization: Bearer $TOKEN" $HOST/archive/api/document/$DOCID/download
```

Expect `200`. A `client_credentials` service-account token does not pass
this check, because `userinfo` requires a user token.

Finally, sign a document in the portal and check that the viewer still loads
the PDF.

## Other DMSS hardening

- **Archive JWT.** `dmss-archive-services` can validate a JWT itself: in
  `dmss-archive-services/application.yml`, set `authentication.jwt.enabled:
  true` and `validation: true`, and configure either `useCert: true` with a
  public key or certificate, or a `secret` of your own. The shipped `secret`
  is public, and `validate-config.sh` fails if JWT checking is enabled with
  it. Contact TrustLynx support before you enable this, because every caller
  must then send a valid token.
- **Header forwarding.** `dmss-container-and-signature-services` forwards
  `Authorization` and other headers to the archive. Align the archive's
  authentication with that behaviour.
- **Direct host ports.** The loopback-bound ports 84 and 86 bypass nginx.
  They are reachable only from the host itself (or an SSH tunnel), for
  diagnostics. With local e-sealing, container-signature's Basic-auth
  password also gates port 84
  ([6. Production hardening](06-production-hardening.md), #9).
