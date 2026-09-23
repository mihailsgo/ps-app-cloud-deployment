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

Sign more than one document. A container-signature image that rewrites the
signing profile after its first use (24.3.0.43 through 24.3.3.9 did this to
`LocalDemo`) seals the first document after every restart and fails every
later one: the next `/api/stamp` hangs until nginx returns 504, after which
ps-server's stamp circuit breaker opens and stamps fail fast with
`503 STAMP_CIRCUIT_OPEN`. The documents stay unsealed in the archive. To
check the pinned images themselves without touching the running stack:

```bash
./installation-scripts/dmss-seal-smoke.sh     # isolated project, 3 consecutive seals
```

---

