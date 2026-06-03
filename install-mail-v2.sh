#!/bin/bash
###############################################################################
# install-mail-v2.sh  ·  ces.eng.br  ·  Oracle AMD E2.1.Micro (1GB) Ubuntu 22.04
# Executado por cloud-init (root) no PRIMEIRO boot. Idempotente.
# Secrets escritos por cloud-init ANTES em /opt/mail/secrets/:
#   - dkim.private        (chave privada DKIM RSA-2048, seletor "mail")
#   - passwords.tsv       (linhas: usuario<TAB>senha)
# Site servido pelo Caddy a partir de /opt/mail/site (clonado do repo).
# Log: /var/log/ces-install.log
###############################################################################
set -uo pipefail
exec > >(tee -a /var/log/ces-install.log) 2>&1
echo "===== ces install-mail-v2 START $(date -u) ====="

DOMAIN="ces.eng.br"
HOST="mail.ces.eng.br"
BASE=/opt/mail
SEC=$BASE/secrets

# 0) Pré-checagens
[ -f "$SEC/dkim.private" ] || { echo "FATAL: falta $SEC/dkim.private"; exit 1; }
[ -f "$SEC/passwords.tsv" ] || { echo "FATAL: falta $SEC/passwords.tsv"; exit 1; }

export DEBIAN_FRONTEND=noninteractive

# 1) SWAP 3G (1GB RAM precisa de folga para o stack)
if ! swapon --show | grep -q swapfile; then
  echo "-- swap 3G"
  fallocate -l 3G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=3072
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
sysctl -w vm.swappiness=10 >/dev/null
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

# 2) Pacotes base + Docker
apt-get update -y
apt-get install -y ca-certificates curl git ufw >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  echo "-- docker"
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker

# 3) Firewall do host (Oracle Ubuntu bloqueia por padrão via iptables).
#    Inserir ACCEPT ANTES das regras REJECT existentes (posição 6 no chain INPUT da imagem Oracle).
for P in 22 25 80 443 465 587 993 995 110 143 4190; do
  iptables -C INPUT -p tcp --dport $P -j ACCEPT 2>/dev/null || iptables -I INPUT 6 -p tcp --dport $P -j ACCEPT
done
netfilter-persistent save 2>/dev/null || { apt-get install -y iptables-persistent >/dev/null; netfilter-persistent save; }

# 4) Site (clona do repo público; se falhar, placeholder)
mkdir -p $BASE/site
if [ ! -f $BASE/site/index.html ]; then
  git clone --depth 1 https://github.com/zarkatus/oci-arm-watcher $BASE/_repo 2>/dev/null && \
    cp -r $BASE/_repo/site/* $BASE/site/ 2>/dev/null || echo "<h1>ces.eng.br</h1>" > $BASE/site/index.html
fi

# 5) docker-mailserver config
mkdir -p $BASE/dms/docker-data/dms/config
cd $BASE/dms

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
SSL_TYPE=manual
SSL_CERT_PATH=/etc/letsencrypt/live/${HOST}/fullchain.pem
SSL_KEY_PATH=/etc/letsencrypt/live/${HOST}/privkey.pem
POSTFIX_INET_PROTOCOLS=ipv4
LOG_LEVEL=info
ENV

# 6) Compose: mailserver + snappymail (webmail leve) + caddy (site + webmail + TLS)
cat > $BASE/docker-compose.yml <<YML
services:
  mailserver:
    image: ghcr.io/docker-mailserver/docker-mailserver:latest
    hostname: ${HOST}
    env_file: ./dms/mailserver.env
    ports:
      - "25:25"
      - "465:465"
      - "587:587"
      - "993:993"
      - "995:995"
      - "110:110"
      - "143:143"
    volumes:
      - ./dms/docker-data/dms/mail-data/:/var/mail/
      - ./dms/docker-data/dms/mail-state/:/var/mail-state/
      - ./dms/docker-data/dms/mail-logs/:/var/log/mail/
      - ./dms/docker-data/dms/config/:/tmp/docker-mailserver/
      - ./caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${HOST}/:/etc/letsencrypt/live/${HOST}/:ro
      - /etc/localtime:/etc/localtime:ro
    restart: always
    stop_grace_period: 1m
    cap_add: [NET_ADMIN]

  snappymail:
    image: djmaze/snappymail:latest
    restart: always
    expose: ["8888"]
    volumes:
      - ./snappymail:/var/lib/snappymail

  caddy:
    image: caddy:2-alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv/site:ro
      - ./caddy/data:/data
      - ./caddy/config:/config
YML

# 7) Caddyfile: site (apex+www) estático; webmail (mail.) -> snappymail; emite certs LE
cat > $BASE/Caddyfile <<CADDY
{
  email postmaster@${DOMAIN}
}
${DOMAIN}, www.${DOMAIN} {
  root * /srv/site
  file_server
  encode gzip
}
${HOST} {
  reverse_proxy snappymail:8888
}
CADDY

# 8) Injeta DKIM pré-gerado no rspamd (seletor "mail")
DKIMDIR=$BASE/dms/docker-data/dms/config/rspamd/dkim
mkdir -p $DKIMDIR
cp $SEC/dkim.private $DKIMDIR/${DOMAIN}.mail.key
chmod 600 $DKIMDIR/${DOMAIN}.mail.key
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
mkdir -p $BASE/dms/docker-data/dms/config/rspamd/override.d

# 9) Sobe o stack
cd $BASE
docker compose up -d
echo "-- aguardando mailserver subir"
for i in $(seq 1 30); do docker exec mailserver true 2>/dev/null && break; sleep 5; done

# 10) Cria as 11 caixas com as senhas pré-geradas
while IFS=$'\t' read -r U PW; do
  [ -z "$U" ] && continue
  docker exec mailserver setup email add "${U}@${DOMAIN}" "${PW}" 2>/dev/null && echo "  + ${U}@${DOMAIN}"
done < $SEC/passwords.tsv

docker exec mailserver setup config dkim 2>/dev/null || true   # garante estrutura rspamd

echo "===== ces install-mail-v2 DONE $(date -u) ====="
echo "STATUS_OK" > $BASE/INSTALL_DONE
