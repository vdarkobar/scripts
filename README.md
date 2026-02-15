# scripts
Proxmox scripts

### Quick Install:  

```bash
mkdir -p scripts && \
wget -O scripts/deblxc.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/deblxc.sh && \
chmod +x scripts/deblxc.sh && \
./scripts/deblxc.sh 
```
  
```bash
mkdir -p scripts && \
wget -O scripts/npm-podman.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-podman.sh && \
chmod +x scripts/npm-podman.sh && \
./scripts/npm-podman.sh 
```
  
```bash
mkdir -p scripts && \
wget -O scripts/unbound.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/unbound.sh && \
chmod +x scripts/unbound.sh && \
./scripts/unbound.sh  
```
  
```bash
mkdir -p scripts && \
wget -O scripts/updatelxc.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/updatelxc.sh && \
chmod +x scripts/updatelxc.sh && \
./scripts/updatelxc.sh  
```



<!-- This text will never appear in the rendered page 

mkdir -p scripts scripts/backups && \
[ ! -f scripts/npm-podman.sh ] || cp -a scripts/npm-podman.sh "scripts/backups/npm-podman.sh.$(date +%F_%H%M%S).bak" && \
wget -O scripts/npm-podman.sh https://raw.githubusercontent.com/vdarkobar/scripts/main/npm-podman.sh && \
chmod +x scripts/npm-podman.sh && \
./scripts/npm-podman.sh

-->
