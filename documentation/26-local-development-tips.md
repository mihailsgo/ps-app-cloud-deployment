# 26. Local Development Tips

- Hosts entry: map your chosen hostname to 127.0.0.1.
- Certificates: use mkcert to create a locally trusted cert and point `nginx/nginx.conf` to it.
- Nginx reaches every internal service (including container/signature and archive)
  by Docker service name over the internal network — the same routing works
  identically on Windows, macOS, and Linux, and no `host.docker.internal` round-trip
  is involved. Ports 84/86 (and 8080) are still published to `127.0.0.1` for local
  host-side debugging (`curl http://localhost:86/...`), but nginx itself never uses
  them.

---

