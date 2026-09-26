# Docker DERP

Tailscale `derper` and `derpprobe` for Docker (`amd64` / `arm64`).

- [Custom DERP servers](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)
- [All server options](https://github.com/tailscale/tailscale/blob/main/cmd/derper/derper.go)
- Image: `ghcr.io/ack72/docker-derp` — `latest`, `1.102.4`, or `1.102.4-<run-id>.<attempt>` (unique build).

```sh
# Automatic Let's Encrypt certificate
docker run -d --name derp --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -p 80:80 -p 443:443 -p 3478:3478/udp \
  -v derp-data:/data \
  ghcr.io/ack72/docker-derp:latest \
  derper -hostname=derp.example.com \
    -c=/data/derper.key -certdir=/data/certs

# Existing certificate: host filenames can be anything
docker run -d --name derp --restart unless-stopped \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -p 80:80 -p 443:443 -p 3478:3478/udp \
  -v derp-data:/data \
  -v /path/to/fullchain.pem:/certs/derp.example.com.crt:ro \
  -v /path/to/privkey.pem:/certs/derp.example.com.key:ro \
  ghcr.io/ack72/docker-derp:latest \
  derper -hostname=derp.example.com -c=/data/derper.key \
    -certmode=manual -certdir=/certs

# Available options / monitoring
docker run --rm ghcr.io/ack72/docker-derp:latest derper -help
docker run --rm ghcr.io/ack72/docker-derp:latest derpprobe -help
```

Docker Compose with existing certificates (`compose.yaml`, then `docker compose up -d`):

```yaml
services:
  derp:
    image: ghcr.io/ack72/docker-derp:latest
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    sysctls:
      net.ipv4.ip_unprivileged_port_start: "0"
    ports:
      - "80:80"
      - "443:443"
      - "3478:3478/udp"
    volumes:
      - derp-data:/data
      - /path/to/fullchain.pem:/certs/derp.example.com.crt:ro
      - /path/to/privkey.pem:/certs/derp.example.com.key:ro
      # To verify clients, also uncomment -verify-clients below:
      # - /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock:ro
    command:
      - derper
      - -hostname=derp.example.com
      - -c=/data/derper.key
      - -certmode=manual
      - -certdir=/certs
      # - -verify-clients

volumes:
  derp-data:
```

Point the hostname at your server, allow TCP 80/443 and UDP 3478, and add it to your
[tailnet DERP map](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers).
The image runs as UID/GID **65532**: certificate files must be readable and `/data`
must be writable. Keep `/data` across updates. Inside the container, manual
certificates must be named `<hostname>.crt` (full chain) and `<hostname>.key`;
the certificate must cover that hostname. Recreate the container after renewing
individually bind-mounted certificate files.

To restrict access to your tailnet, run `tailscaled` on the host, add
`-v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock:ro`
before the image name, and add `-verify-clients` to the `derper` arguments.
The container user needs socket/WhoIs API access. Without verification, other
tailnets can use the server.

Dependabot checks Go, Docker and Actions daily. Merged updates and daily scheduled
builds publish images after both architectures pass security and runtime checks.

## NGINX

[Tailscale advises against HTTP proxies](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/derper/README.md#guide-to-running-cmdderper).
The examples below are optional, locally tested configurations; direct exposure
remains the upstream recommendation. Both assume NGINX runs on the Docker host.

### TCP passthrough (`stream`)

This preserves DERP's TLS and protocol handshake. Replace the Compose service's
`ports` with:

```yaml
ports:
  - "127.0.0.1:8080:80"
  - "127.0.0.1:8443:443"
  - "3478:3478/udp"
```

Keep the certificate mounts and `derper` arguments above. Enable NGINX's
[`stream` module](https://nginx.org/en/docs/stream/ngx_stream_core_module.html)
and add this block at the top level of `nginx.conf`, outside `http {}`:

```nginx
stream {
    proxy_connect_timeout 5s;
    proxy_timeout 1h;

    server {
        listen 80;
        listen [::]:80;
        proxy_pass 127.0.0.1:8080;
    }

    server {
        listen 443;
        listen [::]:443;
        proxy_pass 127.0.0.1:8443;
    }
}
```

This example reserves TCP 80/443 for DERP; existing HTTP/HTTPS listeners must use
other ports. TLS terminates in `derper`, so NGINX needs no certificate or
`listen ... ssl`. Keep UDP 3478 directly exposed for STUN; the TCP backend sees
the proxy's source address. Recreate the container with `docker compose up -d`,
then validate and reload NGINX with `nginx -t && nginx -s reload`.

### HTTP reverse proxy (shared 443, no `stream`)

Use a dedicated hostname alongside your existing websites. NGINX handles TLS
using your existing certificates; DERP listens on a private HTTP port. Replace
the Compose service's `ports`, `volumes` and `command` with these values (keep its
image and other settings, plus the top-level `derp-data` volume):

```yaml
ports:
  - "127.0.0.1:8080:8080"
  - "3478:3478/udp"
volumes:
  - derp-data:/data
command:
  - derper
  - -a=:8080
  - -hostname=derp.example.com
  - -c=/data/derper.key
  - -http-port=-1
```

Add the following inside NGINX's existing `http {}` context, replacing the domain
and certificate paths. Keep your existing certificate renewal configuration.

```nginx
map $http_upgrade $derp_connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name derp.example.com;

    location = /generate_204 {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name derp.example.com;
    ssl_certificate /path/to/fullchain.pem;
    ssl_certificate_key /path/to/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /debug { return 403; }
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $derp_connection_upgrade;
        proxy_set_header Derp-Fast-Start "";
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
```

Recreate the container, then run `nginx -t && nginx -s reload`. Keep UDP 3478
directly exposed and set the DERP map's `HostName` to `derp.example.com` (port 443).
This uses HTTP/1.1 Upgrade without DERP's TLS fast-start optimization; keep the
Upgrade headers. Tested with Tailscale 1.102.4 and NGINX 1.30.5; test again after
updates. The backend must remain private. To enable `-verify-clients`, also retain
the tailscaled socket mount.

## License

BSD 3-Clause. Based on [sparanoid/docker-derp](https://github.com/sparanoid/docker-derp)
and [Tailscale](https://github.com/tailscale/tailscale).
