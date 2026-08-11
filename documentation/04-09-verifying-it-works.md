# 4.9 Verifying it works

After bootstrap or upgrade with `--enable-local-eseal`:

```bash
docker compose ps | grep dmss-digital-stamping-service       # should show Up

# Stamping is reachable inside the docker network from container-signature
docker exec dmss-container-and-signature-services \
    bash -c 'exec 3<>/dev/tcp/dmss-digital-stamping-service/8084 && echo OK'

# The demo cert resolves end-to-end
docker exec dmss-container-and-signature-services curl -fsS \
    http://dmss-digital-stamping-service:8084/api/signing/certificate/for/TrustLynx \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('cert[:80]:', d['cert'][:80])"
# expected: cert[:80]: 308203ec308202d4a003020102...

# Sign a demo PDF through the SPA (RUN_STAMPING_REQUEST=true in constants.json)
# and confirm:
docker compose logs ps-server | grep -E '\[stamp\] mode=local'
docker compose logs ps-server | grep -E 'Stamp response status: 200'
```

Download the latest archived version of the signed document and confirm the
PDF contains a signature dictionary (`/Type /Sig` + `/Filter /Adobe.PPKLite`).

---

