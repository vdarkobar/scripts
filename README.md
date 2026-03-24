# Proxmox Scripts
#### *container creation, configuration and app install*

## Infrastructure
<details>
  <summary>PVE Drive Inventory</summary>
  <p>At-a-glance hardware and storage health for Proxmox VE.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/pve-drive-inventory.sh)</code></pre>
  <p>ZFS Helper Script.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/zfs-helper.sh)</code></pre>
</details>

<details>
  <summary>Debian LXC</summary>
  <p>Creates a Debian LXC container.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/deblxc.sh)</code></pre>
</details>

<details>
  <summary>PBS</summary>
  <p>Proxmox Backup Server on Debian LXC.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/pbs-lxc.sh)</code></pre>
</details>

<details>
  <summary>LXC updater</summary>
  <p>Updates LXC containers.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/lxc-update.sh)</code></pre>
</details>

<details>
  <summary>LXC delete</summary>
  <p>Deletes LXC containers.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/lxc-delete.sh)</code></pre>
</details>

## Network Services
<details>
  <summary>NPM on Podman, optional Cloudflared</summary>
  <p>Runs Nginx Proxy Manager on Podman, with optional Cloudflared.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/npm-podman.sh)</code></pre>
</details>

<details>
  <summary>Unbound DNS</summary>
  <p>Validating, recursive, caching DNS resolver.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/unbound.sh)</code></pre>
</details>

<details>
  <summary>Pi-Hole</summary>
  <p>Network-wide Ad Blocking.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/pihole.sh)</code></pre>
</details>

<details>
  <summary>Uptime Kuma</summary>
  <p>A Fancy Self-Hosted Monitoring Tool.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/uptime-kuma-podman.sh)</code></pre>
</details>

## Files & Storage
<details>
  <summary>Samba File server</summary>
  <p>File sharing server for your network.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/samba.sh)</code></pre>
</details>

<details>
  <summary>Nextcloud AIO on Docker</summary>
  <p>Open source content collaboration platform.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/nextcloud-aio-docker.sh)</code></pre>
</details>

<details>
  <summary>Immich on Podman</summary>
  <p>Self-hosted photo and video backup platform.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/immich-podman.sh)</code></pre>
</details>

<details>
  <summary>FileBrowser Quantum</summary>
  <p>Temporary web-based file manager for managing container files.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/filebrowser.sh)</code></pre>
</details>

## Communication
<details>
  <summary>Matrix on Podman</summary>
  <p><a href="https://github.com/vdarkobar/scripts/blob/main/misc/matrix-how-to.md">Decentralised communication platform.</a></p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/matrix-podman.sh)</code></pre>
</details>

## Notes & Writing
<details>
  <summary>Docmost</summary>
  <p>Collaborative wiki and documentation platform.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/docmost.sh)</code></pre>
</details>

<details>
  <summary>Docmost on Podman</summary>
  <p>Collaborative wiki and documentation platform on Podman.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/docmost-podman.sh)</code></pre>
</details>

<details>
  <summary>Flatnotes on Podman</summary>
  <p>Database-less note-taking web app.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/flatnotes-podman.sh)</code></pre>
</details>

<details>
  <summary>Cryptpad</summary>
  <p>Private collaborative office suite.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/cryptpad.sh)</code></pre>
</details>

## Media & Libraries
<details>
  <summary>Kavita</summary>
  <p>Digital library server.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/kavita-native.sh)</code></pre>
</details>

<details>
  <summary>Kavita on Podman</summary>
  <p>Digital library server on Podman.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/kavita-podman.sh)</code></pre>
</details>

## Privacy
<details>
  <summary>SearXNG</summary>
  <p>Privacy-focused metasearch engine.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/searxng.sh)</code></pre>
</details>

<details>
  <summary>SearXNG on Podman</summary>
  <p>Privacy-focused metasearch engine on Podman.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/searxng-podman.sh)</code></pre>
</details>

<details>
  <summary>Privatebin</summary>
  <p>Minimalist self-hosted pastebin.</p>
  <pre><code>bash &lt;(curl -fsSL https://raw.githubusercontent.com/vdarkobar/scripts/main/bash/privatebin.sh)</code></pre>
</details>
