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

## Supported OS
- **Debian** 11 / 12  
- **Ubuntu** 20.04 / 22.04 / 24.04  

> Requires `systemd` + `apt` and outbound HTTPS to Let’s Encrypt.  
> In LXC/containers, AppArmor may be limited; the installer falls back to `--security-opt apparmor=unconfined`.

---

## What the Installer Does
1. Installs **Docker**, **Nginx** (+ **libnginx-mod-stream**), **Certbot**, and utilities.  
2. Provisions a Let’s Encrypt cert for your **TURN server FQDN** using **Nginx webroot** on port **80**.  
3. Writes a hardened **coturn** config with a global **REALM** and shared-secret auth.  
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

> Open these in your cloud firewall. If using Cloudflare DNS, set your TURN records to **DNS only** (grey cloud).

---

## Quick Start

1. Put the script in your repo as:
```
install-coturn-nextcloud-watchtower.sh
```

2. Run it on each server:
```bash
# First node (creates the REALM & SECRET if not supplied)
sudo REALM="talk.example.com" bash install-coturn-nextcloud-watchtower.sh

# Additional nodes (reuse the same SECRET printed by the first node)
sudo REALM="talk.example.com" SECRET="<same-secret>" bash install-coturn-nextcloud-watchtower.sh
```

The script prompts for:
- **TURN server FQDN** for *this node* (e.g., `turn-de.example.com`)
- **Realm** (defaults to `talk.example.com`; must be **identical on all nodes**)
- **Email** for Let’s Encrypt

At the end, it prints your **shared SECRET** and test credentials.

---

## Environment Flags

Set these before running the installer to customize behavior.

| Variable | Default | Description |
|---|---:|---|
| `REALM` | `talk.example.com` | Global realm string (same on all nodes) |
| `SECRET` | *(auto)* | Shared secret (hex). Provide to reuse across nodes. |
| `MINP` | `50000` | Start of UDP relay port range |
| `MAXP` | `50020` | End of UDP relay port range |
| `WATCH_SCHED` | `0 0 4 * * 0` | Watchtower cron (with **seconds**), Sun 04:00 local |
| `RESET` | `0` | If `1`, rotate TURN shared secret (update Nextcloud) |
| `PULL_NOW` | `0` | If `1`, `docker pull` latest images now |
| `FORCE_RENEW` | `0` | If `1`, force Let’s Encrypt renewal now |

Example:
```bash
sudo REALM="talk.example.com" RESET=1 PULL_NOW=1 WATCH_SCHED="0 15 3 * * 0" \
  bash install-coturn-nextcloud-watchtower.sh
```

---

## Configure Nextcloud Talk

**Settings → Administration → Talk → STUN/TURN servers**

For **each server** you deploy (e.g., `turn-de.example.com`, `turn-es.example.com`), add:

```text
STUN
  stun:<server-fqdn>:3478

TURN
  turn:<server-fqdn>:3478?transport=udp
  turn:<server-fqdn>:3478?transport=tcp
  turns:<server-fqdn>:5349?transport=tcp
  turns:<server-fqdn>:443?transport=tcp
```

**TURN secret**: paste the **shared SECRET** (same for all servers; one field in Nextcloud).  
Nextcloud does not have a realm field — only the secret.

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

**Recommendation:** add **all four** entries per server. ICE chooses the fastest path automatically.

---

## Multi-server Notes (same REALM & SECRET)

- Use **one global REALM** (e.g., `talk.example.com`) on all TURN servers.  
- Reuse the **same `SECRET`** across nodes (supply `SECRET="..."` env when running the script).  
- Each server should have its **own FQDN** and cert (e.g., `turn-de.example.com`, `turn-es.example.com`).  
- The realm string itself does **not** need DNS or a cert unless you also use it as a TURN endpoint.

**DNS patterns:** We recommend `turn-<region>.example.com` (easy certificates; wildcard-friendly).  
If you prefer one hostname with multiple A/AAAA records, use DNS with **health checks/latency routing** and prefer **DNS-01** for certificates.

---

## Files & Locations

- **Config:** `/opt/coturn/turnserver.conf`  
- **Logs:** `/opt/coturn/log/turn.log`  
- **Certs:** `/etc/letsencrypt/live/<server-fqdn>/{fullchain.pem,privkey.pem}`  
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
turnctl tls       # tests <server-fqdn>:5349
turnctl tls443    # tests <server-fqdn>:443 (via nginx passthrough)
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
3. Cloud firewall must allow **443/TCP**. Cloudflare DNS: **DNS only** for each TURN record.
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
sudo REALM="talk.example.com" RESET=1 bash install-coturn-nextcloud-watchtower.sh
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
