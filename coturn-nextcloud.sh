#!/usr/bin/env bash
set -euo pipefail

# 0) Root & prereqs
if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo bash $0"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates dnsutils jq openssl

# Docker
command -v docker >/dev/null 2>&1 || { apt-get install -y docker.io; systemctl enable --now docker; }

# nginx + stream module
command -v nginx  >/dev/null 2>&1 || { apt-get install -y nginx;     systemctl enable --now nginx; }
apt-get install -y libnginx-mod-stream
[ -f /etc/nginx/modules-enabled/50-mod-stream.conf ] || \
  echo 'load_module /usr/lib/nginx/modules/ngx_stream_module.so;' > /etc/nginx/modules-enabled/50-mod-stream.conf

# Certbot
command -v certbot >/dev/null 2>&1 || apt-get install -y certbot

# AppArmor
apt-get install -y apparmor apparmor-utils || true
systemctl enable --now apparmor || true
APPARMOR_OPT=""
if command -v aa-status >/dev/null 2>&1; then
  aa-status >/dev/null 2>&1 || APPARMOR_OPT="--security-opt apparmor=unconfined"
else
  APPARMOR_OPT="--security-opt apparmor=unconfined"
fi

# 1) Inputs & toggles
read -rp "TURN domain (e.g. talk.example.com): " DOMAIN
[[ -z "${DOMAIN}" ]] && { echo "Domain cannot be empty"; exit 1; }
read -rp "Admin email for Let's Encrypt: " EMAIL
[[ -z "${EMAIL}" ]] && { echo "Email cannot be empty"; exit 1; }

MINP="${MINP:-50000}"
MAXP="${MAXP:-50020}"
WATCH_SCHED="${WATCH_SCHED:-0 0 4 * * 0}"  # Sun 04:00 (cron with seconds)
TZ_STR="$(cat /etc/timezone 2>/dev/null || echo UTC)"
RESET="${RESET:-0}"         # rotate TURN secret if 1
PULL_NOW="${PULL_NOW:-0}"   # docker pull latest if 1
FORCE_RENEW="${FORCE_RENEW:-0}" # force LE renewal if 1

# 2) DNS sanity
PUBIP4="$(curl -4 -s https://api.ipify.org || true)"
DNSV4="$(dig +short A "${DOMAIN}" | tail -n1 || true)"
if [[ -z "${PUBIP4}" || -z "${DNSV4}" || "${PUBIP4}" != "${DNSV4}" ]]; then
  echo "❌ DNS for ${DOMAIN} must point to ${PUBIP4}. Fix DNS and re-run."; exit 1
fi

# 3) nginx webroot on :80
WEBROOT="/var/www/certbot"; mkdir -p "${WEBROOT}"; chown -R www-data:www-data "${WEBROOT}"
ACME_SITE="/etc/nginx/sites-available/certbot-${DOMAIN}.conf"
cat > "${ACME_SITE}" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN};
  root ${WEBROOT};
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 200 'TURN ACME endpoint OK\n'; add_header Content-Type text/plain; }
}
EOF
ln -sf "${ACME_SITE}" "/etc/nginx/sites-enabled/certbot-${DOMAIN}.conf"
[[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# 4) Get/renew cert
certbot certonly --webroot -w "${WEBROOT}" -d "${DOMAIN}" \
  --agree-tos -m "${EMAIL}" --non-interactive --no-eff-email
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
[[ -s "${CERT_DIR}/fullchain.pem" && -s "${CERT_DIR}/privkey.pem" ]] || { echo "❌ Cert failed"; exit 1; }
[[ "${FORCE_RENEW}" = "1" ]] && certbot renew --force-renewal || true

# 5) coturn config (no listening-ip lines)
INSTALL_DIR="/opt/coturn"; LOG_DIR="${INSTALL_DIR}/log"; mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"
if [[ "${RESET}" = "1" ]] || ! grep -q 'static-auth-secret=' "${INSTALL_DIR}/turnserver.conf" 2>/dev/null; then
  SECRET="$(openssl rand -hex 32)"
else
  SECRET="$(grep -m1 'static-auth-secret=' "${INSTALL_DIR}/turnserver.conf" | cut -d= -f2)"
fi
sed -i '/^alt-tls-listening-port=/d' "${INSTALL_DIR}/turnserver.conf" 2>/dev/null || true
sed -i '/^lt-cred-mech$/d' "${INSTALL_DIR}/turnserver.conf" 2>/dev/null || true
sed -i '/^listening-ip=/d' "${INSTALL_DIR}/turnserver.conf" 2>/dev/null || true

cat > "${INSTALL_DIR}/turnserver.conf" <<EOF
# === coturn for Nextcloud Talk (shared-secret) ===
listening-port=3478
tls-listening-port=5349

external-ip=${PUBIP4}
realm=${DOMAIN}
server-name=${DOMAIN}

use-auth-secret
static-auth-secret=${SECRET}
stale-nonce
fingerprint

cert=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem
pkey=/etc/letsencrypt/live/${DOMAIN}/privkey.pem

min-port=${MINP}
max-port=${MAXP}

# These may log as "Bad configuration format" on some builds; harmless. Remove if noisy:
no-loopback-peers
no-multicast-peers

simple-log
log-file=/var/log/turnserver/turn.log
cli-password=$(openssl rand -hex 12)
EOF
chmod 600 "${INSTALL_DIR}/turnserver.conf"

# 6) (Re)deploy coturn
[[ "${PULL_NOW}" = "1" ]] && { docker pull coturn/coturn:latest || true; docker pull containrrr/watchtower:latest || true; }
docker rm -f coturn >/dev/null 2>&1 || true
docker run -d --name coturn \
  --restart unless-stopped \
  --network host \
  --user 0:0 \
  $APPARMOR_OPT \
  -v "${INSTALL_DIR}:/etc/coturn:ro" \
  -v "/etc/letsencrypt:/etc/letsencrypt:ro" \
  -v "${LOG_DIR}:/var/log/turnserver" \
  --label "com.centurylinklabs.watchtower.enable=true" \
  coturn/coturn:latest -c /etc/coturn/turnserver.conf
sleep 2
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -q '^coturn' || { echo "❌ coturn failed"; docker logs coturn || true; exit 1; }

# 7) nginx TCP stream — ALWAYS bind 443 and proxy to PUBLIC_IP:5349
mkdir -p /etc/nginx/streams-enabled
cat > /etc/nginx/streams-enabled/turn-443.conf <<EOF
server {
  listen 443 reuseport backlog=4096;
  proxy_pass ${PUBIP4}:5349;
  proxy_connect_timeout 5s;
  proxy_timeout 600s;
}
EOF
if ! grep -q 'streams-enabled/\*\.conf' /etc/nginx/nginx.conf; then
  sed -i '/include \/etc\/nginx\/modules-enabled\/\*\.conf;/a stream { include /etc/nginx/streams-enabled/*.conf; }' /etc/nginx/nginx.conf
fi
nginx -t && systemctl reload nginx

# 8) Open firewall (UFW if present)
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow 3478/tcp || true
  ufw allow 3478/udp || true
  ufw allow 5349/tcp || true
  ufw allow ${MINP}:${MAXP}/udp || true
fi

# 9) Certbot deploy hook
HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-coturn.sh"
mkdir -p "$(dirname "${HOOK}")"
cat > "${HOOK}" <<'HOK'
#!/usr/bin/env bash
set -e
systemctl reload nginx || true
if docker ps --format '{{.Names}}' | grep -q '^coturn$'; then
  docker restart coturn >/dev/null
fi
HOK
chmod +x "${HOOK}"

# 10) Watchtower weekly updates
docker rm -f watchtower >/dev/null 2>&1 || true
docker run -d --name watchtower \
  --restart unless-stopped \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e TZ="${TZ_STR}" \
  -e WATCHTOWER_SCHEDULE="${WATCH_SCHED}" \
  -e WATCHTOWER_CLEANUP="true" \
  --label "com.centurylinklabs.watchtower.enable=true" \
  containrrr/watchtower:latest --label-enable coturn watchtower

# 11) Helper
cat > /usr/local/bin/turnctl <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
CONF="/opt/coturn/turnserver.conf"
DOMAIN="$(grep -m1 '^realm=' "$CONF" | cut -d= -f2)"
SECRET="$(grep -m1 '^static-auth-secret=' "$CONF" | cut -d= -f2)"
PUBIP4="$(curl -4 -s https://api.ipify.org || true)"
case "${1:-}" in
  creds)
    USER=$(($(date +%s)+3600))
    PASS=$(printf "%s" "$USER" | openssl dgst -sha1 -mac HMAC -macopt hexkey:${SECRET} -binary | base64)
    echo "Username:  $USER"; echo "Password:  $PASS" ;;
  status)
    echo "TURN host: $DOMAIN  (IP: ${PUBIP4})"
    ss -ltnup '( sport = :3478 or sport = :5349 or sport = :443 )' || true ;;
  tls)    openssl s_client -connect "${DOMAIN}:5349" -servername "${DOMAIN}" -tls1_2 -brief </dev/null || true ;;
  tls443) openssl s_client -connect "${DOMAIN}:443"  -servername "${DOMAIN}" -tls1_2 -brief </dev/null || true ;;
  *) echo "turnctl cmds: creds | status | tls | tls443" ;;
esac
EOS
chmod +x /usr/local/bin/turnctl

# 12) Final output
USER_VAL=$(($(date +%s)+3600))
PASS_VAL=$(printf "%s" "$USER_VAL" | openssl dgst -sha1 -mac HMAC -macopt hexkey:${SECRET} -binary | base64)
cat <<EOT

===============================================================================
 ✅ TURN ready — 3478/udp+tcp, 5349/tcp, 443/tcp (nginx → ${PUBIP4}:5349)
===============================================================================
TURN host:            ${DOMAIN}
Public IPv4:          ${PUBIP4}
TURN shared secret:   ${SECRET}

Nextcloud → Settings → Administration → Talk
  STUN:
    stun:${DOMAIN}:3478
  TURN (add all):
    turn:${DOMAIN}:3478?transport=udp
    turn:${DOMAIN}:3478?transport=tcp
    turns:${DOMAIN}:5349?transport=tcp
    turns:${DOMAIN}:443?transport=tcp

Helper:   turnctl creds | turnctl status | turnctl tls | turnctl tls443
Config:   /opt/coturn/turnserver.conf
Logs:     /opt/coturn/log/turn.log

Watchtower:
  Schedule: ${WATCH_SCHED} (Sun 04:00 default)   TZ: ${TZ_STR}

Notes:
  • Cloudflare DNS → **DNS only** (grey cloud).
  • Cloud firewall must allow: 80/tcp, 443/tcp, 3478/udp+tcp, 5349/tcp, ${MINP}-${MAXP}/udp.
  • Re-run anytime to reinstall/update. Optional flags:
      RESET=1  PULL_NOW=1  FORCE_RENEW=1
===============================================================================
EOT
