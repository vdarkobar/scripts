# Matrix + RTC — quick setup guide

**Domain: `your-domain.tld` · Debian 13 RTC VPS · Updated 9 September 2026**

**Replace before use:** `your-domain.tld` → your domain; `REPLACE_WITH_VPS_PUBLIC_IPV4` → your VPS public IPv4; `REPLACE_WITH_YOUR_EMAIL` → your email. Apply these substitutions in DNS, Cloudflare rules, installer settings and commands.

Matrix/Element stay at home behind **Cloudflare Tunnel → NPM**. LiveKit/MatrixRTC run on the **Hetzner VPS**. Use the corrected installer supplied with this guide.

## 1. DNS — Cloudflare → your-domain.tld → DNS

| Full hostname | Type | Target | Proxy |
|---|---|---|---|
| `matrix.your-domain.tld` | Existing tunnel CNAME | Keep the existing tunnel target | Proxied |
| `chat.your-domain.tld` | Existing tunnel CNAME | Keep the existing tunnel target | Proxied |
| `rtc.your-domain.tld` | A | Hetzner VPS public IPv4 | **DNS only** |
| `turn.your-domain.tld` | A | Same Hetzner VPS public IPv4 | **DNS only** |

Use **Auto TTL**. Leave RTC/TURN **AAAA records absent** with the default `PUBLIC_IPV6=""`. Publish AAAA only after configuring and externally testing IPv6. Keep the VPS machine FQDN distinct from `rtc` and `turn`.

## 2. Cloudflare — allow Matrix API clients

Open **Rules → Overview → Create rule → Configuration Rule**. Name it **Matrix API — BIC off**. In **Edit expression**, select all existing text and replace it with:

```text
(http.host eq "matrix.your-domain.tld" and (
  starts_with(http.request.uri.path, "/_matrix/")
  or http.request.uri.path eq "/.well-known/matrix/client"
  or http.request.uri.path eq "/.well-known/matrix/server"
))
```

Set **Browser Integrity Check → Off**, status **Active**, order **Last**, then **Deploy**. Cloudflare documents the [rule creation steps](https://developers.cloudflare.com/rules/configuration-rules/create-dashboard/) and [BIC setting](https://developers.cloudflare.com/rules/configuration-rules/settings/#browser-integrity-check).

If you have a broad caching rule covering Matrix, add a **Cache Rule** with the same expression, set **Cache eligibility → Bypass cache**, and ensure it takes precedence over that caching rule. [Cache settings](https://developers.cloudflare.com/cache/how-to/cache-rules/settings/#cache-eligibility).

Matrix API paths must work without an interactive Access login or browser challenge. Keep public `/_synapse/admin` blocked in NPM. RTC/TURN use DNS only and connect directly to the VPS.

## 3. Firewall — RTC VPS only

Any upstream firewall must also allow this traffic.

| Protocol | Inbound port | Purpose |
|---|---|---|
| TCP | 80 | Certificate issuance/renewal |
| TCP | 443 | RTC HTTPS/WebSocket + TURN/TLS |
| TCP | 7881 | Direct media over TCP |
| UDP | 7882 | Direct media |
| UDP | 3478 | TURN |
| UDP | 40000–40199 | TURN relay range |


The destination-specific syntax matches the installer's runtime checks. [UFW command reference](https://manpages.debian.org/trixie/ufw/ufw.8.en.html).

**If a Hetzner Cloud Firewall is attached:** allow the same six rows inbound from `0.0.0.0/0`, plus your existing restricted SSH access. If outbound traffic is restricted, allow the backend's required outbound traffic as well. Both firewalls must permit the connection.

Keep TCP **5349, 7880, 8080, 6379, 18080 and 18081 closed externally**. The installer protects these internal services. Ports on the home Matrix LXC remain restricted to NPM.

## 4. Install Matrix first, then RTC

**Fresh Matrix only — edit `matrix-quadlet.sh`, then run it on the Proxmox host:**

```bash
MATRIX_RTC_AUTH_URL="https://rtc.your-domain.tld/livekit/jwt"
MATRIX_RTC_HEALTH_URL="https://rtc.your-domain.tld/livekit/jwt/healthz"
MATRIX_RTC_REQUIRE_HEALTH=0
```

Keep the other site/storage/NPM settings appropriate to your setup. Skip the creator if Matrix already exists.

**From the RTC VPS**, confirm the public Matrix route works before installing RTC:

```bash
curl --http1.1 -fsS -A 'Python-urllib/3.13' \
  https://matrix.your-domain.tld/_matrix/client/versions | python3 -m json.tool
```

Expected: JSON with a `versions` array. Public `/.well-known/matrix/server` must delegate to **`matrix.your-domain.tld:443`**; the installer also checks discovery and OpenID.

**RTC installer settings — `matrix-rtc.sh`:**

```bash
MATRIX_SERVER_NAME="matrix.your-domain.tld"
HOMESERVER_URL="https://matrix.your-domain.tld"
RTC_HOST="rtc.your-domain.tld"
TURN_HOST="turn.your-domain.tld"
PUBLIC_IPV4="REPLACE_WITH_VPS_PUBLIC_IPV4"
PUBLIC_IPV6=""
ACME_EMAIL="REPLACE_WITH_YOUR_EMAIL"
REQUIRE_PHASE2=1
```

Run on the **RTC VPS**:

```bash
sudo bash matrix-rtc.sh
```

## 5. Integrate an existing Matrix server

If the revised Matrix creator already wrote the RTC settings, skip this step. Otherwise, copy `matrixrtc-integrate-existing.py` from the package into the Matrix LXC and run **inside that LXC as root**:

```bash
apt-get install python3-yaml
python3 matrixrtc-integrate-existing.py \
  --rtc-url https://rtc.your-domain.tld/livekit/jwt --apply
```

Review the result and type **APPLY**. The helper validates, backs up and updates **`/opt/matrix/synapse/homeserver.yaml`**, then restarts Synapse. Alternatively, follow the manual YAML/backup steps printed in the RTC installer's summary.

If NPM serves a static client `.well-known` response, merge the RTC focus there too, preserving `m.homeserver`. No Element Web configuration change is needed for the supplied baseline.

## 6. Verify and keep working

**RTC VPS:**

```bash
sudo matrixrtc-maint check
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' \
  https://rtc.your-domain.tld/livekit/sfu/rtc/v1/validate
curl -fsS https://matrix.your-domain.tld/.well-known/matrix/client \
  | python3 -m json.tool
```

Expected: maintenance checks pass; validation returns **401** without a token; discovery contains `org.matrix.msc4143.rtc_foci` with `livekit_service_url` **`https://rtc.your-domain.tld/livekit/jwt`**. Reopen **Element X on both phones**, then test a call across Wi-Fi/mobile data.

**Older installer showing “Service unreachable” / v1 route 404:** run the corrected installer on the existing RTC VPS and choose **ROUTES**. It backs up and repairs the proxy rules.

**Later hardening runs — preserve RTC firewall rules:**

```bash
sudo env ENABLE_UFW=0 /usr/local/sbin/phase2-hardening.sh
```

If phase 2 reset the firewall, run `sudo matrixrtc-maint firewall-repair`, then `sudo matrixrtc-maint check`.
