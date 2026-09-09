#!/usr/bin/env bash
# MatrixRTC companion backend for a plain Debian 13 Hetzner Cloud VPS.
# Research baseline: 2026-09-09. Run locally on the VPS; never on the Matrix host.
# This file contains all generated maintenance/configuration code. No remote deployment.
# Revision 4: LiveKit v1 signaling routes and an installed-deployment ROUTES repair.
# Run after the supplied cloud-init baseline and phase2-hardening.sh.
# Bootstrap: Matrix must first be running through its public NPM/Cloudflare route.
# The companion Matrix creator permits planned RTC URLs before RTC is installed.
set -Eeuo pipefail
umask 022
export LC_ALL=C SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat

# CONFIGURATION — empty site values prompt. Existing site.json wins on a rerun.
MATRIX_SERVER_NAME=""              # permanent Matrix identity, e.g. matrix.your-domain.tld
HOMESERVER_URL=""                  # public Synapse HTTPS origin, e.g. https://matrix.your-domain.tld
RTC_HOST=""                        # DNS-only hostname pointing directly to this VPS
TURN_HOST=""                       # distinct DNS-only hostname, same VPS
PUBLIC_IPV4=""                     # directly assigned IPv4; a single detected address is suggested
PUBLIC_IPV6=""                     # opt-in only; do not publish AAAA unless externally tested
ACME_EMAIL=""
APP_TZ=""                          # empty inherits the VPS timezone; host setting is preserved
REQUIRE_PHASE2=1                   # 1: supplied hardening completed + active UFW; 0: generic VPS
FULL_ACCESS_HOMESERVERS=""          # comma-separated permanent server_names, no wildcard
HTTP_PORT=80                       # must remain 80 for HTTP-01
HTTPS_PORT=443                     # LiveKit advertises built-in TURN/TLS on 443
LIVEKIT_PORT=7880                  # loopback HTTP/signalling
AUTH_PORT=8080                     # loopback authorization
ICE_TCP_PORT=7881                  # public ICE/TCP
MEDIA_UDP_PORT=7882                # public UDP media multiplexer
TURN_UDP_PORT=3478                 # public authenticated TURN/UDP
TURN_INTERNAL_PORT=5349            # PRIVATE plaintext TURN, HAProxy terminates TLS
EDGE_HTTP_PORT=18081               # loopback HAProxy HTTP router
ACME_PORT=18080                    # loopback challenge file server
REDIS_PORT=6379                    # loopback job persistence
RELAY_FIRST=40000                  # bounded TURN relay UDP range; not a capacity promise
RELAY_LAST=40199
START_WAIT_SECONDS=180
STABILITY_SECONDS=30               # wait after startup, then check for restart loops
LIVEKIT_VERSION="v1.13.6"
LIVEKIT_DIGEST="sha256:e37d68f172556d02aa77968b9fc55ef481468c0315fa38e4fa6c56ce72e3a815"
AUTH_VERSION="0.6.0"
AUTH_DIGEST="sha256:822f0c03a3bdd924da92afc2e8ec59de5dda17af42d32e71e11f269c3517abf7"
REDIS_VERSION="8.2.6-alpine"
REDIS_DIGEST="sha256:ea5a07305d6c66f99df5a5ff8d9659e8f6cb598e6e586dc8dd92b7fcd915746e"
# Package versions follow Debian 13 security updates; no custom proxy build/module.
PACKAGES=(podman skopeo haproxy certbot python3 python3-yaml ca-certificates curl nftables iproute2 openssl)
ROOT_DIR="/etc/matrixrtc"           # fixed in the embedded maintenance code
DATA_DIR="/var/lib/matrixrtc"
LIB_DIR="/usr/local/lib/matrixrtc"

# PHASE 1 — operating-system, ownership and interactive preflight (read-only).
[[ $REQUIRE_PHASE2 == 0 || $REQUIRE_PHASE2 == 1 ]] || { echo 'ERROR: REQUIRE_PHASE2 must be 0 or 1.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'ERROR: Run this file with sudo bash, or as root, on the Debian VPS.' >&2; exit 1; }
[[ -f /etc/os-release ]] || { echo 'ERROR: Missing /etc/os-release.' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || { echo 'ERROR: This installer supports plain Debian 13 only.' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'ERROR: systemd must run as PID 1.' >&2; exit 1; }
for command in python3 ip ss flock dpkg apt-get systemctl timedatectl mktemp install mv chmod readlink; do
    command -v "$command" >/dev/null || { echo "ERROR: Missing prerequisite: $command" >&2; exit 1; }
done
ARCH=$(dpkg --print-architecture)
[[ $ARCH == amd64 || $ARCH == arm64 ]] || { echo "ERROR: Unsupported architecture: $ARCH" >&2; exit 1; }
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || { echo 'ERROR: Quadlet requires cgroup v2.' >&2; exit 1; }
exec 9>/run/lock/matrixrtc.lock
flock -n 9 || { echo 'ERROR: Another MatrixRTC operation is running.' >&2; exit 1; }
exec 8<>/dev/tty || { echo 'ERROR: An interactive terminal is required. Download the script and run it locally.' >&2; exit 1; }
TEMP_DIR=$(mktemp -d /tmp/matrixrtc-install.XXXXXXXX)
POLICY_CREATED=0
rc=0
trap 'rc=$?; trap - EXIT; if (( POLICY_CREATED )); then rm -f /usr/sbin/policy-rc.d; fi; rm -rf -- "$TEMP_DIR"; if (( rc )); then echo "ERROR: Installation stopped (exit $rc). No credentials or existing data were deleted. Review the last phase and rerun after correction." >&2; fi; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

INSTALLED=0
if [[ -e $ROOT_DIR || -L $ROOT_DIR ]]; then
    [[ -d $ROOT_DIR && ! -L $ROOT_DIR && -f $ROOT_DIR/managed-by-matrixrtc ]] || { echo "ERROR: Refusing to take over $ROOT_DIR." >&2; exit 1; }
    [[ $(stat -c '%u:%a' "$ROOT_DIR") == 0:700 ]] || { echo 'ERROR: Existing /etc/matrixrtc must be root-owned, mode 0700.' >&2; exit 1; }
    if [[ -f $ROOT_DIR/installed ]]; then
        INSTALLED=1
        PARTIAL=0
        [[ -f $ROOT_DIR/current/settings.json ]] || { echo 'ERROR: Installed backend has no active settings.' >&2; exit 1; }
        cp "$ROOT_DIR/current/settings.json" "$TEMP_DIR/site.json"
        echo 'Installed backend found. Saved active settings and image versions will be retained.'
    else
        [[ -f $ROOT_DIR/site.json ]] || { echo 'ERROR: Existing partial installation has no site.json. Inspect it before recovery.' >&2; exit 1; }
        cp "$ROOT_DIR/site.json" "$TEMP_DIR/site.json"
        echo 'Resuming an incomplete installation using its saved settings and credentials.'
        # Stop only installer-owned services, after the provisioning confirmation.
        PARTIAL=1
    fi
else
    PARTIAL=0
    for path in "$DATA_DIR" "$LIB_DIR" /usr/local/bin/matrixrtc-maint; do
        [[ ! -e $path && ! -L $path ]] || { echo "ERROR: Unowned path exists: $path" >&2; exit 1; }
    done
    for name in livekit auth redis edge guard acme-http renew; do
        for path in "/etc/systemd/system/matrixrtc-$name.service" "/etc/containers/systemd/matrixrtc-$name.container"; do
            [[ ! -e $path && ! -L $path ]] || { echo "ERROR: Unowned unit exists: $path" >&2; exit 1; }
        done
        [[ $(systemctl show "matrixrtc-$name.service" -p LoadState --value) == not-found ]] || { echo "ERROR: A matrixrtc-$name service already exists." >&2; exit 1; }
    done
    [[ ! -e /etc/systemd/system/matrixrtc-renew.timer ]] || { echo 'ERROR: An unowned renewal timer exists.' >&2; exit 1; }
    if [[ -z $PUBLIC_IPV4 ]]; then
        DETECTED_IPV4=$(ip -j -4 address show scope global | python3 -c 'import sys,json,ipaddress; a=[v["local"] for i in json.load(sys.stdin) for v in i.get("addr_info",[]) if ipaddress.ip_address(v["local"]).is_global]; print(a[0] if len(a)==1 else "")')
        read -r -p "Public VPS IPv4 [${DETECTED_IPV4:-enter address}]: " PUBLIC_IPV4 <&8
        PUBLIC_IPV4=${PUBLIC_IPV4:-$DETECTED_IPV4}
    fi
    echo 'Use RTC and TURN service names distinct from the cloud-init machine FQDN.'
    echo 'Example: machine vps01.your-domain.tld; services rtc.your-domain.tld and turn.your-domain.tld.'
    if [[ -z $APP_TZ ]]; then
        APP_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        [[ -n $APP_TZ ]] || { echo 'ERROR: Could not read the VPS timezone. Set APP_TZ explicitly.' >&2; exit 1; }
    fi
    for name in MATRIX_SERVER_NAME HOMESERVER_URL RTC_HOST TURN_HOST ACME_EMAIL; do
        if [[ -z ${!name} ]]; then
            read -r -p "$name: " "${name?}" <&8
        fi
    done
    FULL_ACCESS_HOMESERVERS=${FULL_ACCESS_HOMESERVERS:-$MATRIX_SERVER_NAME}
    export MATRIX_SERVER_NAME HOMESERVER_URL RTC_HOST TURN_HOST PUBLIC_IPV4 PUBLIC_IPV6 ACME_EMAIL APP_TZ FULL_ACCESS_HOMESERVERS
    export HTTP_PORT HTTPS_PORT LIVEKIT_PORT AUTH_PORT ICE_TCP_PORT MEDIA_UDP_PORT TURN_UDP_PORT TURN_INTERNAL_PORT EDGE_HTTP_PORT ACME_PORT REDIS_PORT RELAY_FIRST RELAY_LAST START_WAIT_SECONDS STABILITY_SECONDS
    export LIVEKIT_VERSION LIVEKIT_DIGEST AUTH_VERSION AUTH_DIGEST REDIS_VERSION REDIS_DIGEST
    python3 - "$TEMP_DIR/site.json" <<'PY_SITE'
import json,os,sys
keys='MATRIX_SERVER_NAME HOMESERVER_URL RTC_HOST TURN_HOST PUBLIC_IPV4 PUBLIC_IPV6 ACME_EMAIL APP_TZ FULL_ACCESS_HOMESERVERS HTTP_PORT HTTPS_PORT LIVEKIT_PORT AUTH_PORT ICE_TCP_PORT MEDIA_UDP_PORT TURN_UDP_PORT TURN_INTERNAL_PORT EDGE_HTTP_PORT ACME_PORT REDIS_PORT RELAY_FIRST RELAY_LAST START_WAIT_SECONDS STABILITY_SECONDS'.split()
c={k:os.environ[k] for k in keys}
for n in ('livekit','auth','redis'):
    for field in ('version','digest'):c[n+'_'+field]=os.environ[n.upper()+'_'+field.upper()]
with open(sys.argv[1],'w') as f:json.dump(c,f,indent=2)
os.chmod(sys.argv[1],0o600)
PY_SITE
fi

# PHASE 2 — embedded maintenance implementation, staged before installation.
cat > "$TEMP_DIR/manage.py" <<'PY_MANAGER'
#!/usr/bin/python3
"""MatrixRTC generation, checks and explicit maintenance. Root only for mutation."""
import base64
import contextlib
import datetime
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

os.environ['SYSTEMD_COLORS'] = '0'
os.environ['SYSTEMD_PAGER'] = 'cat'
os.environ['LC_ALL'] = 'C'  # stable UFW/status parsing on non-English hosts
ROOT = Path('/etc/matrixrtc')
DATA = Path('/var/lib/matrixrtc')
SERVICES = ['matrixrtc-redis', 'matrixrtc-livekit', 'matrixrtc-auth', 'matrixrtc-edge']
REPOS = {'livekit': 'docker.io/livekit/livekit-server',
         'auth': 'ghcr.io/element-hq/lk-jwt-service', 'redis': 'docker.io/library/redis'}
LEGACY_SFU_ACL = '    acl sfu_path path -m str /livekit/sfu/rtc /livekit/sfu/rtc/validate\n'
SFU_ACL = LEGACY_SFU_ACL.rstrip('\n') + ' /livekit/sfu/rtc/v1 /livekit/sfu/rtc/v1/validate\n'
SFU_VALIDATION_PATHS = ('/livekit/sfu/rtc/validate', '/livekit/sfu/rtc/v1/validate')

def fail(message):
    raise RuntimeError(message)

def run(*args, capture=False, **kw):
    return subprocess.run(args, check=True, text=True, capture_output=capture, **kw)

def atomic(path, data, mode=0o600):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.' + path.name + '.')
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def link(target, path):
    path = Path(path)
    tmp = path.with_name('.' + path.name + '.' + secrets.token_hex(6))
    os.symlink(str(target), tmp)
    os.replace(tmp, path)

def read(path):
    return json.loads(Path(path).read_text())

def domain(value):
    return isinstance(value, str) and len(value) <= 253 and '.' in value and bool(re.fullmatch(
        r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', value)) and all(
        re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in value.split('.'))

def validate(c):
    for key in ('MATRIX_SERVER_NAME', 'RTC_HOST', 'TURN_HOST'):
        if not domain(c[key]) or c[key].endswith(('.example.com', '.invalid', '.test')) or c[key] == 'example.com':
            fail(f'{key}: supply your real lower-case DNS name (without https://).')
    if len({c['MATRIX_SERVER_NAME'], c['RTC_HOST'], c['TURN_HOST']}) != 3:
        fail('Matrix, RTC and TURN names must be distinct in this deployment.')
    u = urllib.parse.urlsplit(c['HOMESERVER_URL'])
    if u.scheme != 'https' or not domain(u.hostname or '') or u.username or u.password or u.query or u.fragment or u.path not in ('', '/') or u.port not in (None, 443):
        fail('HOMESERVER_URL must be a public HTTPS origin on port 443, without a path.')
    c['HOMESERVER_URL'] = c['HOMESERVER_URL'].rstrip('/')
    for key, family in [('PUBLIC_IPV4', 4), ('PUBLIC_IPV6', 6)]:
        if key == 'PUBLIC_IPV6' and not c[key]:
            continue
        try:
            address = ipaddress.ip_address(c[key])
        except ValueError:
            fail(f'{key}: enter a public IP address without a subnet prefix.')
        if address.version != family or not address.is_global:
            fail(f'{key}: a globally routable IPv{family} address is required.')
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', c['ACME_EMAIL']):
        fail('ACME_EMAIL must be a valid contact email.')
    if not re.fullmatch(r'[A-Za-z0-9_+/-]+', c['APP_TZ']) or '..' in c['APP_TZ'] or c['APP_TZ'].startswith('/') or not Path('/usr/share/zoneinfo', c['APP_TZ']).is_file():
        fail('APP_TZ is not an installed timezone.')
    origins = c['FULL_ACCESS_HOMESERVERS'].split(',')
    if not origins or any(not domain(x) for x in origins) or c['MATRIX_SERVER_NAME'] not in origins:
        fail('FULL_ACCESS_HOMESERVERS must include the permanent Matrix server_name; no wildcards or spaces.')
    ports = ['HTTP_PORT', 'HTTPS_PORT', 'AUTH_PORT', 'LIVEKIT_PORT', 'ICE_TCP_PORT',
             'MEDIA_UDP_PORT', 'TURN_UDP_PORT', 'TURN_INTERNAL_PORT', 'EDGE_HTTP_PORT',
             'ACME_PORT', 'REDIS_PORT', 'RELAY_FIRST', 'RELAY_LAST']
    for key in ports + ['START_WAIT_SECONDS', 'STABILITY_SECONDS']:
        if not re.fullmatch(r'[1-9][0-9]*', str(c[key])):
            fail(f'{key} must be a positive integer.')
        c[key] = int(c[key])
    if any(c[k] > 65535 for k in ports):
        fail('Port numbers must be <= 65535.')
    if c['HTTP_PORT'] != 80 or c['HTTPS_PORT'] != 443:
        fail('This ACME HTTP-01 / built-in LiveKit TURN design requires public TCP 80 and 443.')
    if c['RELAY_FIRST'] >= c['RELAY_LAST'] or c['RELAY_FIRST'] < 1024:
        fail('Invalid TURN relay range.')
    singles = [c[k] for k in ports[:-2]]
    if len(set(singles)) != len(singles) or any(c['RELAY_FIRST'] <= p <= c['RELAY_LAST'] for p in singles):
        fail('Configured ports overlap; choose distinct listeners and relay ports.')
    if any(c[k] < 1024 for k in ports[2:]):
        fail('Internal/media/TURN UDP ports must be unprivileged (>=1024).')
    if c['STABILITY_SECONDS'] < 30 or c['START_WAIT_SECONDS'] < 30:
        fail('Use at least 30 seconds for startup and stability checks.')
    for name in REPOS:
        if not re.fullmatch(r'v?\d+\.\d+\.\d+(?:-alpine)?', c[name + '_version']):
            fail(f'{name}: use a full stable release version.')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', c[name + '_digest']):
            fail(f'{name}: provide an immutable manifest digest.')
    for name, prefix in [('livekit', 'v1.13.'), ('auth', '0.6.'), ('redis', '8.2.')]:
        if not c[name + '_version'].startswith(prefix):
            fail(f'{name}: this implementation has been reviewed only for the {prefix}x series.')
    return c

def network(c):
    assigned = {a['local'] for i in json.loads(run('ip', '-j', 'address', capture=True).stdout)
                for a in i.get('addr_info', [])}
    for k in ('PUBLIC_IPV4', 'PUBLIC_IPV6'):
        if c[k] and c[k] not in assigned:
            fail(f'{k} is not assigned to this VPS. This installer expects directly assigned Hetzner addresses, not NAT.')
    for host in (c['RTC_HOST'], c['TURN_HOST']):
        for family, wanted in [(socket.AF_INET, c['PUBLIC_IPV4']), (socket.AF_INET6, c['PUBLIC_IPV6'])]:
            try:
                answers = {v[4][0] for v in socket.getaddrinfo(host, None, family, socket.SOCK_STREAM)}
            except socket.gaierror as e:
                if e.errno not in (socket.EAI_NONAME, socket.EAI_NODATA):
                    fail(f'DNS lookup failed for {host}: {e}')
                answers = set()
            if answers != ({wanted} if wanted else set()):
                if any(ipaddress.ip_address(a).is_loopback for a in answers):
                    fail(f'{host} resolves locally to {sorted(answers)}. Cloud-init manage_etc_hosts: localhost can map the machine FQDN to 127.0.1.1. Use distinct public RTC/TURN service names in DNS and the installer. Keep the machine hostname and cloud-init hosts policy; this installer does not edit /etc/hosts.')
                fail(f'DNS mismatch for {host} {"A" if family == socket.AF_INET else "AAAA"}: {sorted(answers)}; expected {wanted or "no record"}. Use DNS only, not a Cloudflare proxy.')
    home = c['HOMESERVER_URL']
    endpoint = home + '/_matrix/client/versions'
    try:
        status, body = request(endpoint)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        fail(f'Homeserver API connection failed at {endpoint}: {e}. Install/start Matrix and configure its public NPM/Cloudflare route before installing RTC. The revised Matrix creator permits a pending RTC backend with MATRIX_RTC_REQUIRE_HEALTH=0.')
    try:
        info = json.loads(body)
    except ValueError:
        info = None
    if status != 200 or not isinstance(info, dict) or not isinstance(info.get('versions'), list) or not info['versions']:
        fail(f'Homeserver API {endpoint} returned HTTP {status} without a valid Matrix versions response. Install/start Matrix first and check its public NPM/Cloudflare route. HTML pages, browser challenges and proxy error responses do not satisfy this check. On the original Matrix creator, leave both RTC URLs empty for initial installation and integrate RTC afterwards; the revised creator accepts planned URLs with MATRIX_RTC_REQUIRE_HEALTH=0.')
    status, body = request('https://' + c['MATRIX_SERVER_NAME'] + '/.well-known/matrix/client')
    if status != 200 or json.loads(body).get('m.homeserver', {}).get('base_url', '').rstrip('/') != home:
        fail('Matrix client discovery does not point to HOMESERVER_URL.')
    status, body = request('https://' + c['MATRIX_SERVER_NAME'] + '/.well-known/matrix/server')
    if status != 200:
        fail('Publish /.well-known/matrix/server on the permanent server_name; this deployment requires explicit HTTPS federation delegation to port 443.')
    destination = json.loads(body).get('m.server', '')
    if not re.fullmatch(r'[a-z0-9.-]+:443', destination) or not domain(destination[:-4]):
        fail('Expected explicit m.server DNS-name:443 in federation discovery; no port 8448 is exposed by the home tunnel.')
    status, body = request('https://' + destination + '/_matrix/federation/v1/openid/userinfo?access_token=matrixrtc-intentionally-invalid')
    if status != 401 or json.loads(body).get('errcode') != 'M_UNKNOWN_TOKEN':
        fail('OpenID userinfo must return JSON M_UNKNOWN_TOKEN / HTTP 401 for the invalid probe, not a challenge, 404, or HTML.')
    print('DNS, client discovery, federation discovery and OpenID negative probe passed.')

def ufw_active():
    if shutil.which('ufw') is None:
        return False
    return 'Status: active' in run('ufw', 'status', capture=True).stdout.splitlines()

def ufw_setting(key):
    # Read simple shell assignments without executing the configuration file.
    values = []
    for line in Path('/etc/default/ufw').read_text().splitlines():
        match = re.fullmatch(r'\s*' + re.escape(key) + r'\s*=\s*(.*)', line)
        if match:
            words = shlex.split(match[1], comments=True)
            values.append(words[0] if len(words) == 1 else '' if not words else None)
    return values[-1] if values else None

def phase2_ready(initial=True):
    marker = Path('/var/lib/phase2-hardening/last-run')
    if not marker.is_file() or marker.is_symlink() or marker.stat().st_uid != 0 or marker.stat().st_mode & 0o022:
        fail('Phase-2 completion record is missing or unsafe. Complete sudo /usr/local/sbin/phase2-hardening.sh first. For an intentionally different baseline, set REQUIRE_PHASE2=0 in the installer.')
    try:
        datetime.datetime.fromisoformat(marker.read_text().strip())
    except ValueError:
        fail('Invalid phase-2 completion record; inspect the hardening run before installation.')
    result = subprocess.run(['cloud-init', 'status', '--format=json'], text=True, capture_output=True)
    try:
        state = json.loads(result.stdout).get('status')
    except (ValueError, AttributeError):
        fail('Cannot read cloud-init status; inspect sudo cloud-init status --long.')
    if result.returncode != 0 or state not in ('done', 'disabled'):
        fail(f'Cloud-init is not cleanly finished (status {state}). Resolve errors or wait for completion, then rerun.')
    if initial and Path('/run/reboot-required').exists():
        fail('A reboot is pending. Complete the baseline reboot and reconnect before first RTC installation; the installer never reboots the VPS.')
    if not ufw_active():
        fail('The phase-2 profile requires active UFW. Check the completed hardening run; RTC will not enable or reset UFW. Use REQUIRE_PHASE2=0 only for an intentional alternative firewall setup.')
    if ufw_setting('IPT_SYSCTL') != '':
        fail('Expected phase-2 IPT_SYSCTL="" in /etc/default/ufw. Resolve the hardening policy before installing RTC; kernel settings were not changed.')
    print('Phase 2 completion, cloud-init status and active UFW/sysctl separation verified.')

def firewall_rules(c):
    for address in (c['PUBLIC_IPV4'], c['PUBLIC_IPV6']):
        if not address:
            continue
        for key in ('HTTP_PORT', 'HTTPS_PORT', 'ICE_TCP_PORT'):
            yield address, 'tcp', str(c[key])
        for value in (c['MEDIA_UDP_PORT'], c['TURN_UDP_PORT'], f"{c['RELAY_FIRST']}:{c['RELAY_LAST']}"):
            yield address, 'udp', str(value)

def firewall(c, apply=False):
    """Check RTC's exact runtime rules; repair only through UFW's supported CLI."""
    policy_file = ROOT / 'host-policy.json'
    policy = read(policy_file) if policy_file.is_file() else c
    if not ufw_active():
        if apply or policy.get('FIREWALL_POLICY') == 'ufw':
            fail('UFW is inactive or absent. Inspect the host firewall; this command never enables or resets it.')
        print('UFW is inactive/absent; verify the existing host and Hetzner firewall externally.')
        return
    if c['PUBLIC_IPV6'] and ufw_setting('IPV6') != 'yes':
        fail('UFW does not manage IPv6. Resolve that policy before applying or checking dual-stack RTC rules.')
    if policy.get('HARDENING_PROFILE') == 'phase2' and ufw_setting('IPT_SYSCTL') != '':
        fail('Phase-2 UFW/sysctl separation changed: expected IPT_SYSCTL="". Inspect /etc/default/ufw before continuing.')
    if apply:
        assigned = {ipaddress.ip_address(a['local']) for i in json.loads(run('ip', '-j', 'address', capture=True).stdout)
                    for a in i.get('addr_info', [])}
        if any(ipaddress.ip_address(a) not in assigned for a in (c['PUBLIC_IPV4'], c['PUBLIC_IPV6']) if a):
            fail('Saved public address is no longer assigned to this VPS; refusing to add stale firewall rules.')
        for address, proto, port in firewall_rules(c):
            run('ufw', 'allow', 'proto', proto, 'from', 'any', 'to', address, 'port', port,
                'comment', 'MatrixRTC public ' + proto.upper(), capture=True)
        print('RTC application allows applied. Existing SSH rules, UFW defaults and sysctl settings preserved.')
    missing = []
    for address, proto, port in firewall_rules(c):
        binary = 'ip6tables' if ':' in address else 'iptables'
        chain = 'ufw6-user-input' if ':' in address else 'ufw-user-input'
        variants = [('-m', proto, '--dport', port)]
        if ':' in port:
            variants.append(('-m', 'multiport', '--dports', port))
        for match in variants:
            result = subprocess.run([binary, '-w', '5', '-C', chain, '-d', address,
                                     '-p', proto, *match, '-j', 'ACCEPT'],
                                    text=True, capture_output=True)
            if result.returncode == 0:
                break
            if result.returncode != 1:
                fail(f'Unable to inspect {binary} UFW rules. Check the firewall backend and permissions.')
        else:
            missing.append(f'{address} {proto}/{port}')
    if missing:
        fail('Missing RTC runtime UFW rules: ' + ', '.join(missing) + '. After a phase-2 reset, run sudo matrixrtc-maint firewall-repair. If still missing, inspect UFW saved/runtime state; no full firewall reload was attempted.')
    print('RTC runtime UFW allow rules are present. Earlier deny rules, other tables and the Hetzner firewall still require external connectivity tests.')

def request(url, payload=None, headers=None):
    req = urllib.request.Request(url, data=payload, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status, response.read(1_000_000).decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read(1_000_000).decode()

def ports(c):
    tcp = {c[k] for k in ('HTTP_PORT','HTTPS_PORT','AUTH_PORT','LIVEKIT_PORT','ICE_TCP_PORT','TURN_INTERNAL_PORT','EDGE_HTTP_PORT','ACME_PORT','REDIS_PORT')}
    udp = {c['MEDIA_UDP_PORT'],c['TURN_UDP_PORT'], *range(c['RELAY_FIRST'], c['RELAY_LAST'] + 1)}
    for proto, reserved in [('tcp',tcp),('udp',udp)]:
        output = run('ss','-H','-ln' + ('t' if proto == 'tcp' else 'u'),capture=True).stdout
        for line in output.splitlines():
            fields = line.split()
            if len(fields) >= 4:
                local = fields[3]
                value = local.rsplit(':',1)[-1]
                if value.isdigit() and int(value) in reserved:
                    fail(f'Port conflict: {proto} {local}. Inspect ss -lntup; unrelated listeners will not be stopped.')
    print('Reserved TCP/UDP listeners and TURN relay range are available.')

def wait_redis():
    c, s = read(ROOT/'current/settings.json'), read(ROOT/'secrets.json')
    def bulk(parts):
        return ('*'+str(len(parts))+'\r\n'+''.join('$'+str(len(x))+'\r\n'+x+'\r\n' for x in parts)).encode()
    for _ in range(30):
        try:
            with socket.create_connection(('127.0.0.1',c['REDIS_PORT']),timeout=2) as conn:
                conn.settimeout(2)
                conn.sendall(bulk(['AUTH',s['redis_password']]))
                if conn.recv(1024) != b'+OK\r\n':
                    fail('Redis authentication failed.')
                conn.sendall(bulk(['PING']))
                if conn.recv(1024) == b'+PONG\r\n':
                    return
        except (OSError,RuntimeError):
            pass
        time.sleep(1)
    fail('Redis did not accept an authenticated PING within 30 attempts.')

def acquire_images(c):
    arch = run('dpkg', '--print-architecture', capture=True).stdout.strip()
    for name, repo in REPOS.items():
        ref = repo + '@' + c[name + '_digest']
        manifest = json.loads(run('skopeo', 'inspect', '--raw', 'docker://' + ref, capture=True).stdout)
        supported = {(m.get('platform', {}).get('os'), m.get('platform', {}).get('architecture')) for m in manifest.get('manifests', [])}
        if not {('linux', 'amd64'), ('linux', 'arm64')} <= supported:
            fail(f'{name}: manifest must contain both linux/amd64 and linux/arm64.')
        run('podman', 'pull', '--quiet', '--platform', 'linux/' + arch, ref)
        info = json.loads(run('podman', 'image', 'inspect', ref, capture=True).stdout)[0]
        if info['Architecture'] != arch or info['Os'] != 'linux':
            fail(f'{name}: pulled architecture mismatch.')
        c[name + '_image_id'] = info['Id']
        # An explicit local pin protects old revisions against ordinary image prune.
        run('podman', 'tag', info['Id'], 'localhost/matrixrtc-' + name + ':pin-' + c[name + '_digest'][7:23])
    return c

def stage_probe(c, generation):
    """Exercise the real selected parsers in disposable isolated namespaces."""
    import yaml
    run('podman','run','--rm','--pull=never','--network=none','--cap-drop=all',
        '-v',str(generation/'livekit.yaml')+':/config.yaml:ro',
        REPOS['livekit']+'@'+c['livekit_digest'],'--config','/config.yaml','ports',capture=True)
    probe = generation / 'probe-livekit.yaml'
    value = yaml.safe_load((generation / 'livekit.yaml').read_text())
    value['rtc'].update({'node_ip': '127.0.0.1', 'ips': {'includes': ['127.0.0.1/32']}, 'enable_loopback_candidate': True})
    value['turn']['bind_addresses'] = ['127.0.0.1']
    atomic(probe, yaml.safe_dump(value, sort_keys=False))
    for name in ('livekit', 'auth', 'redis'):
        container = 'matrixrtc-stage-' + secrets.token_hex(6)
        args = ['podman','run','-d','--name',container,'--pull=never','--network=none',
                '--user','0:0','--cap-drop=all','--security-opt=no-new-privileges']
        ref = REPOS[name] + '@' + c[name+'_digest']
        if name == 'livekit':
            args += ['--read-only','-v',str(probe)+':/config.yaml:ro',ref,'--config','/config.yaml']
        elif name == 'auth':
            args += ['--read-only','--env-file',str(generation/'auth.env'),'-e','LIVEKIT_REDIS_URL=',
                     '-v',str(ROOT/'key')+':/run/matrixrtc/key:ro','-v',str(ROOT/'secret')+':/run/matrixrtc/secret:ro',ref]
        else:
            args += ['--tmpfs','/data:rw,mode=0700','-v',str(generation/'redis.conf')+':/config.conf:ro',
                     '--entrypoint','/usr/local/bin/redis-server',ref,'/config.conf']
        try:
            run(*args,capture=True)
            time.sleep(3)
            state=json.loads(run('podman','inspect',container,capture=True).stdout)[0]['State']
            if not state['Running']:
                log=run('podman','logs',container,capture=True)
                atomic(generation/(name+'-stage.log'),log.stdout+log.stderr)
                fail(f'{name} rejected its staged configuration. Private diagnostics retained in {generation}.')
            print(f'{name}: isolated executable/configuration startup passed.',flush=True)
        finally:
            subprocess.run(['podman','rm','-f',container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    probe.unlink()

def render(c, s, out):
    import yaml
    out = Path(out)
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    (out / 'quadlets').mkdir(exist_ok=True)
    (out / 'units').mkdir(exist_ok=True)
    atomic(out / 'settings.json', json.dumps(c, indent=2) + '\n')
    addr = [c['PUBLIC_IPV4']] + ([c['PUBLIC_IPV6']] if c['PUBLIC_IPV6'] else [])
    lk = {'port': c['LIVEKIT_PORT'], 'bind_addresses': ['127.0.0.1'],
          'rtc': {'node_ip': ','.join(addr), 'use_external_ip': False,
                  'tcp_port': c['ICE_TCP_PORT'], 'udp_port': c['MEDIA_UDP_PORT'],
                  'port_range_start': 0, 'port_range_end': 0,
                  'ips': {'includes': [a + ('/128' if ':' in a else '/32') for a in addr]}},
          'room': {'auto_create': False}, 'keys': {s['livekit_key']: s['livekit_secret']},
          'turn': {'enabled': True, 'domain': c['TURN_HOST'],
                   'external_tls': True, 'tls_port': c['TURN_INTERNAL_PORT'],
                   'udp_port': c['TURN_UDP_PORT'], 'bind_addresses': addr,
                   'relay_range_start': c['RELAY_FIRST'], 'relay_range_end': c['RELAY_LAST'],
                   'per_user_relay_allocation_limit': 12},
          'webhook': {'api_key': s['livekit_key'], 'urls': [f"http://127.0.0.1:{c['AUTH_PORT']}/sfu_webhook"]},
          'logging': {'level': 'warn'}}
    atomic(out / 'livekit.yaml', yaml.safe_dump(lk, sort_keys=False))
    auth = {'LIVEKIT_URL': f"wss://{c['RTC_HOST']}/livekit/sfu",
            'LIVEKIT_KEY_FROM_FILE': '/run/matrixrtc/key',
            'LIVEKIT_SECRET_FROM_FILE': '/run/matrixrtc/secret',
            'LIVEKIT_JWT_BIND': f"127.0.0.1:{c['AUTH_PORT']}",
            'LIVEKIT_FULL_ACCESS_HOMESERVERS': c['FULL_ACCESS_HOMESERVERS'],
            'LIVEKIT_LOG_LEVEL': 'warn', 'LIVEKIT_SANITY_CHECK_INTERVAL_SECONDS': '30',
            'LIVEKIT_REDIS_URL': f"redis://:{s['redis_password']}@127.0.0.1:{c['REDIS_PORT']}/0"}
    atomic(out / 'auth.env', ''.join(f'{k}={v}\n' for k, v in auth.items()))
    atomic(out / 'redis.conf', f"""bind 127.0.0.1
port {c['REDIS_PORT']}
protected-mode yes
requirepass {s['redis_password']}
dir /data
appendonly yes
appendfsync everysec
save ""
loglevel warning
daemonize no
""")
    header = '''global
    maxconn 4096
    ssl-default-bind-options ssl-min-ver TLSv1.2
defaults
    mode tcp
    timeout connect 10s
    timeout client 24h
    timeout server 24h
    timeout tunnel 24h
    timeout http-request 15s
'''
    binds80 = ''.join(f"    bind {'['+a+']' if ':' in a else a}:80\n" for a in addr)
    binds443 = ''.join(f"    bind {'['+a+']' if ':' in a else a}:443 ssl crt /etc/matrixrtc/tls/current.pem\n" for a in addr)
    http = f'''frontend acme_http
{binds80}    mode http
    acl acme_path path_beg /.well-known/acme-challenge/
    acl acme_host hdr(host) -i {c['RTC_HOST']} {c['TURN_HOST']}
    http-request deny deny_status 404 unless acme_path acme_host
    default_backend acme_files
backend acme_files
    mode http
    server files 127.0.0.1:{c['ACME_PORT']}
'''
    atomic(out / 'bootstrap.cfg', header + http)
    # SNI routes HTTPS. TURN is the default so older WebRTC stacks without SNI work.
    # No HTTP ALPN is advertised on the mixed-protocol TLS listener.
    edge = f'''frontend shared_tls
{binds443}    acl rtc_sni ssl_fc_sni -i {c['RTC_HOST']}
    use_backend rtc_clear if rtc_sni
    default_backend turn_clear
backend turn_clear
    server turn {c['PUBLIC_IPV4']}:{c['TURN_INTERNAL_PORT']}
backend rtc_clear
    server http 127.0.0.1:{c['EDGE_HTTP_PORT']} send-proxy-v2
frontend rtc_http
    bind 127.0.0.1:{c['EDGE_HTTP_PORT']} accept-proxy
    mode http
    acl rtc_host hdr(host) -i {c['RTC_HOST']} {c['RTC_HOST']}:443
    http-request deny deny_status 404 unless rtc_host
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]
    acl jwt_path path -m str /livekit/jwt/healthz /livekit/jwt/sfu/get /livekit/jwt/get_token /livekit/jwt/delegate_delayed_leave
{SFU_ACL}    acl local_api path_beg /livekit/sfu/twirp/
    acl loopback_source src 127.0.0.0/8 ::1 {c['PUBLIC_IPV4']}/32{(' ' + c['PUBLIC_IPV6'] + '/128') if c['PUBLIC_IPV6'] else ''}
    http-request deny deny_status 404 unless jwt_path or sfu_path or local_api loopback_source
    use_backend jwt if jwt_path
    use_backend sfu if sfu_path
    use_backend sfu if local_api loopback_source
backend jwt
    mode http
    http-request replace-path ^/livekit/jwt/(.*)$ /\1
    server auth 127.0.0.1:{c['AUTH_PORT']}
backend sfu
    mode http
    http-request replace-path ^/livekit/sfu/(.*)$ /\1
    server livekit 127.0.0.1:{c['LIVEKIT_PORT']}
'''.replace('/\x01', '/\\1')
    atomic(out / 'haproxy.cfg', header + http + edge)
    private = [c[k] for k in ('TURN_INTERNAL_PORT', 'LIVEKIT_PORT', 'AUTH_PORT', 'REDIS_PORT', 'EDGE_HTTP_PORT', 'ACME_PORT')]
    guard = 'table inet matrixrtc_guard {\n comment "Owned by matrixrtc-debian13-installer"\n chain input {\n type filter hook input priority -10; policy accept;\n iifname != "lo" tcp dport { ' + ', '.join(map(str, private)) + ' } drop\n }\n}\n'
    atomic(out / 'guard.nft', guard)
    common = '''[Unit]
Wants=network-online.target
After=network-online.target matrixrtc-guard.service
Requires=matrixrtc-guard.service
StartLimitIntervalSec=300
StartLimitBurst=5
'''
    for name in REPOS:
        unit = common
        if name == 'auth':
            unit += 'Requires=matrixrtc-redis.service\nWants=matrixrtc-livekit.service matrixrtc-edge.service\nAfter=matrixrtc-redis.service matrixrtc-livekit.service matrixrtc-edge.service\n'
        unit += f'''\n[Container]
Image={REPOS[name]}@{c[name + '_digest']}
ContainerName=matrixrtc-{name}
Pull=never
Network=host
User=0:0
NoNewPrivileges=true
DropCapability=all
Environment=TZ={c['APP_TZ']}
'''
        if name == 'livekit':
            unit += 'ReadOnly=true\nVolume=/etc/matrixrtc/current/livekit.yaml:/etc/livekit.yaml:ro\nExec=--config /etc/livekit.yaml\n'
        elif name == 'auth':
            unit += 'ReadOnly=true\nEnvironmentFile=/etc/matrixrtc/current/auth.env\nVolume=/etc/matrixrtc/key:/run/matrixrtc/key:ro\nVolume=/etc/matrixrtc/secret:/run/matrixrtc/secret:ro\n'
        else:
            unit += 'Volume=/etc/matrixrtc/current/redis.conf:/etc/redis.conf:ro\nVolume=/var/lib/matrixrtc/redis:/data\nEntrypoint=/usr/local/bin/redis-server\nExec=/etc/redis.conf\n'
        unit += '''\n[Service]
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
TimeoutStopSec=120
LimitNOFILE=65536
UMask=0022
\n[Install]
WantedBy=multi-user.target
'''
        if name == 'auth':
            unit = unit.replace('[Service]\n', '[Service]\nExecStartPre=/usr/local/lib/matrixrtc/manage.py wait-redis\n')
        atomic(out / 'quadlets' / f'matrixrtc-{name}.container', unit, 0o644)
    atomic(out / 'units' / 'matrixrtc-edge.service', '''[Unit]
Description=MatrixRTC HTTPS and TURN TLS edge
Wants=network-online.target matrixrtc-acme-http.service
After=network-online.target matrixrtc-guard.service matrixrtc-acme-http.service
Requires=matrixrtc-guard.service
[Service]
Type=notify
ExecStartPre=/usr/sbin/haproxy -c -f /etc/matrixrtc/edge.cfg
ExecStart=/usr/sbin/haproxy -Ws -f /etc/matrixrtc/edge.cfg -p /run/matrixrtc-edge.pid
ExecReload=/usr/sbin/haproxy -c -f /etc/matrixrtc/edge.cfg
ExecReload=/bin/kill -USR2 $MAINPID
KillMode=mixed
Restart=on-failure
TimeoutStartSec=60
TimeoutStopSec=120
LimitNOFILE=65536
UMask=0022
[Install]
WantedBy=multi-user.target
''', 0o644)
    atomic(out / 'units' / 'matrixrtc-guard.service', '''[Unit]
Description=Protect MatrixRTC private listeners
Before=matrixrtc-edge.service matrixrtc-livekit.service matrixrtc-auth.service matrixrtc-redis.service
After=network-pre.target nftables.service ufw.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/matrixrtc/manage.py guard
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
''', 0o644)
    atomic(out / 'units' / 'matrixrtc-acme-http.service', f'''[Unit]
Description=MatrixRTC ACME challenge files on loopback
[Service]
Type=simple
DynamicUser=yes
ExecStart=/usr/bin/python3 -m http.server {c['ACME_PORT']} --bind 127.0.0.1 --directory /var/lib/matrixrtc/acme-web
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure
UMask=0022
[Install]
WantedBy=multi-user.target
''', 0o644)
    atomic(out / 'units' / 'matrixrtc-renew.service', '''[Unit]
Description=Renew and load MatrixRTC edge certificate
After=network-online.target matrixrtc-edge.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/matrixrtc/manage.py renew
TimeoutStartSec=900
UMask=0022
''', 0o644)
    atomic(out / 'units' / 'matrixrtc-renew.timer', '''[Unit]
Description=Check MatrixRTC certificate renewal twice daily
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
''', 0o644)
    # Parse generated structured files before any activation; unknown YAML keys are
    # additionally rejected by the selected LiveKit executable during staging.
    parsed = yaml.safe_load((out / 'livekit.yaml').read_text())
    assert parsed['room']['auto_create'] is False and parsed['turn']['external_tls'] is True
    assert parsed['bind_addresses'] == ['127.0.0.1']

def guard():
    target = ROOT / 'current/guard.nft'
    exists = subprocess.run(['nft', 'list', 'table', 'inet', 'matrixrtc_guard'], capture_output=True, text=True)
    if exists.returncode == 0 and 'Owned by matrixrtc-debian13-installer' not in exists.stdout:
        fail('Unowned nftables table matrixrtc_guard exists; refusing to replace it.')
    prefix = 'delete table inet matrixrtc_guard\n' if exists.returncode == 0 else ''
    run('nft', '-f', '-', input=prefix + target.read_text())

def certbot_args():
    return ['--config-dir', str(ROOT / 'acme'), '--work-dir', str(DATA / 'certbot'),
            '--logs-dir', '/var/log/matrixrtc-acme']

def load_certificate():
    cert = ROOT / 'acme/live/matrixrtc/fullchain.pem'
    key = ROOT / 'acme/live/matrixrtc/privkey.pem'
    destination = ROOT / 'tls/current.pem'
    pem = cert.read_text() + key.read_text()
    if destination.exists() and destination.read_text() == pem:
        return
    old = destination.read_text() if destination.exists() else None
    atomic(destination, pem)
    try:
        run('haproxy', '-c', '-f', str(ROOT / 'current/haproxy.cfg'), capture=True)
        if (ROOT / 'edge.cfg').resolve().name == 'haproxy.cfg':
            run('systemctl', 'reload', 'matrixrtc-edge.service')
    except BaseException:
        if old is not None:
            atomic(destination, old)
        raise

def signaling_routes(c):
    for path in SFU_VALIDATION_PATHS:
        status, _ = request(f"https://{c['RTC_HOST']}{path}")
        if status != 401:
            fail(f'LiveKit route {path} returned HTTP {status}; expected 401 without a token. An older proxy configuration may need sudo matrixrtc-maint proxy-repair.')

def proxy_repair(c):
    """Migrate only the recognized old SFU allowlist; preserve active generation/data."""
    current = (ROOT / 'current').resolve(strict=True)
    target = current / 'haproxy.cfg'
    if not (ROOT / 'installed').is_file() or not (ROOT / 'managed-by-matrixrtc').is_file():
        fail('Proxy repair requires a completed installer-owned deployment.')
    if current.parent != (ROOT / 'releases').resolve(strict=True) or target.is_symlink():
        fail('Unexpected active generation or proxy configuration path; inspect it before repair.')
    if (ROOT / 'edge.cfg').resolve(strict=True) != target:
        fail('The edge is not using the active generated proxy configuration.')
    controller = Path('/usr/local/lib/matrixrtc/manage.py')
    if controller.is_symlink() or not controller.is_file():
        fail('Expected the installed maintenance controller to be a regular file.')
    previous = target.read_text()
    old_controller = controller.read_text()
    new_controller = Path(__file__).read_text()
    with tempfile.TemporaryDirectory(dir=ROOT, prefix='.proxy-repair-') as tmp:
        render(c, read(ROOT / 'secrets.json'), tmp)
        candidate = Path(tmp) / 'haproxy.cfg'
        updated = candidate.read_text()
        legacy = updated.replace(SFU_ACL, LEGACY_SFU_ACL)
        if updated.count(SFU_ACL) != 1 or previous not in (legacy, updated):
            fail('Proxy configuration has changes beyond the recognized old route list. No live file was changed; reconcile manual edits before repair.')
        run('haproxy', '-c', '-f', str(candidate), capture=True)
        run('systemctl', 'is-active', '--quiet', 'matrixrtc-edge.service', capture=True)
        if target.read_text() != previous or controller.read_text() != old_controller or (ROOT / 'current').resolve() != current:
            fail('Active files changed while staging proxy repair. Retry after other edits finish.')
        changed = previous != updated or old_controller != new_controller
        backup = None
        if changed:
            backup = ROOT / 'proxy-backups' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3))
            backup.parent.mkdir(mode=0o700, exist_ok=True)
            backup.mkdir(mode=0o700)
            shutil.copy2(target, backup / 'haproxy.cfg')
            shutil.copy2(controller, backup / 'manage.py')
            atomic(backup / 'active-generation.txt', str(current) + '\n')
            print(f'Proxy and maintenance backup: {backup}', flush=True)
        try:
            if previous != updated:
                atomic(target, updated, target.stat().st_mode & 0o777)
            # Also reload on a repeat: a prior interruption may have written the file
            # without loading it. Existing long-lived connections drain gracefully.
            run('systemctl', 'reload', 'matrixrtc-edge.service')
            for attempt in range(5):
                try:
                    run('systemctl', 'is-active', '--quiet', 'matrixrtc-edge.service', capture=True)
                    signaling_routes(c)
                    break
                except Exception:
                    if attempt == 4:
                        raise
                    time.sleep(1)
            if old_controller != new_controller:
                atomic(controller, new_controller, 0o700)
        except BaseException:
            if backup is not None:
                try:
                    atomic(target, previous, (backup / 'haproxy.cfg').stat().st_mode & 0o777)
                    atomic(controller, old_controller, (backup / 'manage.py').stat().st_mode & 0o777)
                    run('haproxy', '-c', '-f', str(target), capture=True)
                    run('systemctl', 'reload', 'matrixrtc-edge.service')
                    run('systemctl', 'is-active', '--quiet', 'matrixrtc-edge.service', capture=True)
                except BaseException:
                    fail(f'Proxy repair failed and rollback could not be verified. Recovery files: {backup}. Inspect matrixrtc-edge.service before retrying.')
                print('Proxy repair failed; previous proxy and controller restored and HAProxy reloaded.', file=sys.stderr)
            raise
    print('Legacy and v1 LiveKit routes respond correctly. Maintenance controller is current. Retry an Element X call; media connectivity still requires that test.')

def checks(c, stability=False):
    firewall(c)
    counters={svc: run('systemctl','show',svc+'.service','-p','NRestarts','--value',capture=True).stdout.strip() for svc in SERVICES}
    if stability:
        print(f"Waiting {c['STABILITY_SECONDS']} seconds for service stability...", flush=True)
        time.sleep(c['STABILITY_SECONDS'])
    deadline = time.monotonic() + c['START_WAIT_SECONDS']
    while True:
        try:
            for svc in SERVICES:
                run('systemctl', 'is-active', '--quiet', svc + '.service', capture=True)
            for port, path in [(c['AUTH_PORT'], '/healthz'), (c['LIVEKIT_PORT'], '/')]:
                status, _ = request(f'http://127.0.0.1:{port}{path}')
                if status != 200:
                    fail('Local service health response failed.')
            break
        except Exception:
            if time.monotonic() > deadline:
                fail('Services did not become healthy. Inspect journalctl -u matrixrtc-auth -u matrixrtc-livekit -u matrixrtc-redis -u matrixrtc-edge; treat logs as private.')
            time.sleep(2)
    for svc in SERVICES:
        restarts = run('systemctl', 'show', svc + '.service', '-p', 'NRestarts', '--value', capture=True).stdout.strip()
        if restarts != counters[svc]:
            fail(f'{svc} restarted unexpectedly during startup ({restarts}).')
    status, _ = request(f"https://{c['RTC_HOST']}/livekit/jwt/healthz")
    if status != 200:
        fail('Public HTTPS auth health route failed.')
    signaling_routes(c)
    status, _ = request(f"https://{c['RTC_HOST']}/livekit/jwt/sfu_webhook", b'{}', {'Content-Type': 'application/json'})
    if status != 404:
        fail('The internal webhook must not be exposed publicly.')
    # Non-empty invalid OpenID credentials exercise authentication, not only JSON validation.
    body = json.dumps({'room': '!matrixrtc-probe:' + c['MATRIX_SERVER_NAME'], 'device_id': 'probe',
                       'openid_token': {'access_token': 'matrixrtc-intentionally-invalid', 'matrix_server_name': c['MATRIX_SERVER_NAME']}}).encode()
    status, _ = request(f"https://{c['RTC_HOST']}/livekit/jwt/sfu/get", body, {'Content-Type': 'application/json'})
    if status != 401:
        fail('Invalid OpenID authentication must return 401.')
    # TLS validation for the TURN name does not prove TURN allocation.
    with socket.create_connection((c['TURN_HOST'], 443), timeout=10) as raw:
        with ssl.create_default_context().wrap_socket(raw, server_hostname=c['TURN_HOST']):
            pass
    rules = run('nft', 'list', 'table', 'inet', 'matrixrtc_guard', capture=True).stdout
    if 'drop' not in rules or str(c['TURN_INTERNAL_PORT']) not in rules:
        fail('Private listener guard is missing.')
    print('Service, HTTPS, TLS-name and authentication rejection checks passed. Real calls and TURN allocations remain to be tested.')

def activate(generation, old=None, component=None):
    try:
        link(generation, ROOT / 'current')
        link(ROOT / 'current/haproxy.cfg', ROOT / 'edge.cfg')
        run('systemctl', 'daemon-reload')
        if component:
            # Auth Redis jobs use the same schema only within the explicitly limited update series.
            if component == 'redis':
                run('systemctl', 'stop', 'matrixrtc-auth.service')
            run('systemctl', 'restart', f'matrixrtc-{component}.service')
            if component == 'redis':
                run('systemctl', 'start', 'matrixrtc-auth.service')
        else:
            run('systemctl', 'restart', 'matrixrtc-edge.service')
            run('systemctl', 'start', 'matrixrtc-redis.service', 'matrixrtc-livekit.service', 'matrixrtc-auth.service')
        checks(read(generation / 'settings.json'), stability=True)
    except BaseException:
        if old is not None and component == 'livekit':
            # Full immutable image/config pair is restored. Redis data is not downgraded.
            link(old, ROOT / 'current')
            run('systemctl', 'daemon-reload')
            run('systemctl', 'restart', f'matrixrtc-{component}.service')
            checks(read(old / 'settings.json'), stability=True)
            print('Previous image/configuration pair restored and health-checked; call acceptance still required.')
        elif old is not None:
            print('Stateful component update failed; no automatic image/data downgrade was attempted. Preserve data and inspect logs.', file=sys.stderr)
        else:
            subprocess.run(['systemctl', 'stop', 'matrixrtc-auth.service', 'matrixrtc-livekit.service', 'matrixrtc-redis.service'])
            print('Installation incomplete; settings, secrets, certificate and staged files retained for rerun.', file=sys.stderr)
        raise
    atomic(ROOT / 'installed', generation.name + '\n')

def install(c):
    c = acquire_images(validate(c))
    s = read(ROOT / 'secrets.json')
    generation = ROOT / 'releases' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3))
    render(c, s, generation)
    stage_probe(c, generation)
    # The retained settings are the authoritative rerun inputs, not an editable .env.
    atomic(ROOT / 'site.json', json.dumps(c, indent=2) + '\n')
    link(generation, ROOT / 'current')
    link(ROOT / 'current/bootstrap.cfg', ROOT / 'edge.cfg')
    for source in (generation / 'quadlets').iterdir():
        dest = Path('/etc/containers/systemd') / source.name
        if dest.exists() or dest.is_symlink():
            if not dest.is_symlink() or str(dest.readlink()) != str(ROOT / 'current/quadlets' / source.name):
                fail(f'Refusing to overwrite {dest}.')
        else:
            os.symlink(str(ROOT / 'current/quadlets' / source.name), dest)
    for source in (generation / 'units').iterdir():
        dest = Path('/etc/systemd/system') / source.name
        if dest.exists() or dest.is_symlink():
            if not dest.is_symlink() or str(dest.readlink()) != str(ROOT / 'current/units' / source.name):
                fail(f'Refusing to overwrite {dest}.')
        else:
            os.symlink(str(ROOT / 'current/units' / source.name), dest)
    run('haproxy', '-c', '-f', str(generation / 'bootstrap.cfg'), capture=True)
    run('systemctl', 'daemon-reload')
    for svc in SERVICES:
        if run('systemctl', 'show', svc + '.service', '-p', 'LoadState', '--value', capture=True).stdout.strip() != 'loaded':
            fail('Quadlet/systemd generation failed for ' + svc)
    run('systemctl', 'enable', 'matrixrtc-guard.service', 'matrixrtc-acme-http.service', 'matrixrtc-edge.service')
    run('systemctl', 'restart', 'matrixrtc-guard.service', 'matrixrtc-acme-http.service', 'matrixrtc-edge.service')
    run('certbot', 'certonly', '--webroot', '-w', str(DATA / 'acme-web'), '--cert-name', 'matrixrtc',
        '-d', c['RTC_HOST'], '-d', c['TURN_HOST'], '--email', c['ACME_EMAIL'], '--agree-tos',
        '--non-interactive', '--keep-until-expiring', *certbot_args())
    load_certificate()
    run('haproxy', '-c', '-f', str(generation / 'haproxy.cfg'), capture=True)
    activate(generation)
    run('systemctl', 'enable', '--now', 'matrixrtc-renew.timer')
    summary(c)

def update(component, version, digest):
    if component not in REPOS:
        fail('Component must be livekit, auth, or redis.')
    old = (ROOT / 'current').resolve()
    c = read(old / 'settings.json')
    firewall(c)
    before = c[component + '_version']
    with tempfile.TemporaryDirectory(dir=ROOT, prefix='.drift-check-') as tmp:
        render(c, read(ROOT/'secrets.json'), tmp)
        for relative in ('livekit.yaml','auth.env','redis.conf','haproxy.cfg','guard.nft',
                         'quadlets/matrixrtc-livekit.container','quadlets/matrixrtc-auth.container','quadlets/matrixrtc-redis.container'):
            if (Path(tmp)/relative).read_bytes() != (old/relative).read_bytes():
                fail('Active generated configuration has manual changes. Reconcile them before updating; they will not be overwritten.')
    pattern = r'v?(\d+)\.(\d+)\.(\d+)(-alpine)?'
    a, b = re.fullmatch(pattern, before), re.fullmatch(pattern, version)
    if not b or a.group(1, 2, 4) != b.group(1, 2, 4) or int(b[3]) <= int(a[3]):
        fail('Only a strictly newer patch within the installed major.minor and variant is supported. Major/minor migrations need a revised integration/configuration audit.')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        fail('Supply the reviewed multi-architecture SHA-256 manifest digest.')
    observed=run('skopeo','inspect','--format','{{.Digest}}','docker://'+REPOS[component]+':'+version,capture=True).stdout.strip()
    if observed != digest:
        fail('The requested release tag does not resolve to the supplied digest. Review the upstream release before updating.')
    print(f'Update {component}: {before} -> {version}. LiveKit interrupts calls; auth/Redis briefly interrupt token/leave management.')
    if component in ('redis','auth'):
        print('This component may modify persistent jobs/data. No automatic stateful-component rollback. Take a VPS snapshot first.')
    with open('/dev/tty') as tty:
        print('Type UPDATE to proceed: ', end='', flush=True)
        if tty.readline().strip() != 'UPDATE':
            fail('Cancelled.')
    c[component + '_version'], c[component + '_digest'] = version, digest
    c = acquire_images(c)
    new = ROOT / 'releases' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3))
    render(c, read(ROOT / 'secrets.json'), new)
    stage_probe(c, new)
    run('haproxy', '-c', '-f', str(new / 'haproxy.cfg'), capture=True)
    activate(new, old, component)
    atomic(ROOT / 'site.json', json.dumps(c, indent=2) + '\n')
    print('Update committed. Old configuration/image pins retained; no unattended component update exists.')

def summary(c):
    print(f"""
MATRIX CALLING BACKEND

  Matrix identity: {c['MATRIX_SERVER_NAME']} (unchanged, on the existing server)
  Authorization:  https://{c['RTC_HOST']}/livekit/jwt
  Health URL:     https://{c['RTC_HOST']}/livekit/jwt/healthz
  LiveKit signal: wss://{c['RTC_HOST']}/livekit/sfu
  TURN/TLS:       turns:{c['TURN_HOST']}:443?transport=tcp
  Full access:    {c['FULL_ACCESS_HOMESERVERS']}
  Remote users:   may join existing SFU rooms; may not create them.
  Mode:           client-direct OpenID, authorization service 0.6.x.
  App timezone:   {c['APP_TZ']} (host timezone preserved)

DNS (DNS only; these point directly to this VPS)
  {c['RTC_HOST']}   A     {c['PUBLIC_IPV4']}
  {c['TURN_HOST']}   A     {c['PUBLIC_IPV4']}
""")
    if c['PUBLIC_IPV6']:
        for host in (c['RTC_HOST'], c['TURN_HOST']):
            print(f"  {host}   AAAA  {c['PUBLIC_IPV6']}")
    else:
        print('  AAAA: none. IPv6 is not enabled for this deployment.')
    print(f"""
PORTS (inbound UFW and Hetzner Cloud Firewall)
  TCP 80                 ACME HTTP-01
  TCP 443                HTTPS and TURN/TLS
  TCP {c['ICE_TCP_PORT']}             direct ICE/TCP
  UDP {c['MEDIA_UDP_PORT']}             direct media multiplexing
  UDP {c['TURN_UDP_PORT']}             TURN/UDP
  UDP {c['RELAY_FIRST']}-{c['RELAY_LAST']}      TURN relay sockets
  SSH: preserve the existing port and management-source restrictions.
  Internal TCP {c['TURN_INTERNAL_PORT']} is plaintext TURN: NEVER permit externally.

COMMANDS — VPS
  sudo matrixrtc-maint status
  sudo matrixrtc-maint check
  sudo matrixrtc-maint firewall-check
  sudo matrixrtc-maint firewall-repair
  sudo matrixrtc-maint proxy-repair
  sudo matrixrtc-maint versions
  sudo matrixrtc-maint update livekit v1.13.X sha256:<reviewed-index-digest>
  sudo matrixrtc-maint renew
  sudo matrixrtc-maint renewal-test
  sudo journalctl -u matrixrtc-livekit -u matrixrtc-auth -u matrixrtc-edge -n 80

FILES
  /etc/matrixrtc/current/       active generated configuration and image pins
  /etc/matrixrtc/releases/      recoverable previous configuration revisions
  /etc/matrixrtc/secrets.json   credentials, root only; never share
  /etc/matrixrtc/host-policy.json  retained host firewall profile, when present
  /etc/matrixrtc/acme/          ACME account and certificates
  /var/lib/matrixrtc/redis/     persistent delegated-leave jobs
  /usr/local/lib/matrixrtc/     maintenance implementation
  /etc/containers/systemd/     matrixrtc-* Quadlets

NEXT — EXISTING MATRIX SERVER
  MATRIX_RTC_AUTH_URL=\"https://{c['RTC_HOST']}/livekit/jwt\"
  MATRIX_RTC_HEALTH_URL=\"https://{c['RTC_HOST']}/livekit/jwt/healthz\"
  Apply the separate existing-Matrix integration helper/guide locally there.
  Editing creator variables or /opt/matrix/.env alone has no runtime effect.
  Component updates are manual. Only certificate renewal is scheduled.
  HTTP checks do not prove calling: test two networks and forced TURN/TLS.

LATER HARDENING RUNS
  sudo env ENABLE_UFW=0 /usr/local/sbin/phase2-hardening.sh
  This skips firewall changes and leaves UFW active.
  A default phase-2 rerun resets RTC rules. Restore them afterwards with:
  sudo matrixrtc-maint firewall-repair
  sudo matrixrtc-maint check
""")

def main():
    command = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if command == 'validate':
        c = validate(read(sys.argv[2])); atomic(sys.argv[2], json.dumps(c, indent=2) + '\n'); return
    if command == 'render-test':
        render(validate(read(sys.argv[2])), read(sys.argv[3]), sys.argv[4]); return
    if command in ('preflight','ports'):
        c = validate(read(sys.argv[2]))
        (network if command == 'preflight' else ports)(c); return
    if command == 'phase2-ready':
        phase2_ready(initial=len(sys.argv) < 3 or sys.argv[2] != 'installed'); return
    if command == 'firewall-apply-staged':
        if os.geteuid() != 0:
            fail('Run with sudo or as root.')
        firewall(validate(read(sys.argv[2])), apply=True); return  # installer owns lock
    if os.geteuid() != 0:
        fail('Run with sudo or as root.')
    if command in ('guard','wait-redis'):
        (guard if command == 'guard' else wait_redis)(); return  # systemd caller owns lock
    with open('/run/lock/matrixrtc.lock', 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('Another MatrixRTC operation is running. Retry after it finishes.')
        if command == 'install':
            install(read(ROOT / 'site.json')); return
        c = validate(read(ROOT / 'current/settings.json'))
        if command == 'check':
            network(c); checks(c)
        elif command == 'firewall-check':
            firewall(c)
        elif command == 'firewall-repair':
            guard()
            firewall(c, apply=True)
            print('Private listener guard and RTC UFW rules restored; application services were not restarted.')
        elif command == 'proxy-repair':
            proxy_repair(c)
        elif command == 'refresh-host-integration' and len(sys.argv) == 3:
            if sys.argv[2] not in ('phase2', 'generic'):
                fail('Unknown hardening profile.')
            if sys.argv[2] == 'phase2':
                phase2_ready(initial=False)
            guard()
            firewall(c, apply=True)
            atomic(ROOT / 'host-policy.json', json.dumps({'FIREWALL_POLICY': 'ufw', 'HARDENING_PROFILE': sys.argv[2]}) + '\n')
            atomic('/usr/local/lib/matrixrtc/manage.py', Path(__file__).read_text(), 0o700)
            print('Maintenance controller refreshed. Active images, generated service configuration, credentials and running calls were retained.')
            summary(c)
        elif command == 'network':
            network(c)
        elif command == 'status':
            summary(c)
            subprocess.run(['systemctl', '--no-pager', '--full', 'status', *[s + '.service' for s in SERVICES], 'matrixrtc-renew.timer'])
        elif command == 'versions':
            for name in REPOS:
                print(name, c[name + '_version'], REPOS[name] + '@' + c[name + '_digest'])
            run('dpkg-query', '-W', 'podman', 'haproxy', 'certbot', 'nftables')
        elif command == 'update' and len(sys.argv) == 5:
            update(*sys.argv[2:])
        elif command in ('renew', 'renewal-test'):
            args = ['certbot', 'renew', '--cert-name', 'matrixrtc', '--non-interactive', *certbot_args()]
            if command == 'renewal-test':
                args += ['--dry-run']
            run(*args)
            if command == 'renew':
                load_certificate()
        else:
            fail('Usage: matrixrtc-maint {status|versions|check|firewall-check|firewall-repair|proxy-repair|renew|renewal-test|update COMPONENT VERSION SHA256-DIGEST}')

if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as e:
        # Avoid printing subprocess arguments or structured configuration with credentials.
        if isinstance(e, subprocess.CalledProcessError):
            print('ERROR: a required command failed. Inspect the relevant private service logs.', file=sys.stderr)
        else:
            print('ERROR:', str(e) or 'Interrupted', file=sys.stderr)
        sys.exit(1)
PY_MANAGER
chmod 0700 "$TEMP_DIR/manage.py"
python3 "$TEMP_DIR/manage.py" validate "$TEMP_DIR/site.json"
if (( INSTALLED )); then
    echo
    echo 'ROUTES: back up and correct the recognized old LiveKit proxy routes, validate and reload HAProxy,'
    echo '        verify legacy/v1 endpoints and refresh maintenance. Images, credentials and firewall stay as saved.'
    echo 'REPAIR: refresh maintenance and restore RTC firewall rules; no application restart or route change.'
    echo '        UFW must already be active. SSH policy and host hardening are preserved.'
    read -r -p 'Type ROUTES or REPAIR, or press Enter to show existing status: ' answer <&8
    if [[ $answer == ROUTES ]]; then
        flock -u 9
        python3 "$TEMP_DIR/manage.py" proxy-repair
    elif [[ $answer == REPAIR ]]; then
        profile=generic
        (( ! REQUIRE_PHASE2 )) || profile=phase2
        flock -u 9
        python3 "$TEMP_DIR/manage.py" refresh-host-integration "$profile"
    else
        flock -u 9
        /usr/local/bin/matrixrtc-maint status
    fi
    exit 0
fi
if (( REQUIRE_PHASE2 )); then
    python3 "$TEMP_DIR/manage.py" phase2-ready
fi
# Restore all validated effective settings, including values retained on partial reruns.
while IFS=$'\t' read -r name value; do
    printf -v "$name" '%s' "$value"
done < <(python3 - "$TEMP_DIR/site.json" <<'PY_VALUES'
import json,sys
for k,v in json.load(open(sys.argv[1])).items():
    if k.isupper():print(k+'\t'+str(v))
PY_VALUES
)

python3 "$TEMP_DIR/manage.py" preflight "$TEMP_DIR/site.json"
if [[ -n $PUBLIC_IPV6 ]]; then
    echo 'IPv6 is explicitly configured. Both DNS names must already have the matching AAAA.'
    echo 'Confirm this assigned address has working inbound AND outbound IPv6 from an external network.'
    read -r -p 'Type IPV6-TESTED to confirm, or Ctrl-C and clear PUBLIC_IPV6/remove AAAA: ' answer <&8
    [[ $answer == IPV6-TESTED ]] || { echo 'Cancelled IPv6 deployment.'; exit 1; }
fi
if command -v nft >/dev/null && nft list table inet matrixrtc_guard > "$TEMP_DIR/guard.txt" 2>/dev/null; then
    if [[ $PARTIAL -ne 1 ]] || ! grep -q 'Owned by matrixrtc-debian13-installer' "$TEMP_DIR/guard.txt"; then
        echo 'ERROR: Unowned nftables table matrixrtc_guard exists.' >&2; exit 1
    fi
fi

echo
echo 'VPS RESOURCES (detected; no participant-capacity guarantee)'
printf '  Architecture: %s\n  CPUs: %s\n' "$ARCH" "$(getconf _NPROCESSORS_ONLN)"
awk '/MemTotal:/ {printf "  RAM: %.1f GiB\n",$2/1048576}' /proc/meminfo
df -h / /var/lib
echo
echo 'EXISTING SSH LISTENERS AND FIREWALL POLICY'
ss -ltnp | awk 'NR==1 || /sshd|systemd/'
if command -v sshd >/dev/null; then
    sshd -T 2>/dev/null | awk '$1=="port" || $1=="listenaddress" {print "  " $0}' || true
fi
FIREWALL_POLICY=external
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    FIREWALL_POLICY=ufw
    ufw status verbose
    if [[ -n $PUBLIC_IPV6 ]] && ! grep -Eq '^IPV6=yes$' /etc/default/ufw; then
        echo 'ERROR: Active UFW does not manage IPv6. Configure it safely before enabling VPS IPv6.' >&2; exit 1
    fi
    echo 'Only destination-specific application allow rules will be added. SSH rules and sources are preserved.'
else
    echo 'UFW is inactive or absent. This installer will not enable it.'
    echo 'Use the existing host firewall and Hetzner Cloud Firewall with the table below.'
    echo 'A separate nftables guard will always block private MatrixRTC TCP listeners off loopback.'
fi
python3 - "$TEMP_DIR/site.json" "$FIREWALL_POLICY" "$REQUIRE_PHASE2" <<'PY_HOST_POLICY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); c=json.loads(p.read_text())
c['FIREWALL_POLICY']=sys.argv[2]
c['HARDENING_PROFILE']='phase2' if sys.argv[3]=='1' else 'generic'
p.write_text(json.dumps(c,indent=2)+'\n')
PY_HOST_POLICY
echo
printf 'DNS — both names must be DNS only (no ordinary Cloudflare HTTP proxy):\n'
printf '  %-40s A     %s\n' "$RTC_HOST" "$PUBLIC_IPV4" "$TURN_HOST" "$PUBLIC_IPV4"
if [[ -n $PUBLIC_IPV6 ]]; then
    printf '  %-40s AAAA  %s\n' "$RTC_HOST" "$PUBLIC_IPV6" "$TURN_HOST" "$PUBLIC_IPV6"
else
    echo '  AAAA records: none'
fi
cat <<SUMMARY

HETZNER / UFW — inbound to this VPS, from clients on the internet
  TCP 80,443             certificate issuance; HTTPS and TURN/TLS
  TCP $ICE_TCP_PORT                 direct ICE/TCP
  UDP $MEDIA_UDP_PORT                 direct multiplexed media
  UDP $TURN_UDP_PORT                 authenticated TURN/UDP
  UDP $RELAY_FIRST-$RELAY_LAST          TURN relay sockets
  SSH                    retain the existing port and trusted management sources
  ICMP / ICMPv6          retain required diagnostics and path-MTU/IPv6 control traffic
  Internal TCP $TURN_INTERNAL_PORT      never expose: plaintext TURN behind TLS termination

  Matrix server_name: $MATRIX_SERVER_NAME
  Public homeserver:  $HOMESERVER_URL
  Calling origin:     $RTC_HOST
  TURN TLS origin:    $TURN_HOST
  App timezone:       $APP_TZ
  Full-access users:  $FULL_ACCESS_HOMESERVERS
  Federated policy:   other origins may join existing rooms, but cannot create rooms.
  Client-direct mode does not independently verify Matrix room invitations.
  No wildcard room creation; LiveKit room.auto_create is disabled.

Only this VPS will be provisioned. Existing home ingress and Matrix identity stay in place.
Packages: ${PACKAGES[*]}
Application containers are pinned to reviewed multi-architecture SHA-256 manifests.
No OS full-upgrade, hostname/resolver/SSH change, reboot, or component auto-update.
Your cloud-init and phase-2 hardening files, sysctls and UFW defaults are preserved.
Later hardening runs: sudo env ENABLE_UFW=0 /usr/local/sbin/phase2-hardening.sh
After an intentional phase-2 firewall reset: sudo matrixrtc-maint firewall-repair
ACME Terms of Service will be accepted for $ACME_EMAIL after confirmation.
SUMMARY
read -r -p 'Confirm Hetzner/existing firewall rules are ready: type FIREWALL-READY: ' answer <&8
[[ $answer == FIREWALL-READY ]] || { echo 'Cancelled before provisioning.'; exit 1; }
if [[ $FIREWALL_POLICY == external ]]; then
    read -r -p 'Keep UFW inactive and rely on the reviewed external/existing firewall: type EXTERNAL: ' answer <&8
    [[ $answer == EXTERNAL ]] || { echo 'Cancelled before provisioning.'; exit 1; }
fi
read -r -p 'Install/resume the calling backend on this VPS? Type INSTALL: ' answer <&8
[[ $answer == INSTALL ]] || { echo 'Cancelled before provisioning.'; exit 1; }

# PHASE 3 — stop a partial attempt only; check real port availability before APT.
if (( PARTIAL )); then
    systemctl stop matrixrtc-auth.service matrixrtc-livekit.service matrixrtc-redis.service matrixrtc-edge.service matrixrtc-acme-http.service || true
fi
python3 "$TEMP_DIR/manage.py" ports "$TEMP_DIR/site.json"
HAPROXY_WAS_INSTALLED=0
if dpkg-query -W -f='${db:Status-Status}' haproxy 2>/dev/null | grep -qx installed; then HAPROXY_WAS_INSTALLED=1; fi
# Respect an existing policy-rc.d. Otherwise temporarily suppress package service
# starts, preventing the distribution's default HAProxy instance from taking :80.
if [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    POLICY_CREATED=1
fi
apt-get update
for package in "${PACKAGES[@]}"; do
    candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
    [[ -n $candidate && $candidate != '(none)' ]] || { echo "ERROR: Debian repositories have no candidate for $package. Repository configuration was not changed." >&2; exit 1; }
done
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${PACKAGES[@]}"
if (( ! HAPROXY_WAS_INSTALLED )); then systemctl disable --now haproxy.service; fi
if (( POLICY_CREATED )); then rm -f /usr/sbin/policy-rc.d; POLICY_CREATED=0; fi
haproxy -v | head -1
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' podman)" ge 5.4 || { echo 'ERROR: Podman >=5.4 is required.' >&2; exit 1; }
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' haproxy)" ge 3.0 || { echo 'ERROR: HAProxy >=3.0 is required.' >&2; exit 1; }

# PHASE 4 — owned directories, saved settings and once-only credentials.
install -d -m 0700 "$ROOT_DIR" "$ROOT_DIR/releases" "$ROOT_DIR/tls" "$LIB_DIR"
install -d -m 0755 "$DATA_DIR" "$DATA_DIR/acme-web" /etc/containers/systemd
install -d -m 0700 "$DATA_DIR/redis"
# site.json is committed before the ownership marker so recovery always has inputs.
install -m 0600 "$TEMP_DIR/site.json" "$ROOT_DIR/site.json.next"
mv -fT "$ROOT_DIR/site.json.next" "$ROOT_DIR/site.json"
printf 'matrixrtc-debian13-installer-v1\n' > "$ROOT_DIR/managed-by-matrixrtc"
chmod 0600 "$ROOT_DIR/managed-by-matrixrtc"
python3 - "$ROOT_DIR" <<'PY_SECRETS'
import json,os,pathlib,re,secrets,sys,tempfile
p=pathlib.Path(sys.argv[1]);f=p/'secrets.json'
if f.exists():
    if f.is_symlink() or f.stat().st_uid!=0 or f.stat().st_mode & 0o077:raise SystemExit('ERROR: secrets.json must be a root-only regular file.')
    s=json.loads(f.read_text())
    if set(s)!= {'livekit_key','livekit_secret','redis_password'} or any(not isinstance(v,str) or not re.fullmatch(r"[0-9a-f]{64}",v) for v in s.values()):raise SystemExit('ERROR: Existing secret state is incomplete; refusing to rotate credentials.')
else:
    s={k:secrets.token_hex(32) for k in ('livekit_key','livekit_secret','redis_password')}
    fd,t=tempfile.mkstemp(dir=p)
    with os.fdopen(fd,'w') as out:json.dump(s,out);out.flush();os.fsync(out.fileno())
    os.chmod(t,0o600);os.replace(t,f)
for name,key in [('key','livekit_key'),('secret','livekit_secret')]:
    target=p/name
    if target.exists():
        if target.read_text()!=s[key]:raise SystemExit('ERROR: Credential file mismatch; refusing to overwrite.')
    else:
        fd,t=tempfile.mkstemp(dir=p)
        with os.fdopen(fd,'w') as out:out.write(s[key]);out.flush();os.fsync(out.fileno())
        os.chmod(t,0o600);os.replace(t,target)
PY_SECRETS
install -m 0700 "$TEMP_DIR/manage.py" "$LIB_DIR/manage.py.next"
mv -fT "$LIB_DIR/manage.py.next" "$LIB_DIR/manage.py"
printf '#!/bin/sh\nexec /usr/local/lib/matrixrtc/manage.py "$@"\n' > "$TEMP_DIR/matrixrtc-maint"
install -m 0755 "$TEMP_DIR/matrixrtc-maint" /usr/local/bin/matrixrtc-maint

# PHASE 5 — preserve UFW's state and existing management rules.
if [[ $FIREWALL_POLICY == ufw ]]; then
    python3 "$TEMP_DIR/manage.py" firewall-apply-staged "$ROOT_DIR/site.json"
fi

# PHASE 6 — immutable pulls, configuration staging, bootstrap ACME and activation.
# The maintenance controller uses the same lock; release this descriptor before it
# takes over. All persistent application mutations from here are serialized there.
flock -u 9
python3 "$LIB_DIR/manage.py" install
echo 'Installation completed. Use the separate integration guide on the existing Matrix server.'
