# 24.3 SSL Certificates

Ensure SSL certificates are properly configured in nginx:

```nginx
ssl_certificate     /etc/nginx/certs/your-domain.crt;
ssl_certificate_key /etc/nginx/certs/your-domain.key;
```

`ssl_certificate` must point to a **fullchain** file — the leaf certificate followed by every
intermediate CA certificate, concatenated in order. A leaf-only file breaks TLS verification for
clients that don't already have the intermediate cached, including Keycloak's own backchannel
requests, even when browsers appear to work. See
[11.1 TLS Prerequisites](11-01-tls-prerequisites-for-installation-scripts.md) for how to build one,
and [11.2 Monitoring the Served Certificate](11-02-monitoring-the-served-certificate.md) to confirm
nginx is serving the current file.
