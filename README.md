## Proxmox Scripts
#### *container creation, configuration and app install*  
  
Debian LXC
```bash
mkdir -p scripts && \
wget -O scripts/deblxc.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/deblxc.sh && \
chmod +x scripts/deblxc.sh && \
./scripts/deblxc.sh
```
  
NPM on Podman, optional Cloudflared
```bash
mkdir -p scripts && \
wget -O scripts/npm-podman.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-podman.sh && \
chmod +x scripts/npm-podman.sh && \
./scripts/npm-podman.sh
```
  
Unbound DNS
```bash
mkdir -p scripts && \
wget -O scripts/unbound.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/unbound.sh && \
chmod +x scripts/unbound.sh && \
./scripts/unbound.sh
```
  
Samba File server
```bash
mkdir -p scripts && \
wget -O scripts/samba.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/samba.sh && \
chmod +x scripts/samba.sh && \
./scripts/samba.sh
```
  
Matrix, decentralised communication <a href="https://github.com/vdarkobar/scripts/blob/main/misc/matrix-how-to.md">*how-to*</a>
```bash
mkdir -p scripts && \
wget -O scripts/matrix-podman.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/matrix-podman.sh && \
chmod +x scripts/matrix-podman.sh && \
./scripts/matrix-podman.sh
```
  
Privatebin <a href="https://github.com/vdarkobar/scripts/blob/main/misc/matrix-how-to.md">*how-to*</a>
```bash
mkdir -p scripts && \
wget -O scripts/privatebin.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/privatebin.sh && \
chmod +x scripts/privatebin.sh && \
./scripts/privatebin.sh
```
  
LXC updater
```bash
mkdir -p scripts && \
wget -O scripts/updatelxc.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/updatelxc.sh && \
chmod +x scripts/updatelxc.sh && \
./scripts/updatelxc.sh
```





<details>
  <summary><b>Debian LXC</b></summary>
  <br>
  <button
    onclick="navigator.clipboard.writeText(`mkdir -p scripts && \
wget -O scripts/deblxc.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/deblxc.sh && \
chmod +x scripts/deblxc.sh && \
./scripts/deblxc.sh`)"
  >Copy</button>
</details>




<!-- This text will never appear in the rendered page 

mkdir -p scripts scripts/backups && \
[ ! -f scripts/npm-podman.sh ] || cp -a scripts/npm-podman.sh "scripts/backups/npm-podman.sh.$(date +%F_%H%M%S).bak" && \
wget -O scripts/npm-podman.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-podman.sh && \
chmod +x scripts/npm-podman.sh && \
./scripts/npm-podman.sh

-->
