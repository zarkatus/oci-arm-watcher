#!/bin/bash
###############################################################################
# install-mail-v2.sh · ces.eng.br · Oracle AMD E2.1.Micro (1GB) Ubuntu 22.04
# Rodado por cloud-init (root) no 1º boot. Idempotente. Revisado (27 achados).
# Secrets escritos por cloud-init ANTES em /opt/mail/secrets/:
#   dkim.private (RSA-2048, seletor "mail") · passwords.tsv (user<TAB>senha)
#   relay.env (OPCIONAL: RELAYHOST/RELAY_USER/RELAY_PASSWORD p/ envio externo)
# TLS: mailserver=self-signed (boot imediato); Caddy=Let's Encrypt p/ web+webmail.
# Log: /var/log/ces-install.log
###############################################################################
set -Eeuo pipefail
trap 'echo "[ERRO] linha $LINENO (rc=$?)"' ERR

DOMAIN="ces.eng.br"; HOST="mail.ces.eng.br"; BASE=/opt/mail; SEC=$BASE/secrets

# 0) Secrets devem existir E ter conteúdo (antes do redirect de log)
for f in "$SEC/dkim.private" "$SEC/passwords.tsv"; do
  [ -f "$f" ] && [ -s "$f" ] || { echo "FATAL: $f ausente ou vazio"; exit 1; }
done
mkdir -p /var/log
exec > >(tee -a /var/log/ces-install.log) 2>&1
echo "===== ces install-mail-v2 START $(date -u) ====="
export DEBIAN_FRONTEND=noninteractive

# 1) SWAP 3G
if ! swapon --show | grep -q swapfile; then
  fallocate -l 3G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=3072
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10 >/dev/null || true
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

# 2) Docker
apt-get update -y
apt-get install -y ca-certificates curl git >/dev/null
command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 3) Firewall host — detecta posição da REJECT dinamicamente
REJECT_POS=$(iptables -nL INPUT --line-numbers 2>/dev/null | awk '/REJECT/{print $1; exit}')
[ -n "$REJECT_POS" ] || REJECT_POS=1
for P in 22 25 80 443 465 587 993 995 110 143 4190; do
  iptables -C INPUT -p tcp --dport $P -j ACCEPT 2>/dev/null || iptables -I INPUT "$REJECT_POS" -p tcp --dport $P -j ACCEPT
done
iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT "$REJECT_POS" -p udp --dport 53 -j ACCEPT
# DOCKER/DOCKER-USER chains são geridas pelo Docker (dinâmicas) — não tocar.
apt-get install -y iptables-persistent >/dev/null 2>&1 || true
netfilter-persistent save 2>/dev/null || true

# 4) Site (clona do repo público)
mkdir -p $BASE/site
if [ ! -f $BASE/site/index.html ]; then
  if git clone --depth 1 https://github.com/zarkatus/oci-arm-watcher $BASE/_repo 2>/dev/null && [ -d $BASE/_repo/site ]; then
    cp -r $BASE/_repo/site/* $BASE/site/ 2>/dev/null || true
  fi
  [ -f $BASE/site/index.html ] || echo "<h1>C&amp;S Engenharia · ces.eng.br</h1>" > $BASE/site/index.html
fi

# 5) Diretórios DMS/rspamd ANTES de qualquer escrita
mkdir -p $BASE/dms/docker-data/dms/config/rspamd/override.d
mkdir -p $BASE/dms/docker-data/dms/config/rspamd/dkim
mkdir -p $BASE/dms/docker-data/dms/{mail-data,mail-state,mail-logs}
mkdir -p $BASE/snappymail $BASE/caddy/data $BASE/caddy/config

# 6) DKIM pré-gerado no rspamd (seletor "mail")
cp "$SEC/dkim.private" $BASE/dms/docker-data/dms/config/rspamd/dkim/${DOMAIN}.mail.key
chmod 600 $BASE/dms/docker-data/dms/config/rspamd/dkim/${DOMAIN}.mail.key
cat > $BASE/dms/docker-data/dms/config/rspamd/override.d/dkim_signing.conf <<RSP
enabled = true;
sign_authenticated = true;
sign_local = true;
selector = "mail";
domain {
  ${DOMAIN} {
    path = "/tmp/docker-mailserver/rspamd/dkim/${DOMAIN}.mail.key";
    selector = "mail";
  }
}
RSP
cat > $BASE/dms/docker-data/dms/config/rspamd/override.d/redis.conf <<'RED'
maxmemory = "48mb";
maxmemory_policy = "allkeys-lru";
RED

# 7) mailserver.env — TLS self-signed (boot imediato, sem depender de DNS/cert)
cat > $BASE/dms/mailserver.env <<ENV
OVERRIDE_HOSTNAME=${HOST}
POSTMASTER_ADDRESS=postmaster@${DOMAIN}
ENABLE_CLAMAV=0
ENABLE_AMAVIS=0
ENABLE_RSPAMD=1
ENABLE_OPENDKIM=0
ENABLE_OPENDMARC=0
ENABLE_POLICYD_SPF=0
ENABLE_FAIL2BAN=0
ENABLE_POP3=1
ENABLE_IMAP=1
ONE_DIR=1
SPOOF_PROTECTION=1
PERMIT_DOCKER=none
SSL_TYPE=self-signed
POSTFIX_INET_PROTOCOLS=ipv4
LOG_LEVEL=info
ENV
# Relay de saída OPCIONAL (Oracle bloqueia 25/egress) — só se cloud-init forneceu
if [ -f "$SEC/relay.env" ] && [ -s "$SEC/relay.env" ]; then
  cat "$SEC/relay.env" >> $BASE/dms/mailserver.env
  echo "-- relay de saída configurado"
fi

# 8) Compose — mem_limits, stop_grace, sem cert compartilhado
cat > $BASE/docker-compose.yml <<YML
services:
  mailserver:
    image: ghcr.io/docker-mailserver/docker-mailserver:latest
    hostname: ${HOST}
    env_file: ./dms/mailserver.env
    ports: ["25:25","465:465","587:587","993:993","995:995","110:110","143:143"]
    volumes:
      - ./dms/docker-data/dms/mail-data/:/var/mail/
      - ./dms/docker-data/dms/mail-state/:/var/mail-state/
      - ./dms/docker-data/dms/mail-logs/:/var/log/mail/
      - ./dms/docker-data/dms/config/:/tmp/docker-mailserver/
      - /etc/localtime:/etc/localtime:ro
    restart: always
    stop_grace_period: 1m
    mem_limit: 600m
    mem_reservation: 400m
    cap_add: [NET_ADMIN]
  snappymail:
    image: djmaze/snappymail:latest
    restart: always
    expose: ["8888"]
    volumes: ["./snappymail:/var/lib/snappymail"]
    stop_grace_period: 30s
    mem_limit: 160m
  caddy:
    image: caddy:2-alpine
    restart: always
    ports: ["80:80","443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv/site:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
    stop_grace_period: 30s
    mem_limit: 80m
YML

# 9) Caddyfile — site (apex+www) + webmail (mail.) ; SMTP/IMAP NÃO passam por Caddy
cat > $BASE/Caddyfile <<CADDY
{
  email postmaster@${DOMAIN}
}
# Site institucional
${DOMAIN}, www.${DOMAIN} {
  root * /srv/site
  file_server
  encode gzip
}
# Webmail (HTTPS -> snappymail). SMTP/IMAP TLS são servidos nativamente pelo
# mailserver nas portas 25/465/587/993/995 do host (não passam pelo Caddy).
${HOST} {
  reverse_proxy snappymail:8888
  encode gzip
}
CADDY

# 10) Pré-pull (evita pico de memória durante o up) e sobe
cd $BASE
docker compose pull
docker compose up -d

# 11) Health real do mailserver
echo "-- aguardando mailserver saudável"
for i in $(seq 1 60); do
  if docker exec mailserver postfix status >/dev/null 2>&1; then echo "  postfix ok ($i)"; break; fi
  sleep 5
done
# espera DB de contas estabilizar
sleep 10

# 12) Cria as 11 caixas (retry, sem engolir erro, processa última linha)
echo "-- criando caixas"
while IFS=$'\t' read -r U PW || [ -n "${U:-}" ]; do
  [ -z "${U:-}" ] && continue
  [ -z "${PW:-}" ] && continue
  for a in 1 2 3; do
    if docker exec mailserver setup email add "${U}@${DOMAIN}" "${PW}"; then echo "  + ${U}@${DOMAIN}"; break; fi
    [ $a -lt 3 ] && sleep 5
  done
done < "$SEC/passwords.tsv"

echo "-- contas:"; docker exec mailserver setup email list 2>/dev/null || true
echo "-- containers:"; docker ps --format '  {{.Names}} {{.Status}}'
echo "-- memória:"; free -h | grep -iE 'mem|swap'
echo "===== ces install-mail-v2 DONE $(date -u) ====="
echo "STATUS_OK $(date -u)" > $BASE/INSTALL_DONE
