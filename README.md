# Nextcloud Talk TURN Server  
**coturn (Docker) + Let’s Encrypt + Nginx :443 TCP passthrough + Watchtower**

![OS](https://img.shields.io/badge/OS-Debian%2011%2F12%20%7C%20Ubuntu%2020.04%2F22.04%2F24.04-blue)
![Docker](https://img.shields.io/badge/Docker-ready-2496ED?logo=docker&logoColor=white)
![Nginx Stream](https://img.shields.io/badge/Nginx-stream%20(TCP)-009639?logo=nginx&logoColor=white)
![Certbot](https://img.shields.io/badge/Certbot-LE%20webroot-3A833C)
![Auto Updates](https://img.shields.io/badge/Watchtower-weekly%20updates-23B2A7)
![License](https://img.shields.io/badge/License-MIT-yellow)

A one-command installer that deploys a **TURN** server for **Nextcloud Talk**:

- **coturn** in Docker with `use-auth-secret` (HMAC/shared secret)  
- **TLS** on `:5349` (coturn) and **:443** via **Nginx TCP passthrough**  
- **Let’s Encrypt** (webroot) with **zero-downtime renewals**  
- **Auto-restart** coturn after renewals  
- **Watchtower** for **weekly** container updates  
- **AppArmor** self-heal (safe fallback if unavailable)  
- `turnctl` helper (creds / status / TLS checks)

---

## Table of Contents
- [Supported OS](#supported-os)
- [What the Installer Does](#what-the-installer-does)
- [Ports](#ports)
- [Quick Start](#quick-start)
- [Environment Flags](#environment-flags)
- [Configure Nextcloud Talk](#configure-nextcloud-talk)
- [Performance & Behavior (turn vs turns)](#performance--behavior-turn-vs-turns)
- [Security Notes](#security-notes)
- [Files & Locations](#files--locations)
- [Helper Commands](#helper-commands)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [License](#license)

---

## Supported OS
- **Debian** 11 / 12  
- **Ubuntu** 20.04 / 22.04 / 24.04  

> Requires `systemd` + `apt` and outbound HTTPS to Let’s Encrypt.  
> In LXC/containers, AppArmor may be limited; the installer falls back to `--security-opt apparmor=unconfined`.

---

## What the Installer Does
1. Installs **Docker**, **Nginx** (+ **libnginx-mod-stream**), **Certbot**, and utilities.  
2. Provisions a Let’s Encrypt cert for your **TURN domain** using **Nginx webroot** on port **80**.  
3. Writes a hardened **coturn** config with **shared secret** and a small **UDP relay** range.  
4. Runs **coturn** (Docker) with **host networking** and **root** to read LE certs.  
5. Binds **Nginx :443** and **TCP-proxies** to **`PUBLIC_IP:5349`** (coturn’s TLS).  
6. Installs a **cert deploy hook** that restarts coturn after each renewal.  
7. Deploys **Watchtower** with **weekly** updates (Sun 04:00 local, configurable).  
8. Installs a `turnctl` helper CLI.

---

## Ports

| Port/Proto | Purpose |
|---|---|
| **80/TCP** | ACME HTTP-01 (Certbot webroot via Nginx) |
| **443/TCP** | **Nginx** TCP passthrough → **coturn** TLS on **5349** (`turns:`) |
| **3478/UDP+TCP** | TURN signaling/allocations (best reachability) |
| **5349/TCP** | TURN over TLS (coturn terminates TLS) |
| **50,000–50,020/UDP** | TURN media relays (configurable via `MINP/MAXP`) |

> Open these in your cloud firewall. If using Cloudflare DNS, set your TURN record to **DNS only** (grey cloud).

---

## Quick Start

1. Put the script in your repo as:
```
install-coturn-nextcloud-watchtower.sh
```

2. Run it:
```bash
sudo bash install-coturn-nextcloud-watchtower.sh
```
You’ll be asked for your **TURN domain** (e.g., `talk.example.com`) and **email** for Let’s Encrypt.

3. At the end, the script prints your **TURN shared secret** and test credentials.

---

## Environment Flags

Set these before running the installer to customize behavior.

| Variable | Default | Description |
|---|---:|---|
| `MINP` | `50000` | Start of UDP relay port range |
| `MAXP` | `50020` | End of UDP relay port range |
| `WATCH_SCHED` | `0 0 4 * * 0` | Watchtower cron (with **seconds**), Sun 04:00 local |
| `RESET` | `0` | If `1`, rotate TURN shared secret (update Nextcloud) |
| `PULL_NOW` | `0` | If `1`, `docker pull` latest images now |
| `FORCE_RENEW` | `0` | If `1`, force Let’s Encrypt renewal now |

Example:
```bash
sudo RESET=1 PULL_NOW=1 WATCH_SCHED="0 15 3 * * 0" bash install-coturn-nextcloud-watchtower.sh
```

---

## Configure Nextcloud Talk

**Settings → Administration → Talk → STUN/TURN servers**

```text
STUN
  stun:<your-domain>:3478

TURN (add all)
  turn:<your-domain>:3478?transport=udp
  turn:<your-domain>:3478?transport=tcp
  turns:<your-domain>:5349?transport=tcp
  turns:<your-domain>:443?transport=tcp
```

**TURN secret**: paste the value printed by the installer.

> Browsers automatically test all paths (ICE) and pick the **fastest working** one.

---

## Performance & Behavior (turn vs turns)

- **`turn:…?transport=udp` (3478/UDP)**  
  ⚡ *Best performance.* Lowest latency/jitter. Preferred when available.

- **`turn:…?transport=tcp` (3478/TCP)**  
  🛟 *Fallback when UDP is blocked.* Slightly higher latency and HOL blocking risk.

- **`turns:…:5349?transport=tcp`**  
  🔒 TURN inside TLS. Protects TURN credentials + helps on TLS-only networks.  
  Media performance ≈ `turn:…tcp` (same transport). TLS overhead is on control channel only.

- **`turns:…:443?transport=tcp` (via Nginx passthrough)**  
  🧱 Works through most corporate/ISP firewalls that only allow HTTPS.  
  Nginx forwards raw TCP → coturn’s TLS at **5349**; TLS still terminates at **coturn**.

**Recommendation:** add **all four** entries. ICE chooses the fastest path automatically.

---

## Security Notes

- WebRTC voice/video is encrypted **end-to-end** with **DTLS-SRTP**.  
  Even when relayed through TURN, your server **cannot decrypt** media.
- Using `turns:` encrypts the **TURN control channel** (credentials + metadata) with TLS.
- For Cloudflare DNS, the TURN record must be **DNS only** (no orange proxy).

---

## Files & Locations

- **Config:** `/opt/coturn/turnserver.conf`  
- **Logs:** `/opt/coturn/log/turn.log`  
- **Certs:** `/etc/letsencrypt/live/<domain>/{fullchain.pem,privkey.pem}`  
- **Nginx stream:** `/etc/nginx/streams-enabled/turn-443.conf`  
- **Cert hook:** `/etc/letsencrypt/renewal-hooks/deploy/restart-coturn.sh`  
- **Helper:** `/usr/local/bin/turnctl`

---

## Helper Commands

```bash
# Show listeners (3478/5349/443) and public IP
turnctl status

# Generate 1-hour test credentials
turnctl creds

# TLS checks
turnctl tls       # tests <domain>:5349
turnctl tls443    # tests <domain>:443 (via nginx passthrough)
```

Low-level checks:
```bash
ss -ltnp | grep ':443'        # who owns 443
docker logs --tail=200 coturn # coturn logs
```

---

## Troubleshooting

<details>
<summary><b>443 fails / handshake refused</b></summary>

1. Ensure the **nginx stream module** is installed and loaded:
   ```bash
   apt-get install -y libnginx-mod-stream
   ls -l /etc/nginx/modules-enabled/*stream*.conf
   ```
2. Confirm the stream include exists and reload:
   ```bash
   grep 'streams-enabled' /etc/nginx/nginx.conf || \
     sudo sed -i '/modules-enabled\/\*\.conf;/a stream { include /etc/nginx/streams-enabled/*.conf; }' /etc/nginx/nginx.conf

   nginx -t && systemctl reload nginx
   ss -ltnp | grep ':443'
   ```
3. Cloud firewall must allow **443/TCP**. Cloudflare DNS: **DNS only** for the record.
</details>

<details>
<summary><b>Calls connect but no audio/video</b></summary>

Open these in your cloud firewall/security group:
- **3478/UDP**, **3478/TCP**
- **5349/TCP**
- **443/TCP**
- **UDP relay range** `MINP`–`MAXP` (default **50000–50020**)
</details>

<details>
<summary><b>Rotate the TURN secret</b></summary>

```bash
sudo RESET=1 bash install-coturn-nextcloud-watchtower.sh
```
Then update the new secret in **Nextcloud → Talk**.
</details>

<details>
<summary><b>Update images now</b></summary>

```bash
sudo PULL_NOW=1 bash install-coturn-nextcloud-watchtower.sh
```
(Watchtower also updates weekly according to `WATCH_SCHED`.)
</details>

---

## Uninstall

```bash
# Stop containers
docker rm -f coturn watchtower || true

# Remove files (optional)
rm -rf /opt/coturn
rm -f /etc/nginx/streams-enabled/turn-443.conf
rm -f /etc/nginx/sites-enabled/certbot-*.conf /etc/nginx/sites-available/certbot-*.conf
rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-coturn.sh
systemctl reload nginx || true

# (Optional) remove packages if unused
# apt-get purge -y docker.io nginx libnginx-mod-stream certbot apparmor apparmor-utils
```

---

## License
**MIT** — feel free to use, modify, and share. Add a `LICENSE` file in your repo with the MIT text.
