#!/usr/bin/env bash
# MatrixRTC companion backend for a plain Debian 13 Hetzner Cloud VPS.
# Research baseline: 2026-09-09. Run locally on the VPS; never on the Matrix host.
# This file contains all generated maintenance/configuration code. No remote deployment.
# Revision 7 (2026-09-17): Redis process-title-aware timezone verification.
# Run debian-hardening.sh v1.0.3 first; confirm fresh administrator SSH and sudo.
# Run this file locally on the hardened native VPS: sudo bash matrix-rtc.sh.
# Host policy stays owned by Debian hardening. This file never downloads/sources it.
# Fresh installs only. Completed revision-5/6/7 reruns check without changing state.
# Older or incomplete installations are preserved for read-only diagnosis.
# No host-policy reset, automatic repair, secret rotation, image pruning or reboot.
# Managed paths: /etc/matrixrtc/{site.json,secrets.json,key,secret,releases,current,
# edge.cfg,managed-by-matrixrtc,installed,tls,acme}; /var/lib/matrixrtc/{redis,
# acme-web,certbot}; /var/log/matrixrtc-acme; /usr/local/lib/matrixrtc/manage.py;
# /usr/local/bin/matrixrtc-maint; /etc/containers/systemd/matrixrtc-*.container;
# /etc/systemd/system/matrixrtc-{edge,guard,acme-http,renew}.service and renew.timer.
# UFW: append only destination-specific RTC allows; preserve SSH and other rules.
# nftables: only the owned inet matrixrtc_guard table/service; no nftables.service.
# Images/entrypoints/root identities are preserved from revision 4; no version bump.
# Only certificate renewal is scheduled. Persistent data requires an external backup.
# Bootstrap: Matrix must first be running through its public NPM/Cloudflare route.
# The companion Matrix creator permits planned RTC URLs before RTC is installed.
set -Eeo pipefail
umask 022
export LC_ALL=C LANG=C SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset PYTHONPATH PYTHONHOME BASH_ENV ENV CDPATH MATRIXRTC_INSTALL_LOCK_FD

# CONFIGURATION — empty site values prompt. Existing site.json wins on a rerun.
MATRIX_SERVER_NAME=""              # permanent Matrix identity, e.g. matrix.your-domain.tld
HOMESERVER_URL=""                  # public Synapse HTTPS origin, e.g. https://matrix.your-domain.tld
RTC_HOST=""                        # DNS-only hostname pointing directly to this VPS
TURN_HOST=""                       # distinct DNS-only hostname, same VPS
PUBLIC_IPV4=""                     # directly assigned IPv4; a single detected address is suggested
PUBLIC_IPV6=""                     # opt-in only; do not publish AAAA unless externally tested
ACME_EMAIL=""
APP_TZ=""                          # derived from the hardened VPS; not an independent setting
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
START_WAIT_SECONDS=180             # readiness budget, 30..86400 seconds
STABILITY_SECONDS=30               # observation window, 30..300 seconds
LIVEKIT_VERSION="v1.13.6"
LIVEKIT_DIGEST="sha256:e37d68f172556d02aa77968b9fc55ef481468c0315fa38e4fa6c56ce72e3a815"
AUTH_VERSION="0.6.0"
AUTH_DIGEST="sha256:822f0c03a3bdd924da92afc2e8ec59de5dda17af42d32e71e11f269c3517abf7"
REDIS_VERSION="8.2.6-alpine"
REDIS_DIGEST="sha256:ea5a07305d6c66f99df5a5ff8d9659e8f6cb598e6e586dc8dd92b7fcd915746e"
# Package versions follow Debian 13 security updates; no custom proxy build/module.
PACKAGES=(podman skopeo haproxy certbot python3 python3-yaml ca-certificates curl nftables iproute2 openssl)
APT_LOCK_TIMEOUT=300               # bounded dpkg lock wait
ROOT_DIR="/etc/matrixrtc"           # fixed in the embedded maintenance code
DATA_DIR="/var/lib/matrixrtc"
LIB_DIR="/usr/local/lib/matrixrtc"

# PHASE 1 — operating-system, ownership and interactive preflight (read-only).
[[ $EUID -eq 0 ]] || { echo 'ERROR: Run this file with sudo bash, or as root, on the Debian VPS.' >&2; exit 1; }
[[ -f /etc/os-release ]] || { echo 'ERROR: Missing /etc/os-release.' >&2; exit 1; }
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]] || { echo 'ERROR: This installer supports plain Debian 13 only.' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo 'ERROR: systemd must run as PID 1.' >&2; exit 1; }
[[ $# == 0 ]] || { echo 'Usage: sudo bash matrix-rtc.sh (edit the top configuration first).' >&2; exit 2; }
INSTALL_STAGE=preflight
trap 'rc=$?; trap - ERR; printf "ERROR: stage=%s rc=%s line=%s. Command arguments omitted; VPS state preserved.\n" "$INSTALL_STAGE" "$rc" "$LINENO" >&2; exit "$rc"' ERR
for command in python3 ip ss flock dpkg dpkg-query apt-get apt-cache systemctl timedatectl \
    systemd-detect-virt mktemp install mv chmod readlink stat getconf awk df grep cp cat rm head ufw iptables ip6tables; do
    command -v "$command" >/dev/null || { echo "ERROR: Missing prerequisite: $command" >&2; exit 1; }
done
[[ $(systemd-detect-virt --container || true) == none && ! -d /etc/pve ]] || {
    echo 'ERROR: RTC requires a native Debian VPS/VM, not a container or Proxmox host.' >&2; exit 1;
}
[[ -x /usr/local/sbin/debian-hardening-check && -f /var/lib/debian-hardening/policy.json ]] || {
    echo 'ERROR: Run debian-hardening.sh v1.0.3 and confirm SSH/sudo access first.' >&2; exit 1;
}
[[ $APT_LOCK_TIMEOUT =~ ^[1-9][0-9]{0,3}$ ]] || { echo 'ERROR: Invalid APT_LOCK_TIMEOUT.' >&2; exit 1; }
[[ -z $(dpkg --audit) ]] || { echo 'ERROR: An incomplete package transaction needs inspection.' >&2; exit 1; }
ARCH=$(dpkg --print-architecture)
[[ $ARCH == amd64 || $ARCH == arm64 ]] || { echo "ERROR: Unsupported architecture: $ARCH" >&2; exit 1; }
[[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || { echo 'ERROR: Quadlet requires cgroup v2.' >&2; exit 1; }
exec 9>/run/lock/matrixrtc.lock
flock -n 9 || { echo 'ERROR: Another MatrixRTC operation is running.' >&2; exit 1; }
exec 7>/run/lock/debian-hardening-install.lock
flock -n 7 || { echo 'ERROR: Debian hardening is still running.' >&2; exit 1; }
export MATRIXRTC_INSTALL_LOCK_FD=7
exec 8<>/dev/tty || { echo 'ERROR: An interactive terminal is required. Download the script and run it locally.' >&2; exit 1; }
TEMP_DIR=$(mktemp -d /tmp/matrixrtc-install.XXXXXXXX)
POLICY_CREATED=0
rc=0
trap 'rc=$?; trap - EXIT; if (( POLICY_CREATED )); then rm -f /usr/sbin/policy-rc.d; fi; rm -rf -- "$TEMP_DIR"; if (( rc )); then echo "ERROR: Installation stopped (exit $rc). No credentials or existing data were deleted. Inspect the reported stage and private logs." >&2; fi; exit "$rc"' EXIT
trap 'echo "Interrupted during $INSTALL_STAGE; VPS state preserved." >&2; exit 130' INT
trap 'echo "Terminated during $INSTALL_STAGE; VPS state preserved." >&2; exit 143' TERM
trap 'echo "Disconnected during $INSTALL_STAGE; VPS state preserved." >&2; exit 129' HUP

INSTALLED=0
if [[ -e $ROOT_DIR || -L $ROOT_DIR ]]; then
    [[ -d $ROOT_DIR && ! -L $ROOT_DIR && -f $ROOT_DIR/managed-by-matrixrtc ]] || { echo "ERROR: Refusing to take over $ROOT_DIR." >&2; exit 1; }
    [[ $(stat -c '%u:%a' "$ROOT_DIR") == 0:700 ]] || { echo 'ERROR: Existing /etc/matrixrtc must be root-owned, mode 0700.' >&2; exit 1; }
    if [[ -f $ROOT_DIR/installed ]]; then
        INSTALLED=1
        [[ -f $ROOT_DIR/current/settings.json ]] || { echo 'ERROR: Installed backend has no active settings.' >&2; exit 1; }
        cp "$ROOT_DIR/current/settings.json" "$TEMP_DIR/site.json"
        echo 'Installed backend found. Saved active settings and image versions will be retained.'
    else
        echo 'ERROR: An incomplete RTC installation exists. Its state is preserved; inspect it before any new installation.' >&2
        exit 1
    fi
else
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
    echo 'Use RTC and TURN service names distinct from the VPS machine FQDN.'
    echo 'Example: machine vps01.your-domain.tld; services rtc.your-domain.tld and turn.your-domain.tld.'
    if [[ -z $APP_TZ ]]; then
        APP_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        [[ -n $APP_TZ ]] || { echo 'ERROR: Could not read the hardened VPS timezone.' >&2; exit 1; }
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
import stat
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo
import urllib.error
import urllib.parse
import urllib.request

os.environ['SYSTEMD_COLORS'] = '0'
os.environ['SYSTEMD_PAGER'] = 'cat'
os.environ['LC_ALL'] = 'C'  # stable UFW/status parsing on non-English hosts
os.environ['PATH'] = '/usr/sbin:/usr/bin:/sbin:/bin'
ROOT = Path('/etc/matrixrtc')
DATA = Path('/var/lib/matrixrtc')
SERVICES = ['matrixrtc-redis', 'matrixrtc-livekit', 'matrixrtc-auth', 'matrixrtc-edge']
CHECK_SERVICES = SERVICES + ['matrixrtc-guard', 'matrixrtc-acme-http']
HOST_STATE = Path('/var/lib/debian-hardening')
HOST_VERSION = '1.0.3'
SCHEMA = 2
REPOS = {'livekit': 'docker.io/livekit/livekit-server',
         'auth': 'ghcr.io/element-hq/lk-jwt-service', 'redis': 'docker.io/library/redis'}
LEGACY_SFU_ACL = '    acl sfu_path path -m str /livekit/sfu/rtc /livekit/sfu/rtc/validate\n'
SFU_ACL = LEGACY_SFU_ACL.rstrip('\n') + ' /livekit/sfu/rtc/v1 /livekit/sfu/rtc/v1/validate\n'
SFU_VALIDATION_PATHS = ('/livekit/sfu/rtc/validate', '/livekit/sfu/rtc/v1/validate')

def fail(message):
    raise RuntimeError(message)

def run(*args, capture=False, **kw):
    kw.setdefault('timeout', 120)
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

def safe_file(path, private=False, nonempty=True):
    path = Path(path)
    st = path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & (0o077 if private else 0o022):
        fail(f'Unsafe control file: {path}; uid={st.st_uid} mode={stat.S_IMODE(st.st_mode):04o}.')
    if nonempty and not st.st_size:
        fail(f'Empty control file: {path}.')
    return path

def safe_dir(path, private=False):
    path = Path(path)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != 0 or st.st_mode & (0o077 if private else 0o022):
        fail(f'Unsafe control directory: {path}.')
    return path

@contextlib.contextmanager
def host_lock():
    path = '/run/lock/debian-hardening-install.lock'
    inherited = os.environ.get('MATRIXRTC_INSTALL_LOCK_FD')
    handle = None
    try:
        if inherited is not None:
            if inherited != '7':
                fail('Invalid inherited installer lock.')
            fd = 7
            a, b = os.fstat(fd), os.stat(path)
            if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                fail('Inherited installer lock has the wrong identity.')
        else:
            handle = open(path, 'a')
            fd = handle.fileno()
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('Debian hardening is running; RTC cannot overlap host-policy changes.')
        yield
    finally:
        if handle:
            handle.close()

def host_ready(c=None, audit=True):
    """Require the completed native baseline; never apply or recover it here."""
    safe_dir(HOST_STATE, private=True)
    for marker in (HOST_STATE / 'pending', Path('/var/lib/hetzner-hardening/pending')):
        if marker.exists() or marker.is_symlink():
            fail('Host access recovery is pending. RTC makes no changes during that transaction.')
    policy = read(safe_file(HOST_STATE / 'policy.json', private=True))
    if policy.get('version') != HOST_VERSION or policy.get('ufw') is not True or not policy.get('hashes'):
        fail('Complete the supplied Debian hardening v1.0.3 with UFW enabled before RTC.')
    # policy.json exists before access confirmation: match the sealed transaction.
    confirmed = False
    for transaction in HOST_STATE.glob('run-*'):
        safe_dir(transaction, private=True)
        if not (transaction / 'confirmed').exists() or (transaction / 'recovered').exists():
            continue
        safe_file(transaction / 'confirmed', private=True)
        if read(safe_file(transaction / 'policy.json', private=True)) == policy:
            confirmed = True
            break
    if not confirmed:
        fail('No confirmed SSH/sudo transaction matches the current hardening policy.')
    for unit in ('firewalld.service', 'nftables.service', 'netfilter-persistent.service'):
        state = run('systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'UnitFileState', capture=True).stdout
        fields = dict(x.split('=', 1) for x in state.splitlines() if '=' in x)
        if fields.get('ActiveState') in ('active', 'activating') or fields.get('UnitFileState') in ('enabled', 'enabled-runtime'):
            fail(f'Competing host firewall manager: {unit}. RTC does not change its policy.')
    expected_zone = policy['timezone']['before'] if policy['timezone']['preserve'] else policy['timezone']['requested']
    actual_zone = run('timedatectl', 'show', '-p', 'Timezone', '--value', capture=True).stdout.strip()
    if actual_zone != expected_zone or (c is not None and c['APP_TZ'] != actual_zone):
        fail('Host policy, effective timezone and application timezone disagree; no timezone was changed.')
    if c is not None:
        reserved = {c[k] for k in ('HTTP_PORT', 'HTTPS_PORT', 'ICE_TCP_PORT', 'LIVEKIT_PORT',
                                  'AUTH_PORT', 'TURN_INTERNAL_PORT', 'EDGE_HTTP_PORT', 'ACME_PORT', 'REDIS_PORT')}
        if policy['ssh_port'] in reserved:
            fail('An RTC TCP port conflicts with the preserved SSH port.')
    if audit:
        for path in ('/usr/local/sbin/debian-hardening-check', '/usr/local/lib/debian-hardening/core.py',
                     '/usr/local/lib/debian-hardening/postfix-check.py'):
            safe_file(path)
        report = json.loads(run('/usr/local/sbin/debian-hardening-check', capture=True, timeout=240).stdout)
        if report.get('status') not in ('OK', 'WARN') or report.get('errors'):
            fail('Debian hardening audit did not pass.')
        print('Debian hardening: ' + report['status'])
        for warning in report.get('warnings', []):
            print('  WARN: ' + warning)
    return policy

def host_snapshot(policy):
    paths = set(policy['hashes']) | {str(HOST_STATE / 'policy.json'), '/etc/ssh/sshd_config',
        '/etc/sudoers', '/etc/localtime', '/etc/timezone', '/etc/default/ufw', '/etc/ufw/ufw.conf'}
    snapshot = {}
    for name in sorted(paths):
        p = Path(name)
        if p.exists():
            snapshot[name] = [str(p.resolve()), hashlib.sha256(p.read_bytes()).hexdigest(),
                              p.stat().st_uid, stat.S_IMODE(p.stat().st_mode)]
        else:
            snapshot[name] = None
    return snapshot

def assert_host_preserved(before, policy):
    if before != host_snapshot(policy):
        fail('Host hardening/access/timezone files changed during the RTC operation; inspect the preserved VPS.')
    host_ready(audit=True)

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
    if not 30 <= c['STABILITY_SECONDS'] <= 300 or not 30 <= c['START_WAIT_SECONDS'] <= 86400:
        fail('Startup budget must be 30..86400 and stability window 30..300 seconds.')
    for name in REPOS:
        if not re.fullmatch(r'v?\d+\.\d+\.\d+(?:-alpine)?', c[name + '_version']):
            fail(f'{name}: use a full stable release version.')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', c[name + '_digest']):
            fail(f'{name}: provide an immutable manifest digest.')
    for name, prefix in [('livekit', 'v1.13.'), ('auth', '0.6.'), ('redis', '8.2.')]:
        if not c[name + '_version'].startswith(prefix):
            fail(f'{name}: this implementation has been reviewed only for the {prefix}x series.')
    c['PUBLIC_IPV4'] = str(ipaddress.ip_address(c['PUBLIC_IPV4']))
    if c['PUBLIC_IPV6']:
        c['PUBLIC_IPV6'] = str(ipaddress.ip_address(c['PUBLIC_IPV6']))
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
    discovery = json.loads(body)
    if status != 200 or discovery.get('m.homeserver', {}).get('base_url', '').rstrip('/') != home:
        fail('Matrix client discovery does not point to HOMESERVER_URL.')
    expected_focus = 'https://' + c['RTC_HOST'] + '/livekit/jwt'
    if not any(isinstance(focus,dict) and focus.get('type') == 'livekit' and
               focus.get('livekit_service_url','').rstrip('/') == expected_focus
               for focus in discovery.get('org.matrix.msc4143.rtc_foci', [])):
        print('WARN: Matrix does not yet advertise this RTC focus: ' + expected_focus)
        print('  Complete the separate Matrix discovery integration before client call acceptance.')
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

def firewall_rules(c):
    for address in (c['PUBLIC_IPV4'], c['PUBLIC_IPV6']):
        if not address:
            continue
        for key in ('HTTP_PORT', 'HTTPS_PORT', 'ICE_TCP_PORT'):
            yield address, 'tcp', str(c[key])
        for value in (c['MEDIA_UDP_PORT'], c['TURN_UDP_PORT'], f"{c['RELAY_FIRST']}:{c['RELAY_LAST']}"):
            yield address, 'udp', str(value)

def filter_model(content, source='firewall rules'):
    """Replay supported restore commands, preserving effective rule order."""
    chains, policies = {}, {}
    table = None
    restore = any(line.strip().startswith('*') for line in content.splitlines())
    def invalid(number, reason):
        # Report location without disclosing rule comments or arbitrary contents.
        fail(f'UFW filter syntax in {source}, line {number}: {reason}. Review this rule source.')
    for number, line in enumerate(content.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('*'):
            if line != '*filter' or table is not None:
                invalid(number, 'unexpected or nested table')
            table = 'filter'
            continue
        if line == 'COMMIT':
            if table != 'filter':
                invalid(number, 'COMMIT outside a filter table')
            table = None
            continue
        if restore and table != 'filter':
            invalid(number, 'rule outside a filter table')
        try:
            w = shlex.split(line, comments=True)
        except ValueError:
            invalid(number, 'invalid quoting')
        if not w:
            continue
        if w[0].startswith(':'):
            if (len(w) != 3 or not w[0][1:] or w[1] not in ('-', 'ACCEPT', 'DROP') or
                    not re.fullmatch(r'\[\d+:\d+\]', w[2]) or w[0][1:] in chains):
                invalid(number, 'invalid or duplicate chain declaration')
            chains[w[0][1:]] = []
            if w[1] != '-':
                policies[w[0][1:]] = w[1]
        elif w[0] == '-N':
            if len(w) != 2 or w[1] in chains:
                invalid(number, 'invalid or duplicate new chain')
            chains[w[1]] = []
        elif w[0] == '-P':
            if len(w) != 3 or w[2] not in ('ACCEPT', 'DROP') or w[1] in policies:
                invalid(number, 'invalid or duplicate chain policy')
            chains.setdefault(w[1], [])
            policies[w[1]] = w[2]
        elif w[0] in ('-A', '-I'):
            if len(w) < 4 or w[1] not in chains:
                invalid(number, 'missing rule body or undeclared chain')
            body = w[2:]
            position = len(chains[w[1]]) if w[0] == '-A' else 0
            if w[0] == '-I' and body[0].isdigit():
                position = int(body.pop(0)) - 1
                if not 0 <= position <= len(chains[w[1]]):
                    invalid(number, 'insertion position outside this chain')
            if not body or not body[0].startswith(('-', '!')):
                invalid(number, 'invalid rule body')
            clean, i = [], 0
            while i < len(body):
                if body[i:i+2] == ['-m', 'comment']:
                    i += 2
                elif body[i] == '--comment':
                    if i + 1 >= len(body):
                        invalid(number, 'missing comment argument')
                    i += 2
                else:
                    clean.append(body[i]); i += 1
            if not any(flag in clean for flag in ('-j', '--jump', '-g', '--goto')):
                invalid(number, 'rule has no supported target')
            chains[w[1]].insert(position, tuple(clean))
        else:
            invalid(number, 'unsupported command (expected -A, -I, -N or -P)')
    if table is not None:
        invalid(len(content.splitlines()), 'missing COMMIT')
    return chains, policies


def port_match(value, port):
    for part in value.split(','):
        bounds = part.replace('-', ':').split(':')
        if len(bounds) > 2 or any(x and not x.isdigit() for x in bounds):
            fail('Unrecognized firewall port match.')
        lo = int(bounds[0] or 0)
        hi = int(bounds[-1] or 65535)
        if lo <= port <= hi:
            return True
    return False


def canonical_rule(words, version=None):
    """Normalize documented iptables printing differences, retaining match logic."""
    clauses, i, negate = [], 0, False
    protocol_aliases = {'6':'tcp','17':'udp','1':'icmp','58':'ipv6-icmp','icmpv6':'ipv6-icmp'}
    icmp4 = {'destination-unreachable':'3','time-exceeded':'11','parameter-problem':'12',
             'echo-request':'8','echo-reply':'0'}
    icmp6 = {'destination-unreachable':'1','packet-too-big':'2','time-exceeded':'3','parameter-problem':'4',
             'echo-request':'128','echo-reply':'129','router-solicitation':'133','router-advertisement':'134',
             'neighbour-solicitation':'135','neighbor-solicitation':'135',
             'neighbour-advertisement':'136','neighbor-advertisement':'136','redirect':'137'}
    while i < len(words):
        flag = words[i]; i += 1
        if flag == '!':
            negate = not negate; continue
        count = 0 if flag == '--syn' else 2 if flag == '--tcp-flags' else 1
        values = list(words[i:i+count]); i += count
        if len(values) != count:
            fail('Incomplete firewall rule.')
        if flag == '-m' and values[0] in ('tcp','udp','icmp','icmp6','ipv6-icmp') and not negate:
            continue  # implied protocol match, often inserted only in live output
        if flag == '-p':
            values[0] = protocol_aliases.get(values[0],values[0])
        elif flag in ('-s','-d'):
            values[0] = str(ipaddress.ip_network(values[0],strict=False))
            if values[0] in ('0.0.0.0/0','::/0') and not negate:
                continue
        elif flag in ('--ctstate','--state'):
            values[0] = ','.join(sorted(values[0].split(',')))
        elif flag == '--icmp-type':
            values[0] = icmp4.get(values[0],values[0])
        elif flag == '--icmpv6-type':
            values[0] = icmp6.get(values[0],values[0])
        elif flag == '--limit':
            values[0] = re.sub(r'/(second|minute|hour|day)s?$',lambda x:'/ '+x[1][0],values[0]).replace('/ ','/')
            values[0] = re.sub(r'/(sec|min)$',lambda x:'/'+x[1][0],values[0])
        clauses.append((negate,flag,*values)); negate=False
    if negate:
        fail('Dangling firewall negation.')
    # iptables may print these implicit extension defaults explicitly. Compare
    # their effective values, preserving non-default levels, bursts and rejects.
    if (False, '-j', 'LOG') in clauses and not any(x[1] == '--log-level' for x in clauses):
        clauses.append((False, '--log-level', '4'))
    if (False, '-m', 'limit') in clauses and not any(x[1] == '--limit-burst' for x in clauses):
        clauses.append((False, '--limit-burst', '5'))
    if version in (4, 6) and (False, '-j', 'REJECT') in clauses and not any(x[1] == '--reject-with' for x in clauses):
        clauses.append((False, '--reject-with', 'icmp-port-unreachable' if version == 4 else 'icmp6-port-unreachable'))
    return tuple(sorted(clauses))


def rule_match(words, address, proto, port):
    """New non-loopback traffic from any source; IPv6 probes have no routing header."""
    possibilities = {True}
    target, goto = None, False
    i, negate = 0, False
    while i < len(words):
        flag = words[i]; i += 1
        if flag == '!':
            negate = not negate
            continue
        if flag == '--syn':
            result = {proto == 'tcp'}
        elif flag == '--tcp-flags':
            mask, wanted = words[i:i+2]; i += 2
            selected = {'SYN'} & set(mask.split(','))
            result = {selected == set(wanted.split(','))}
        elif flag.startswith('-') and i < len(words) and words[i] != '!':
            value = words[i]; i += 1
            if flag in ('-j', '--jump', '-g', '--goto'):
                target, goto = value, flag in ('-g', '--goto')
                continue
            if flag == '-m':
                if value == 'rt' and ipaddress.ip_address(address).version == 6:
                    result = {False}  # ordinary client traffic has no IPv6 routing header
                else:
                    result = {True} if value in ('tcp','udp','conntrack','state','multiport','addrtype','limit') else {True,False}
            elif flag in ('-p', '--protocol'):
                result = {value in (proto, 'all', '0', '6' if proto == 'tcp' else '17')}
            elif flag in ('-d', '--destination'):
                result = {ipaddress.ip_address(address) in ipaddress.ip_network(value, strict=False)}
            elif flag in ('-s', '--source'):
                net = ipaddress.ip_network(value, strict=False)
                result = {True} if net.prefixlen == 0 else {True,False}
            elif flag in ('-i', '--in-interface'):
                result = {False} if value == 'lo' else {True,False}
            elif flag in ('--dport','--dports','--destination-port','--destination-ports'):
                result = {port_match(value, port)}
            elif flag in ('--ctstate', '--state'):
                result = {'NEW' in value.split(',')}
            elif flag == '--dst-type':
                result = {'LOCAL' in value.split(',')}
            elif flag in ('--log-prefix','--log-level','--reject-with'):
                result = {True}
            else:
                result = {True,False}
        else:
            fail('Unsupported reachable firewall expression; review its syntax.')
        if negate:
            result = {not x for x in result}
            negate = False
        possibilities = {a and b for a in possibilities for b in result}
    if negate or target is None:
        fail('Unsupported firewall rule without a recognized target.')
    return possibilities, target, goto


def packet_outcomes(model, address, proto, port):
    chains, policies = model
    cache = {}
    def walk(chain, stack):
        if chain in stack or len(stack) > 32 or chain not in chains:
            fail('Unknown or recursive reachable UFW chain; review custom filtering.')
        if chain in cache:
            return cache[chain]
        outcomes, fallthrough = set(), True
        for words in chains[chain]:
            if not fallthrough:
                break
            match, target, goto = rule_match(words, address, proto, port)
            if True not in match:
                continue
            if target in ('LOG', 'NFLOG'):
                continue
            hit = {target} if target in ('ACCEPT','DROP','REJECT','RETURN') else walk(target, stack + (chain,))
            outcomes |= hit - {'RETURN'}
            fallthrough = False in match or ('RETURN' in hit and not goto and target != 'RETURN')
            if 'RETURN' in hit and (goto or target == 'RETURN'):
                outcomes.add('RETURN')
        if fallthrough:
            outcomes.add(policies.get(chain, 'RETURN'))
        cache[chain] = outcomes
        return outcomes
    result = walk('INPUT', ())
    if 'RETURN' in result:
        result = (result - {'RETURN'}) | {policies.get('INPUT', 'DROP')}
    return result


def ufw_models(version):
    prefix, suffix, binary = ('ufw', '', 'iptables') if version == 4 else ('ufw6', '6', 'ip6tables')
    live = filter_model(run(binary, '-w', '5', '-S', capture=True).stdout, f'{binary} -S')
    chains, policies = live
    if any(policies.get(k) != v for k,v in {'INPUT':'DROP','OUTPUT':'ACCEPT','FORWARD':'DROP'}.items()):
        fail(f'IPv{version} effective firewall defaults differ from the hardened baseline.')
    inputs = [('-j', prefix + name) for name in ('-before-logging-input','-before-input',
              '-after-input','-after-logging-input','-reject-input','-track-input')]
    if chains.get('INPUT') != inputs:
        fail(f'IPv{version} INPUT hooks differ from the UFW framework; review custom filtering.')
    persistent = {}
    for kind in ('before','user','after'):
        p = safe_file(f'/etc/ufw/{kind}{suffix}.rules')
        parsed, saved_policies = filter_model(p.read_text(), f'/etc/ufw/{kind}{suffix}.rules')
        if saved_policies:
            fail('UFW application files must not redefine built-in policies.')
        for chain,rules in parsed.items():
            if chain in persistent:
                fail('Duplicate persistent UFW chain declaration.')
            persistent[chain] = rules
    for chain, rules in persistent.items():
        runtime = chains.get(chain)
        # ufw-init appends one user hook to each before chain, outside rule files.
        hooks = {prefix + '-before-' + direction: [('-j', prefix + '-user-' + direction)]
                 for direction in ('input', 'output', 'forward')}
        allowed_tail = hooks.get(chain, [])
        wanted = [canonical_rule(x, version) for x in rules]
        observed = [canonical_rule(x, version) for x in runtime] if runtime is not None else None
        if observed != wanted and (not allowed_tail or observed != wanted + [canonical_rule(x, version) for x in allowed_tail]):
            fail(f'Persistent/effective UFW chain mismatch: {chain}.')
    for name in ('-skip-to-policy-input', '-skip-to-policy-forward'):
        helper = prefix + name
        if helper in persistent or chains.get(helper) != [('-j','DROP')]:
            fail(f'Missing, redefined or unsafe generated UFW policy chain: {helper}.')
    # Equality above proves persistent chains; the verified live graph supplies
    # generated hooks/helper chains which are legitimately absent from rule files.
    return live


def firewall_baseline():
    if not ufw_active() or ufw_setting('IPV6') != 'yes' or ufw_setting('IPT_SYSCTL') != '':
        fail('RTC requires the active dual-stack UFW baseline with IPT_SYSCTL empty.')
    return {version: ufw_models(version) for version in (4,6)}


def firewall(c, apply=False):
    # Parse and reconcile the baseline before any allow command is issued.
    models = firewall_baseline()
    if apply:
        assigned = {str(ipaddress.ip_address(a['local'])) for i in json.loads(run('ip','-j','address',capture=True).stdout)
                    for a in i.get('addr_info', [])}
        if any(a not in assigned for a in (c['PUBLIC_IPV4'],c['PUBLIC_IPV6']) if a):
            fail('A configured public address is not assigned; no firewall rule was added.')
        before = firewall_snapshot()
        for address, proto, port in firewall_rules(c):
            run('ufw','allow','proto',proto,'from','any','to',address,'port',port,
                'comment','MatrixRTC public '+proto.upper(),capture=True)
        assert_firewall_additions(before, firewall_snapshot(), c)
        models = firewall_baseline()
    for address, proto, ports in firewall_rules(c):
        lo, _, hi = ports.partition(':')
        for port in range(int(lo), int(hi or lo)+1):
            if packet_outcomes(models[ipaddress.ip_address(address).version],address,proto,port) != {'ACCEPT'}:
                fail(f'Effective UFW does not allow all intended clients: {address} {proto}/{port}.')
    print('PASS: persistent/effective IPv4/IPv6 UFW and reachable RTC allows.')


def firewall_snapshot():
    return {**{f'{kind}{suffix}': Path(f'/etc/ufw/{kind}{suffix}.rules').read_text()
               for kind in ('before','user','after') for suffix in ('','6')},
            'live4': run('iptables','-w','5','-S',capture=True).stdout,
            'live6': run('ip6tables','-w','5','-S',capture=True).stdout}


def assert_firewall_additions(before, after, c):
    expected = []
    for address, proto, port in firewall_rules(c):
        prefix = 'ufw6' if ':' in address else 'ufw'
        expected.append((prefix+'-user-input',address,proto,port))
    def permitted(chain, words):
        # Accept only the exact CLI-generated RTC rule forms, not arbitrary allows.
        for name, address, proto, port in expected:
            if chain != name:
                continue
            host = str(ipaddress.ip_network(address, strict=False))
            for dest in (address,host):
                for flag,module in (('--dport',proto),('--dports','multiport')):
                    canonical = ('-d',dest,'-p',proto,'-m',module,flag,port,'-j','ACCEPT')
                    if canonical_rule(words) == canonical_rule(canonical):
                        return True
        return False
    for key in before:
        if key.startswith(('before','after')):
            if before[key] != after[key]:
                fail('RTC altered a baseline UFW rule file.')
            continue
        label = {'user':'/etc/ufw/user.rules', 'user6':'/etc/ufw/user6.rules',
                 'live4':'iptables -S', 'live6':'ip6tables -S'}[key]
        old, old_policy = filter_model(before[key], 'before RTC changes: ' + label)
        new, new_policy = filter_model(after[key], 'after RTC changes: ' + label)
        if old_policy != new_policy or old.keys() != new.keys():
            fail('RTC altered UFW policies or chain inventory.')
        for chain in old:
            remaining = list(new[chain])
            for rule in old[chain]:
                if not remaining:
                    fail('An existing firewall rule disappeared.')
                # UFW appends application allows, preserving all earlier rule order.
                if canonical_rule(remaining.pop(0)) != canonical_rule(rule):
                    fail('Existing firewall rules changed or moved during RTC setup.')
            if any(not permitted(chain, rule) for rule in remaining):
                fail('Unexpected firewall rule appeared during RTC setup.')


def request(url, payload=None, headers=None, timeout=15):
    req = urllib.request.Request(url, data=payload, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
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
        observed = run('skopeo','inspect','--format','{{.Digest}}',
                       'docker://'+repo+':'+c[name+'_version'],capture=True).stdout.strip()
        if observed != c[name+'_digest']:
            fail(f'{name}: the retained release tag and manifest digest disagree.')
        manifest = json.loads(run('skopeo', 'inspect', '--raw', 'docker://' + ref, capture=True).stdout)
        supported = {(m.get('platform', {}).get('os'), m.get('platform', {}).get('architecture')) for m in manifest.get('manifests', [])}
        if not {('linux', 'amd64'), ('linux', 'arm64')} <= supported:
            fail(f'{name}: manifest must contain both linux/amd64 and linux/arm64.')
        run('podman', 'pull', '--quiet', '--platform', 'linux/' + arch, ref, timeout=900)
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
        'sha256:'+image_id(c['livekit_image_id']),'--config','/config.yaml','ports',capture=True)
    probe = generation / 'probe-livekit.yaml'
    value = yaml.safe_load((generation / 'livekit.yaml').read_text())
    value['rtc'].update({'node_ip': '127.0.0.1', 'ips': {'includes': ['127.0.0.1/32']}, 'enable_loopback_candidate': True})
    value['turn']['bind_addresses'] = ['127.0.0.1']
    atomic(probe, yaml.safe_dump(value, sort_keys=False))
    for name in ('livekit', 'auth', 'redis'):
        container = 'matrixrtc-stage-' + secrets.token_hex(6)
        args = ['podman','run','-d','--name',container,'--pull=never','--network=none',
                '--user','0:0','--cap-drop=all','--security-opt=no-new-privileges','-e','TZ='+c['APP_TZ']]
        ref = 'sha256:' + image_id(c[name+'_image_id'])
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
            info=json.loads(run('podman','inspect',container,capture=True).stdout)[0]
            state=info['State']
            if not state['Running']:
                log=run('podman','logs',container,capture=True)
                atomic(generation/(name+'-stage.log'),log.stdout+log.stderr)
                fail(f'{name} rejected its staged configuration. Private diagnostics retained in {generation}.')
            if name == 'redis':
                redis_timezone_check(c,container,info)
            print(f'{name}: isolated executable/configuration startup passed.',flush=True)
        finally:
            subprocess.run(['podman','rm','-f',container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)
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
Image=sha256:{image_id(c[name + '_image_id'])}
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
            unit = unit.replace('[Service]\n', '[Service]\nExecStartPre=/usr/bin/python3 -I /usr/local/lib/matrixrtc/manage.py wait-redis\n')
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
ExecStart=/usr/bin/python3 -I /usr/local/lib/matrixrtc/manage.py guard
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
ExecStart=/usr/bin/python3 -I /usr/local/lib/matrixrtc/manage.py renew
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
    manifest = {str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(out.rglob('*')) if p.is_file() and p.name != 'manifest.json'}
    atomic(out / 'manifest.json', json.dumps(manifest, indent=2) + '\n')

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
            fail(f'LiveKit route {path} returned HTTP {status}; expected 401 without a token. Inspect the active HAProxy routes and pinned LiveKit version.')

def image_id(value):
    value = str(value).removeprefix('sha256:')
    if not re.fullmatch('[0-9a-f]{64}', value):
        fail('Missing or invalid immutable runtime image ID.')
    return value


def current_generation():
    safe_dir(ROOT, private=True)
    safe_dir(ROOT / 'releases', private=True)
    current = (ROOT / 'current').resolve(strict=True)
    if current.parent != (ROOT / 'releases').resolve(strict=True):
        fail('Active generation points outside the owned release directory.')
    safe_dir(current, private=True)
    return current


def redis_timezone_check(c, container, info):
    """Verify Redis TZ without assuming /proc exposes its relocated environment."""
    env = dict(x.split('=',1) for x in info['Config'].get('Env',[]) if '=' in x)
    if not info['State']['Running'] or env.get('TZ') != c['APP_TZ']:
        fail(f'{container}: configured Redis TZ or running state differs.')
    main = Path('/proc') / str(info['State']['Pid'])
    if not (main/'exe').samefile(main/'root/usr/local/bin/redis-server'):
        fail(f'{container}: the main process is not the image Redis executable.')
    runtime_env = dict(x.split(b'=',1) for x in (main/'environ').read_bytes().split(b'\0') if b'=' in x)
    # Redis 8.2's setproctitle copies environ and overwrites its original storage.
    # Missing TZ in /proc is therefore expected; a visible conflicting TZ is not.
    if b'TZ' in runtime_env and runtime_env[b'TZ'] != c['APP_TZ'].encode():
        fail(f'{container}: visible Redis process TZ differs from the host policy.')
    zone = main/'root/usr/share/zoneinfo'/c['APP_TZ']
    if not zone.is_file() or not zone.read_bytes().startswith(b'TZif'):
        fail(f'{container}: timezone data is missing or invalid for {c["APP_TZ"]}.')
    # The pinned Alpine image includes tzdata and BusyBox date. Do not override
    # TZ here: probe the existing container environment and actual libc zone data.
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    probes = [now] + [datetime.datetime(now.year,month,15,12,tzinfo=datetime.timezone.utc) for month in (1,7)]
    expected_zone = ZoneInfo(c['APP_TZ'])
    for instant in probes:
        observed = run('podman','exec',container,'/bin/date','-d','@'+str(int(instant.timestamp())),
                       '+%Y-%m-%dT%H:%M:%S%z',capture=True,timeout=10).stdout.strip()
        expected = instant.astimezone(expected_zone).strftime('%Y-%m-%dT%H:%M:%S%z')
        if observed != expected:
            fail(f'{container}: container timezone conversion differs from host {c["APP_TZ"]}.')
    print(f'PASS: Redis TZ={c["APP_TZ"]}, executable, zone data and current/winter/summer conversion; /proc environment may be rewritten.')


def configuration_check(c):
    current = current_generation()
    if c.get('schema_version') != SCHEMA:
        fail('This deployment uses an older RTC schema; automatic migration/repair is not supported.')
    manifest = read(safe_file(current / 'manifest.json', private=True))
    expected = {'settings.json','livekit.yaml','auth.env','redis.conf','bootstrap.cfg','haproxy.cfg','guard.nft'}
    expected |= {f'quadlets/matrixrtc-{name}.container' for name in REPOS}
    expected |= {f'units/matrixrtc-{name}.{kind}' for name,kind in (
        ('edge','service'),('guard','service'),('acme-http','service'),('renew','service'),('renew','timer'))}
    if set(manifest) != expected:
        fail('Generated configuration manifest has an unexpected file inventory.')
    for relative, digest in manifest.items():
        path = safe_file(current / relative, private='/' not in relative)
        if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            fail(f'Generated configuration drift: {relative}.')
    for relative, destination in [('quadlets','/etc/containers/systemd'),('units','/etc/systemd/system')]:
        for source in (current / relative).iterdir():
            target = Path(destination) / source.name
            if not target.is_symlink() or target.resolve(strict=True) != source:
                fail(f'Unexpected unit source: {source.name}.')
    if (ROOT / 'edge.cfg').resolve(strict=True) != current / 'haproxy.cfg':
        fail('HAProxy is not using the active full configuration.')
    secret_values = read(safe_file(ROOT / 'secrets.json', private=True))
    if set(secret_values) != {'livekit_key','livekit_secret','redis_password'} or any(
            not isinstance(x,str) or not re.fullmatch('[0-9a-f]{64}',x) for x in secret_values.values()):
        fail('Invalid retained credential state.')
    for name,key in [('key','livekit_key'),('secret','livekit_secret')]:
        if safe_file(ROOT/name,private=True).read_text() != secret_values[key]:
            fail('Credential file does not match retained secret state.')
    safe_dir(DATA / 'redis', private=True)
    # Preserve the supplied image contract: explicit root UID, no capabilities,
    # original LiveKit/auth entrypoints and explicit redis-server entrypoint.
    owners = {}
    for name in REPOS:
        container = 'matrixrtc-' + name
        info = json.loads(run('podman','container','inspect',container,capture=True).stdout)[0]
        expected_id = image_id(c[name+'_image_id'])
        if image_id(info['Image']) != expected_id or not info['State']['Running']:
            fail(f'{container}: running image/state mismatch.')
        cfg, host = info['Config'], info['HostConfig']
        if host.get('NetworkMode') != 'host' or cfg.get('User') != '0:0':
            fail(f'{container}: network or configured identity differs.')
        if host.get('ReadonlyRootfs') is not (name != 'redis'):
            fail(f'{container}: root filesystem access differs.')
        env = dict(x.split('=',1) for x in cfg.get('Env',[]) if '=' in x)
        if env.get('TZ') != c['APP_TZ']:
            fail(f'{container}: timezone delivery differs.')
        expected_mounts = {
            'livekit': {'/etc/livekit.yaml': (current/'livekit.yaml',False)},
            'auth': {'/run/matrixrtc/key': (ROOT/'key',False), '/run/matrixrtc/secret': (ROOT/'secret',False)},
            'redis': {'/etc/redis.conf': (current/'redis.conf',False), '/data': (DATA/'redis',True)}
        }[name]
        binds = {m['Destination']:m for m in info.get('Mounts',[]) if m.get('Type') == 'bind'}
        if set(binds) != set(expected_mounts):
            fail(f'{container}: unexpected persistent bind mount inventory.')
        for destination,(source,rw) in expected_mounts.items():
            mount = binds[destination]
            actual = Path(mount['Source']).resolve()
            same = actual == source.resolve()
            # Unchanged peers need no restart after a component update. Their
            # read-only bind may still pin an identical file in an older release.
            if not same and not rw and source.parent == current:
                releases = (ROOT/'releases').resolve()
                same = (actual.parent.parent == releases and actual.name == source.name and
                        safe_file(actual,private=True).read_bytes() == source.read_bytes())
            if not same or mount['RW'] is not rw:
                fail(f'{container}: mount source/access mismatch at {destination}.')
        meta = json.loads(run('podman','image','inspect','sha256:'+expected_id,capture=True).stdout)[0]
        arch = run('dpkg','--print-architecture',capture=True).stdout.strip()
        if meta['Os'] != 'linux' or meta['Architecture'] != arch:
            fail(f'{container}: image architecture mismatch.')
        pids = set()
        for row in run('podman','top',container,'hpid',capture=True).stdout.splitlines()[1:]:
            if not row.strip().isdigit():
                fail(f'{container}: invalid host PID inventory.')
            pid = int(row.strip()); pids.add(pid)
            proc = Path('/proc') / str(pid)
            status = proc.joinpath('status').read_text()
            values = dict(line.split(':',1) for line in status.splitlines() if ':' in line)
            if values['Uid'].split() != ['0']*4 or values['Gid'].split() != ['0']*4:
                fail(f'{container}: unexpected running UID/GID for PID {pid}.')
            if values.get('NoNewPrivs','').strip() != '1' or int(values['CapEff'].strip(),16) != 0:
                fail(f'{container}: runtime privilege restrictions differ.')
        if not pids or int(info['State']['Pid']) not in pids:
            fail(f'{container}: running process identity is unavailable.')
        main = Path('/proc') / str(info['State']['Pid'])
        if name == 'redis':
            redis_timezone_check(c,container,info)
        else:
            runtime_env = dict(x.split(b'=',1) for x in main.joinpath('environ').read_bytes().split(b'\0') if b'=' in x)
            if runtime_env.get(b'TZ') != c['APP_TZ'].encode():
                fail(f'{container}: TZ did not reach the running process.')
        for destination,(source,_) in expected_mounts.items():
            inside = main / 'root' / destination.lstrip('/')
            # A live process-root read works for minimal images without a shell.
            if source.is_file() and inside.read_bytes() != source.read_bytes():
                fail(f'{container}: mounted file bytes differ at {destination}.')
        if name == 'auth':
            for line in (current/'auth.env').read_text().splitlines():
                key,value = line.split('=',1)
                if env.get(key) != value or runtime_env.get(key.encode()) != value.encode():
                    fail('Authorization environment delivery differs; secret values omitted.')
        owners[container] = pids
    print('PASS: immutable images, mounts, generated configuration, credentials, identities and TZ delivery.')
    return owners


def native_pids(service):
    group = run('systemctl','show',service+'.service','-p','ControlGroup','--value',capture=True).stdout.strip()
    if not group.startswith('/') or '..' in group.split('/') or group == '/':
        fail(f'{service}: invalid systemd control group.')
    root = Path('/sys/fs/cgroup') / group.lstrip('/')
    pids = set()
    for p in root.rglob('cgroup.procs'):
        pids |= {int(x) for x in p.read_text().split()}
    if not pids:
        fail(f'{service}: no process in its service control group.')
    return pids


def listener_check(c, owners):
    owners = dict(owners)
    for svc in ('matrixrtc-edge','matrixrtc-acme-http'):
        owners[svc] = native_pids(svc)
    public = {c['PUBLIC_IPV4']} | ({c['PUBLIC_IPV6']} if c['PUBLIC_IPV6'] else set())
    tcp = {c[k]: ({'127.0.0.1'}, svc) for k,svc in (
        ('LIVEKIT_PORT','matrixrtc-livekit'),('AUTH_PORT','matrixrtc-auth'),('REDIS_PORT','matrixrtc-redis'),
        ('EDGE_HTTP_PORT','matrixrtc-edge'),('ACME_PORT','matrixrtc-acme-http'))}
    tcp.update({c[k]:(public,'matrixrtc-edge') for k in ('HTTP_PORT','HTTPS_PORT')})
    tcp[c['TURN_INTERNAL_PORT']] = (public,'matrixrtc-livekit')
    tcp[c['ICE_TCP_PORT']] = (public | {'0.0.0.0','::'},'matrixrtc-livekit')
    udp = {c['MEDIA_UDP_PORT']:(public | {'0.0.0.0','::'},'matrixrtc-livekit'),
           c['TURN_UDP_PORT']:(public,'matrixrtc-livekit')}
    observed = {'tcp':{},'udp':{}}
    for proto, contracts in [('tcp',tcp),('udp',udp)]:
        for family in ('-4','-6'):
            out = run('ss','-H',family,'-ln'+('t' if proto == 'tcp' else 'u')+'p',capture=True).stdout
            for row in out.splitlines():
                fields = row.split()
                address, port = fields[3].rsplit(':',1)
                address = address.strip('[]').split('%',1)[0]
                address = ('0.0.0.0' if family == '-4' else '::') if address == '*' else address
                if not port.isdigit():
                    continue
                port = int(port)
                pids = {int(x) for x in re.findall(r'pid=(\d+)',row)}
                relevant = port in contracts or (proto == 'udp' and c['RELAY_FIRST'] <= port <= c['RELAY_LAST'])
                rtc_owned = any(pids & ids for ids in owners.values())
                if not relevant:
                    if rtc_owned:
                        fail(f'Unexpected RTC listener: {proto} {address}:{port}.')
                    continue
                allowed, service = contracts.get(port,(public,'matrixrtc-livekit'))
                if address not in allowed or not pids or not pids <= owners[service]:
                    fail(f'Listener binding/owner mismatch: {proto} {address}:{port}.')
                observed[proto].setdefault(port,set()).add(address)
        for port,(allowed,_) in contracts.items():
            got = observed[proto].get(port,set())
            if not got or ('0.0.0.0' not in allowed and got != allowed):
                fail(f'Missing expected listener: {proto}/{port}.')
    print('PASS: application socket owners and private listener bindings.')


def guard_check(c):
    contents = json.loads(run('nft','-j','list','table','inet','matrixrtc_guard',capture=True).stdout)['nftables']
    tables = [x['table'] for x in contents if 'table' in x]
    chains = [x['chain'] for x in contents if 'chain' in x]
    rules = [x['rule'] for x in contents if 'rule' in x]
    if len(tables) != 1 or tables[0].get('comment') != 'Owned by matrixrtc-debian13-installer' or len(chains) != 1 or len(rules) != 1:
        fail('Private-port guard has unexpected objects or ownership.')
    ch = chains[0]
    if any(ch.get(k) != v for k,v in {'name':'input','type':'filter','hook':'input','prio':-10,'policy':'accept'}.items()):
        fail('Private-port guard hook/priority/policy differs.')
    expr = rules[0].get('expr',[])
    private = {c[k] for k in ('TURN_INTERNAL_PORT','LIVEKIT_PORT','AUTH_PORT','REDIS_PORT','EDGE_HTTP_PORT','ACME_PORT')}
    if len(expr) != 3 or expr[0] != {'match':{'op':'!=','left':{'meta':{'key':'iifname'}},'right':'lo'}} or expr[-1] != {'drop':None}:
        fail('Private-port guard condition/verdict differs.')
    match = expr[1].get('match',{})
    if match.get('op') != '==' or match.get('left') != {'payload':{'protocol':'tcp','field':'dport'}} or set(match.get('right',{}).get('set',[])) != private:
        fail('Private-port guard TCP coverage differs.')
    all_rules = json.loads(run('nft','-j','list','ruleset',capture=True).stdout)['nftables']
    for obj in all_rules:
        chain = obj.get('chain',{})
        if chain.get('hook') == 'input' and (chain.get('family'),chain.get('table'),chain.get('name')) not in (
                ('inet','matrixrtc_guard','input'),('ip','filter','INPUT'),('ip6','filter','INPUT')):
            fail('Additional nftables input hook requires review alongside UFW.')
    print('PASS: complete private-port nftables guard.')


def redis_check(c):
    secret = read(ROOT/'secrets.json')['redis_password']
    def command(parts, auth=True):
        def bulk(values):
            return ('*'+str(len(values))+'\r\n'+''.join('$'+str(len(v))+'\r\n'+v+'\r\n' for v in values)).encode()
        with socket.create_connection(('127.0.0.1',c['REDIS_PORT']),timeout=5) as conn:
            conn.settimeout(5)
            stream = conn.makefile('rb')
            if auth:
                conn.sendall(bulk(['AUTH',secret]))
                if stream.readline(4096) != b'+OK\r\n':
                    fail('Redis authentication failed.')
            conn.sendall(bulk(parts))
            line = stream.readline(4096)
            if line.startswith(b'$'):
                size = int(line[1:-2])
                if not 0 <= size <= 1_000_000:
                    fail('Invalid Redis response size.')
                body = stream.read(size)
                if stream.read(2) != b'\r\n':
                    fail('Incomplete Redis response.')
                return body
            return line
    if not command(['PING'],auth=False).startswith(b'-NOAUTH') or command(['PING']) != b'+PONG\r\n':
        fail('Redis PING/authentication policy differs.')
    info = command(['INFO','persistence']).decode()
    fields = dict(x.split(':',1) for x in info.splitlines() if x and not x.startswith('#') and ':' in x)
    if fields.get('aof_enabled') != '1' or fields.get('aof_last_write_status') != 'ok':
        fail('Redis append-only persistence is not healthy.')
    print('PASS: Redis authentication and append-only persistence.')


def service_snapshot(initial=False):
    result = {}
    for svc in CHECK_SERVICES:
        text = run('systemctl','show',svc+'.service','-p','NRestarts','-p','InvocationID',capture=True).stdout
        fields = dict(x.split('=',1) for x in text.splitlines() if '=' in x)
        if not fields.get('NRestarts','').isdigit() or not fields.get('InvocationID'):
            fail(f'{svc}: service invocation/restart state unavailable.')
        if initial and fields['NRestarts'] != '0':
            fail(f'{svc}: unexpected initial restart count {fields["NRestarts"]}.')
        result[svc] = fields
    return result


def renewal_check(c):
    state = run('systemctl','show','matrixrtc-renew.timer','-p','ActiveState','-p','UnitFileState',
                '-p','NextElapseUSecRealtime',capture=True).stdout
    fields = dict(x.split('=',1) for x in state.splitlines() if '=' in x)
    if fields.get('ActiveState') != 'active' or fields.get('UnitFileState') != 'enabled' or fields.get('NextElapseUSecRealtime') in ('',None,'0','n/a'):
        fail('Certificate renewal timer is not active/enabled/scheduled.')
    if run('systemctl','show','matrixrtc-renew.service','-p','Result','--value',capture=True).stdout.strip() not in ('','success'):
        fail('Last certificate renewal failed; inspect its private journal.')
    pem = safe_file(ROOT/'tls/current.pem',private=True)
    run('openssl','x509','-in',str(pem),'-noout','-checkend','604800',capture=True)
    for host in (c['RTC_HOST'],c['TURN_HOST']):
        run('openssl','x509','-in',str(pem),'-noout','-checkhost',host,capture=True)
    print('PASS: certificate names/lifetime and renewal timer.')


def checks(c, initial=False, renewal=True):
    host_ready(c)
    firewall(c)
    deadline = time.monotonic() + c['START_WAIT_SECONDS']
    while True:
        try:
            for svc in CHECK_SERVICES:
                run('systemctl','is-active','--quiet',svc+'.service',capture=True,timeout=5)
            for port,path in [(c['AUTH_PORT'],'/healthz'),(c['LIVEKIT_PORT'],'/')]:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    fail('Readiness budget expired.')
                status,_ = request(f'http://127.0.0.1:{port}{path}', timeout=min(5,remaining))
                if status != 200:
                    fail('Local service health response failed.')
            break
        except (RuntimeError, OSError, subprocess.SubprocessError):
            if time.monotonic() >= deadline:
                fail('Readiness deadline exceeded. Inspect the private matrixrtc service journals; state is preserved.')
            time.sleep(min(2, max(0, deadline-time.monotonic())))
    counters = service_snapshot(initial=initial)
    print(f"Observing services for {c['STABILITY_SECONDS']} seconds...",flush=True)
    time.sleep(c['STABILITY_SECONDS'])
    network(c)
    owners = configuration_check(c)
    listener_check(c,owners)
    guard_check(c)
    redis_check(c)
    status,_ = request(f"https://{c['RTC_HOST']}/livekit/jwt/healthz")
    if status != 200:
        fail('Public authorization health route failed.')
    signaling_routes(c)
    status,_ = request(f"https://{c['RTC_HOST']}/livekit/jwt/sfu_webhook",b'{}',{'Content-Type':'application/json'})
    if status != 404:
        fail('The internal webhook is exposed publicly.')
    body = json.dumps({'room':'!matrixrtc-probe:'+c['MATRIX_SERVER_NAME'],'device_id':'probe',
        'openid_token':{'access_token':'matrixrtc-intentionally-invalid','matrix_server_name':c['MATRIX_SERVER_NAME']}}).encode()
    status,_ = request(f"https://{c['RTC_HOST']}/livekit/jwt/sfu/get",body,{'Content-Type':'application/json'})
    if status != 401:
        fail('Invalid OpenID authentication must return 401.')
    with socket.create_connection((c['TURN_HOST'],443),timeout=10) as raw:
        with ssl.create_default_context().wrap_socket(raw,server_hostname=c['TURN_HOST']):
            pass
    if renewal:
        renewal_check(c)
    if service_snapshot(initial=initial) != counters:
        fail('An RTC service restarted or changed invocation during verification.')
    for svc in CHECK_SERVICES:
        run('systemctl','is-active','--quiet',svc+'.service',capture=True)
    host_ready(c,audit=False)
    print('PASS: readiness, restart stability, HTTPS/TLS and authentication rejection.')
    print('Local/server-origin checks passed. External calls and forced TURN allocation remain separate acceptance tests.')


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
        checks(read(generation / 'settings.json'), initial=old is None, renewal=old is not None)
    except BaseException:
        if old is not None and component == 'livekit':
            # Full immutable image/config pair is restored. Redis data is not downgraded.
            link(old, ROOT / 'current')
            run('systemctl', 'daemon-reload')
            run('systemctl', 'restart', f'matrixrtc-{component}.service')
            checks(read(old / 'settings.json'))
            print('Previous image/configuration pair restored and health-checked; call acceptance still required.')
        elif old is not None:
            print('Stateful component update failed; no automatic image/data downgrade was attempted. Preserve data and inspect logs.', file=sys.stderr)
        else:
            print('Installation incomplete; services and all persistent state are preserved for diagnosis.', file=sys.stderr)
        raise
    if old is not None:
        atomic(ROOT / 'installed', generation.name + '\n')

def install(c):
    policy = host_ready(c)
    before = host_snapshot(policy)
    firewall(c)
    c = acquire_images(validate(c))
    c['schema_version'] = SCHEMA
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
    quadlet_check(generation)
    run('systemctl', 'daemon-reload')
    for svc in SERVICES:
        if run('systemctl', 'show', svc + '.service', '-p', 'LoadState', '--value', capture=True).stdout.strip() != 'loaded':
            fail('Quadlet/systemd generation failed for ' + svc)
    run('systemctl', 'enable', 'matrixrtc-guard.service', 'matrixrtc-acme-http.service', 'matrixrtc-edge.service')
    run('systemctl', 'restart', 'matrixrtc-guard.service', 'matrixrtc-acme-http.service', 'matrixrtc-edge.service')
    run('certbot', 'certonly', '--webroot', '-w', str(DATA / 'acme-web'), '--cert-name', 'matrixrtc',
        '-d', c['RTC_HOST'], '-d', c['TURN_HOST'], '--email', c['ACME_EMAIL'], '--agree-tos',
        '--non-interactive', '--keep-until-expiring', *certbot_args(), timeout=900)
    load_certificate()
    run('haproxy', '-c', '-f', str(generation / 'haproxy.cfg'), capture=True)
    activate(generation)
    assert_host_preserved(before, policy)
    run('systemctl', 'enable', '--now', 'matrixrtc-renew.timer')
    checks(c, initial=True)
    atomic(ROOT / 'installed', generation.name + '\n')
    summary(c)

def update(component, version, digest):
    if component not in REPOS:
        fail('Component must be livekit, auth, or redis.')
    old = (ROOT / 'current').resolve()
    c = read(old / 'settings.json')
    policy = host_ready(c)
    host_before = host_snapshot(policy)
    checks(c)
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
    with open('/dev/tty', 'r') as tty:
        print('Type UPDATE to proceed: ', end='', flush=True)
        if tty.readline().strip() != 'UPDATE':
            fail('Cancelled.')
    c[component + '_version'], c[component + '_digest'] = version, digest
    c = acquire_images(c)
    new = ROOT / 'releases' / (datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(3))
    render(c, read(ROOT / 'secrets.json'), new)
    stage_probe(c, new)
    quadlet_check(new)
    run('haproxy', '-c', '-f', str(new / 'haproxy.cfg'), capture=True)
    activate(new, old, component)
    assert_host_preserved(host_before, policy)
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
  App timezone:   {c['APP_TZ']} (derived from the verified host policy)
  Host baseline:  Debian hardening v1.0.3; confirmed SSH/sudo and active UFW

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
  sudo matrixrtc-maint versions
  sudo matrixrtc-maint update livekit v1.13.X sha256:<reviewed-index-digest>
  sudo matrixrtc-maint renew
  sudo matrixrtc-maint renewal-test
  sudo journalctl -u matrixrtc-livekit -u matrixrtc-auth -u matrixrtc-edge -n 80

FILES
  /etc/matrixrtc/current/       active generated configuration and image pins
  /etc/matrixrtc/releases/      recoverable previous configuration revisions
  /etc/matrixrtc/secrets.json   credentials, root only; never share
  /var/lib/debian-hardening/  independently managed host policy and access records
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

HOST AND APPLICATION POLICY
  Run debian-hardening.sh first and confirm fresh administrator SSH/sudo access.
  RTC owns only its packages, application files/services, public allows and guard.
  The supplied Debian hardening preserves unrelated application UFW rules.
  Complete a later hardening run before checking RTC again; concurrent runs are refused.
  Host audit: sudo /usr/local/sbin/debian-hardening-check
  Recheck RTC after a reviewed reboot and after certificate renewal testing.
  Persistent state: /etc/matrixrtc, /var/lib/matrixrtc and /var/log/matrixrtc-acme.
  No snapshot/backup is created or verified by this installer.
""")

def quadlet_check(generation):
    generator = '/usr/lib/systemd/system-generators/podman-system-generator'
    if not Path(generator).is_file():
        fail('Podman Quadlet generator is missing.')
    env = dict(os.environ, QUADLET_UNIT_DIRS=str(generation/'quadlets'))
    result = run(generator,'--dryrun',capture=True,env=env)
    for name in REPOS:
        if 'matrixrtc-'+name+'.service' not in result.stdout:
            fail(f'Quadlet dry-run did not generate matrixrtc-{name}.service.')


def main():
    args = sys.argv[1:]
    command = args[0] if args else 'status'
    ordinary = {'status','versions','firewall-check','network','renew','renewal-test','host-check'}
    valid = ((command in ordinary and len(args) <= 1) or
             (command == 'check' and args in (['check'],['check','--initial'])) or
             (command == 'update' and len(args) == 4) or
             (command in ('guard','wait-redis','install') and len(args) == 1) or
             (command in ('validate','preflight','ports','firewall-apply-staged','firewall-baseline-staged','host-staged','host-snapshot','host-compare') and len(args) == 2) or
             (command == 'render-test' and len(args) == 4))
    if not valid:
        fail('Usage: matrixrtc-maint {status|versions|check [--initial]|host-check|firewall-check|network|renew|renewal-test|update COMPONENT VERSION DIGEST}')
    if os.geteuid() != 0:
        fail('Run with sudo or as root.')
    if command == 'validate':
        c = validate(read(args[1])); atomic(args[1],json.dumps(c,indent=2)+'\n'); return
    if command == 'render-test':
        render(validate(read(args[1])),read(args[2]),args[3]); return
    if command in ('guard','wait-redis'):
        (guard if command == 'guard' else wait_redis)(); return  # systemd prerequisite under the owning operation
    with host_lock():
        if command in ('host-snapshot','host-compare'):
            policy = host_ready()
            if command == 'host-snapshot':
                atomic(args[1],json.dumps(host_snapshot(policy))+'\n')
            else:
                assert_host_preserved(read(safe_file(args[1],private=True)),policy)
            return
        if command == 'host-check':
            host_ready(); return
        if command in ('preflight','ports','firewall-apply-staged','firewall-baseline-staged','host-staged'):
            c = validate(read(args[1]))
            if command == 'host-staged':
                host_ready(c)
            elif command == 'firewall-apply-staged':
                host_ready(c)
                firewall(c,apply=True)
            elif command == 'firewall-baseline-staged':
                host_ready(c)
                firewall_baseline()
                print('PASS: existing IPv4/IPv6 UFW baseline; RTC allows will be added during installation.')
            else:
                (network if command == 'preflight' else ports)(c)
            return  # the installer holds the RTC lock
        with open('/run/lock/matrixrtc.lock','a') as lock:
            try:
                fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                fail('Another MatrixRTC operation is running.')
            if command == 'install':
                install(read(safe_file(ROOT/'site.json',private=True))); return
            c = validate(read(safe_file(current_generation()/'settings.json',private=True)))
            if c.get('schema_version') != SCHEMA:
                fail('Older RTC deployment found. This installer does not migrate or repair it; inspect its existing maintenance status.')
            if command == 'check':
                checks(c,initial=len(args)==2)
            elif command == 'firewall-check':
                host_ready(c); firewall(c); guard_check(c)
            elif command == 'network':
                host_ready(c); network(c)
            elif command == 'status':
                summary(c)
                run('systemctl','--no-pager','--full','status',*[x+'.service' for x in CHECK_SERVICES],'matrixrtc-renew.timer')
            elif command == 'versions':
                for name in REPOS:
                    print(name,c[name+'_version'],REPOS[name]+'@'+c[name+'_digest'],'runtime=sha256:'+image_id(c[name+'_image_id']))
                run('dpkg-query','-W','podman','haproxy','certbot','nftables')
            elif command == 'update':
                update(*args[1:])
            elif command in ('renew','renewal-test'):
                policy = host_ready(c)
                before = host_snapshot(policy)
                firewall(c); guard_check(c)
                cmd = ['certbot','renew','--cert-name','matrixrtc','--non-interactive',*certbot_args()]
                if command == 'renewal-test':
                    cmd += ['--dry-run']
                run(*cmd,timeout=780)
                if command == 'renew':
                    load_certificate()
                assert_host_preserved(before,policy)
                # The renewal service is currently running: check certificate/timer,
                # not its previous Result, on this path.
                run('openssl','x509','-in',str(ROOT/'tls/current.pem'),'-noout','-checkend','604800',capture=True)
                print('Certificate operation completed; verify external TLS after renewal.')


if __name__ == '__main__':
    try:
        main()
    except (Exception,KeyboardInterrupt) as e:
        if isinstance(e,subprocess.SubprocessError):
            print('ERROR: a required command failed or timed out. Arguments are omitted; inspect private service logs.',file=sys.stderr)
        elif isinstance(e,RuntimeError):
            print('ERROR: '+str(e),file=sys.stderr)
        else:
            print('ERROR: validation or inspection failed ('+type(e).__name__+'). State is preserved; no automatic repair.',file=sys.stderr)
        sys.exit(1)
PY_MANAGER
chmod 0700 "$TEMP_DIR/manage.py"
python3 -I "$TEMP_DIR/manage.py" validate "$TEMP_DIR/site.json"
INSTALL_STAGE="host baseline verification"
python3 -I "$TEMP_DIR/manage.py" host-staged "$TEMP_DIR/site.json"
if (( INSTALLED )); then
    echo 'Existing backend: observational revision/schema and application checks only.'
    flock -u 9
    python3 -I "$TEMP_DIR/manage.py" check
    exit 0
fi
python3 -I "$TEMP_DIR/manage.py" host-snapshot "$TEMP_DIR/host-before.json"
INSTALL_STAGE="firewall baseline preflight"
python3 -I "$TEMP_DIR/manage.py" firewall-baseline-staged "$TEMP_DIR/site.json"
# Restore all validated effective settings, including values retained on partial reruns.
while IFS=$'\t' read -r name value; do
    printf -v "$name" '%s' "$value"
done < <(python3 - "$TEMP_DIR/site.json" <<'PY_VALUES'
import json,sys
for k,v in json.load(open(sys.argv[1])).items():
    if k.isupper():print(k+'\t'+str(v))
PY_VALUES
)

python3 -I "$TEMP_DIR/manage.py" preflight "$TEMP_DIR/site.json"
if [[ -n $PUBLIC_IPV6 ]]; then
    echo 'IPv6 is explicitly configured. Both DNS names must already have the matching AAAA.'
    echo 'Confirm this assigned address has working inbound AND outbound IPv6 from an external network.'
    read -r -p 'Type IPV6-TESTED to confirm, or Ctrl-C and clear PUBLIC_IPV6/remove AAAA: ' answer <&8
    [[ $answer == IPV6-TESTED ]] || { echo 'Cancelled IPv6 deployment.'; exit 1; }
fi
if command -v nft >/dev/null && nft list table inet matrixrtc_guard > "$TEMP_DIR/guard.txt" 2>/dev/null; then
    echo 'ERROR: A matrixrtc_guard table already exists. Its state is preserved for inspection.' >&2; exit 1
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
ufw status verbose
echo 'Active UFW is required. Only RTC allows are added; SSH/defaults and unrelated rules are preserved.'
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
The completed Debian hardening v1.0.3 baseline and administrator access are preserved.
Run host hardening first; complete its SSH confirmation before starting RTC.
The installer records no backup: protect /etc/matrixrtc and /var/lib/matrixrtc externally.
ACME Terms of Service will be accepted for $ACME_EMAIL after confirmation.
SUMMARY
echo 'The installer will configure UFW automatically and preserve existing SSH rules.'
echo 'Confirm the Hetzner Cloud Firewall allows the required public ports, or no cloud firewall is attached.'
echo 'Any other upstream firewall must also allow this traffic. This confirmation does not test connectivity.'
read -r -p 'Confirm upstream firewall readiness: type FIREWALL-READY: ' answer <&8
[[ $answer == FIREWALL-READY ]] || { echo 'Cancelled before provisioning.'; exit 1; }
read -r -p 'Install the calling backend on this VPS? Type INSTALL: ' answer <&8
[[ $answer == INSTALL ]] || { echo 'Cancelled before provisioning.'; exit 1; }

# PHASE 3 — packages for the app; no OS release upgrade or host-policy writer.
INSTALL_STAGE="application packages"
python3 -I "$TEMP_DIR/manage.py" ports "$TEMP_DIR/site.json"
NFTABLES_WAS_INSTALLED=0
if dpkg-query -W -f='${db:Status-Status}' nftables 2>/dev/null | grep -qx installed; then NFTABLES_WAS_INSTALLED=1; fi
HAPROXY_WAS_INSTALLED=0
if dpkg-query -W -f='${db:Status-Status}' haproxy 2>/dev/null | grep -qx installed; then HAPROXY_WAS_INSTALLED=1; fi
# Respect an existing policy-rc.d. Otherwise temporarily suppress package service
# starts, preventing the distribution's default HAProxy instance from taking :80.
if [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]]; then
    printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
    chmod 0755 /usr/sbin/policy-rc.d
    POLICY_CREATED=1
fi
APT_OPTIONS=(-o "DPkg::Lock::Timeout=$APT_LOCK_TIMEOUT" -o APT::Update::Error-Mode=any)
apt-get "${APT_OPTIONS[@]}" update
for package in "${PACKAGES[@]}"; do
    candidate=$(apt-cache policy "$package" | awk '/Candidate:/ {print $2}')
    [[ -n $candidate && $candidate != '(none)' ]] || { echo "ERROR: Debian repositories have no candidate for $package. Repository configuration was not changed." >&2; exit 1; }
done
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get "${APT_OPTIONS[@]}" install -y --no-install-recommends --no-remove \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${PACKAGES[@]}"
if (( ! HAPROXY_WAS_INSTALLED )); then systemctl disable --now haproxy.service; fi
# Do not introduce a second system-wide firewall loader while adding nft tooling.
if (( ! NFTABLES_WAS_INSTALLED )); then systemctl disable nftables.service; fi
if (( POLICY_CREATED )); then rm -f /usr/sbin/policy-rc.d; POLICY_CREATED=0; fi
haproxy -v | head -1
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' podman)" ge 5.4 || { echo 'ERROR: Podman >=5.4 is required.' >&2; exit 1; }
dpkg --compare-versions "$(dpkg-query -W -f='${Version}' haproxy)" ge 3.0 || { echo 'ERROR: HAProxy >=3.0 is required.' >&2; exit 1; }

# PHASE 4 — owned directories, saved settings and once-only credentials.
INSTALL_STAGE="application configuration"
python3 -I "$TEMP_DIR/manage.py" host-compare "$TEMP_DIR/host-before.json"
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
printf '#!/bin/sh\nexec /usr/bin/python3 -I /usr/local/lib/matrixrtc/manage.py "$@"\n' > "$TEMP_DIR/matrixrtc-maint"
install -m 0755 "$TEMP_DIR/matrixrtc-maint" /usr/local/bin/matrixrtc-maint

# PHASE 5 — preserve UFW's state and existing management rules.
INSTALL_STAGE="application firewall"
python3 -I "$TEMP_DIR/manage.py" firewall-apply-staged "$ROOT_DIR/site.json"

# PHASE 6 — immutable pulls, configuration staging, bootstrap ACME and activation.
# The maintenance controller uses the same lock; release this descriptor before it
# takes over. All persistent application mutations from here are serialized there.
INSTALL_STAGE="application startup and verification"
flock -u 9
python3 -I "$LIB_DIR/manage.py" install
INSTALL_STAGE="final host preservation"
python3 -I "$TEMP_DIR/manage.py" host-compare "$TEMP_DIR/host-before.json"
echo 'Installation completed. Use the separate integration guide on the existing Matrix server.'
