# Matrix Synapse — Podman LXC Deployment

Self-hosted Matrix homeserver running in an unprivileged Proxmox LXC container with Podman. All traffic routes through Cloudflare Tunnel (cloudflared) — no open ports required.

## Architecture

```
Internet
  │
  ▼
Cloudflare (DNS + TLS termination)
  │
  ▼ (tunnel)
cloudflared (on NPM LXC)
  │
  ▼
Nginx Proxy Manager (NPM)
  │
  ├── matrix.example.com ──► Matrix LXC :8008 (Synapse)
  └── chat.example.com   ──► Matrix LXC :8080 (Element Web)
```

Stack containers inside the Matrix LXC:

| Container   | Image                              | Port        | Role                  |
|-------------|------------------------------------|-----------  |-----------------------|
| postgres_db | postgres:18-alpine                 | 5432 (int)  | Database              |
| redis       | redis:8-alpine                     | 6379 (int)  | Cache / pub-sub       |
| synapse     | ghcr.io/element-hq/synapse:latest  | 8008        | Homeserver            |
| element-web | vectorim/element-web:latest        | 8080        | Web client            |

Ports marked `(int)` are internal to the Podman network only.


## Prerequisites

- Proxmox VE host
- NPM LXC with cloudflared already configured
- Two DNS records in Cloudflare (see DNS Setup below)
- A domain managed through Cloudflare


## Step 1 — Run the Script

Edit the Config section at the top of `matrix-podman.sh`:

```bash
MATRIX_DOMAIN="example.com"      # your domain
MATRIX_TZ="Europe/Berlin"        # your timezone
SYNAPSE_PORT=8008                 # Synapse published port
ELEMENT_PORT=8080                 # Element published port
```

Then run it on the Proxmox host:

```bash
chmod +x matrix-podman.sh
./matrix-podman.sh
```

The script creates the LXC, installs Podman, generates all configs, pulls images, starts the stack, hardens the OS, and reboots. Note the CT ID and IP from the summary output.


## Step 2 — Cloudflare Tunnel

No manual DNS records needed — the tunnel creates them automatically.

Go to **Cloudflare → Zero Trust → Networks → Connectors**, select your tunnel, then **Configure Tunnel → Published application routes**. Add two routes:

| Subdomain  | Domain          | Type   | URL                      |
|------------|-----------------|--------|--------------------------|
| matrix     | example.com     | HTTP   | `<NPM_LXC_IP>:80`       |
| chat       | example.com     | HTTP   | `<NPM_LXC_IP>:80`       |

For each route: set the subdomain name (`matrix` or `chat`), select your domain from the list, set type to `HTTP`, and set the URL to your NPM container IP and port 80. This routes tunnel traffic to the NPM instance, which handles the routing based on hostname.

Cloudflare automatically creates the corresponding CNAME DNS records when you add published routes.


## Step 3 — Cloudflare SSL/TLS

In the Cloudflare dashboard for your domain:

1. Go to **SSL/TLS → Overview**
2. Set encryption mode to **Full** (not "Full (strict)", not "Flexible")

"Full" means Cloudflare encrypts traffic to the origin (NPM), but accepts NPM's self-signed or Let's Encrypt cert without strict validation. This works reliably with the tunnel.

### Other Cloudflare settings to check

**SSL/TLS → Edge Certificates:**
- "Always Use HTTPS": ON
- "Minimum TLS Version": TLS 1.2

**Speed → Optimization:**
- "Auto Minify": OFF for HTML (can break Element's SPA)

**Caching:**
- Matrix API paths should not be cached. If you use Page Rules or Cache Rules, exclude `matrix.example.com/*`


## Step 4 — NPM Proxy Hosts

Create two proxy hosts in the NPM admin interface.

### Proxy Host: `matrix.example.com`

**Details tab:**
- Domain: `matrix.example.com`
- Scheme: `http`
- Forward Hostname/IP: `<MATRIX_CT_IP>` (e.g., 192.168.1.100)
- Forward Port: `8008`
- Websockets Support: **ON**

**SSL tab:**
- SSL Certificate: Request a new Let's Encrypt certificate (or "None" if using tunnel-only with Full mode)
- Force SSL: ON

**Advanced tab** — paste this entire block:

```nginx
client_max_body_size 200M;
proxy_read_timeout 600s;
proxy_send_timeout 600s;

location /.well-known/matrix/server {
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.server": "matrix.example.com:443"}';
}

location /.well-known/matrix/client {
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '{"m.homeserver": {"base_url": "https://matrix.example.com"}, "m.identity_server": {"base_url": "https://vector.im"}, "org.matrix.msc3575.proxy": {"url": "https://matrix.example.com"}}';
}
```

Replace `example.com` with your actual domain in all three places.

### Proxy Host: `chat.example.com`

**Details tab:**
- Domain: `chat.example.com`
- Scheme: `http`
- Forward Hostname/IP: `<MATRIX_CT_IP>` (same IP)
- Forward Port: `8080`

**SSL tab:**
- SSL Certificate: Request a new Let's Encrypt certificate (or "None" if tunnel-only)
- Force SSL: ON

No advanced config needed for Element.

### Why Scheme is `http` but Force SSL is ON

These control different things. **Scheme: http** is how NPM connects to the container on your local network (plain HTTP on ports 8008/8080). **Force SSL** redirects public browser requests from `http://` to `https://` — the TLS is handled by Cloudflare (edge) and/or NPM (Let's Encrypt), not by the containers themselves.

### Note on SSL certificates with Cloudflare Tunnel

When using cloudflared, the tunnel terminates at NPM on port 80 (HTTP). NPM's Let's Encrypt certs are optional in this setup — they're only needed if you also access NPM directly on your LAN over HTTPS. The tunnel itself doesn't require them. If Let's Encrypt issuance fails (common behind a tunnel since the HTTP-01 challenge can't reach NPM directly), you can skip the certificate in NPM and rely on Cloudflare's edge certificate instead. Just make sure Cloudflare SSL is set to "Full" (not "Full strict").


## Step 5 — Create Admin User

```bash
pct exec <CT_ID> -- podman exec -it synapse register_new_matrix_user \
  http://localhost:8008 -c /data/homeserver.yaml
```

It prompts for username, password, and admin status. Say yes to admin for the first user.


## Step 6 — Verify

### Federation test

Open: `https://federationtester.matrix.org/#matrix.example.com`

All checks should be green. If you see connection errors on port 8448, the `.well-known/matrix/server` file is not being served correctly. Test it:

```bash
curl https://matrix.example.com/.well-known/matrix/server
# Should return: {"m.server": "matrix.example.com:443"}

curl https://matrix.example.com/.well-known/matrix/client
# Should return JSON with m.homeserver base_url
```

If these return 404 or HTML errors, check the NPM Advanced tab config for `matrix.example.com`.

### Element Web

Open: `https://chat.example.com`

The homeserver should be pre-filled as `matrix.example.com`. Log in with the admin user you created.

### Android / iOS

Install Element from the app store. On the login screen, tap "Other" or "Custom server" and enter:

```
https://matrix.example.com
```

Log in with your credentials.


## Troubleshooting

### Element shows 502 Bad Gateway

Check if the element-web container is running:

```bash
pct exec <CT_ID> -- podman ps | grep element
```

If status shows "Initialized" instead of "Up", check logs:

```bash
pct exec <CT_ID> -- podman logs element-web
```

If you see `bind() to 0.0.0.0:80 failed (Permission denied)`, the custom nginx template isn't mounted. Verify `docker-compose.yml` has this in the element service:

```yaml
volumes:
  - ./element-config.json:/app/config.json:ro
  - ./element-nginx.conf:/etc/nginx/templates/default.conf.template:ro
ports:
  - "8080:8080"
```

And that `/opt/matrix/element-nginx.conf` exists with `listen 8080;`. This is required because unprivileged Podman inside an unprivileged LXC cannot bind to ports below 1024.

### Federation test shows port 8448 timeout

The `.well-known/matrix/server` response tells federation clients to connect on port 443 instead of the default 8448. If this file isn't served, clients fall back to 8448 which isn't open.

Fix: ensure the NPM Advanced tab for `matrix.example.com` contains the `.well-known` location blocks (see Step 5).

### Synapse not starting

Check logs:

```bash
pct exec <CT_ID> -- podman logs synapse
```

Common issues:
- Database connection refused: PostgreSQL hasn't finished initializing. Wait 30 seconds and check again.
- YAML parse error in homeserver.yaml: the Python patch failed. Check `/opt/matrix/synapse/homeserver.yaml` for duplicate `database:` blocks.

### Containers not starting after reboot

```bash
pct exec <CT_ID> -- systemctl status matrix-stack.service
pct exec <CT_ID> -- journalctl -u matrix-stack.service --no-pager -n 50
```

To manually restart:

```bash
pct exec <CT_ID> -- bash -c 'cd /opt/matrix && podman-compose down && podman-compose up -d'
```


## Maintenance

### View running containers

```bash
pct exec <CT_ID> -- bash -c 'cd /opt/matrix && podman-compose ps'
```

### View logs

```bash
pct exec <CT_ID> -- podman logs synapse
pct exec <CT_ID> -- podman logs element-web
pct exec <CT_ID> -- podman logs postgres_db
pct exec <CT_ID> -- podman logs redis
```

### Manual update

```bash
pct exec <CT_ID> -- bash -c 'cd /opt/matrix && podman-compose pull && podman-compose up -d'
```

Auto-updates run biweekly (1st and 15th of each month at 05:30) via the `matrix-update.timer`.

### Check update timer

```bash
pct exec <CT_ID> -- systemctl status matrix-update.timer
```

### Backup

The data lives in `/opt/matrix/` inside the LXC. Key directories:
- `synapse/` — homeserver config and media store
- `postgresdata/` — PostgreSQL database files
- `.secrets/` — database password

For a consistent backup, stop the stack first:

```bash
pct exec <CT_ID> -- bash -c 'cd /opt/matrix && podman-compose down'
# Back up /opt/matrix/ via Proxmox Backup Server or manual copy
pct exec <CT_ID> -- bash -c 'cd /opt/matrix && podman-compose up -d'
```

Or use Proxmox Backup Server to snapshot the entire LXC.


## File Reference

| File | Purpose |
|------|---------|
| `/opt/matrix/docker-compose.yml` | Podman Compose stack definition |
| `/opt/matrix/.env` | Reference file (values baked into compose) |
| `/opt/matrix/.secrets/db_password.secret` | PostgreSQL password (root:root 600) |
| `/opt/matrix/element-config.json` | Element Web client configuration |
| `/opt/matrix/element-nginx.conf` | Nginx template for Element (listen 8080) |
| `/opt/matrix/synapse/homeserver.yaml` | Synapse homeserver configuration |
| `/opt/matrix/synapse/` | Synapse data and media store |
| `/opt/matrix/postgresdata/` | PostgreSQL data directory |
| `/opt/matrix/redis/` | Redis AOF persistence |
| `/etc/systemd/system/matrix-stack.service` | Auto-start stack on boot |
| `/etc/systemd/system/matrix-update.timer` | Biweekly auto-update |
| `/etc/sysctl.d/99-hardening.conf` | Network hardening + unprivileged port fix |
