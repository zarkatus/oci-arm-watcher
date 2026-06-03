#!/bin/bash
# Instalação docker-mailserver em VM Oracle AMD 1GB (Ubuntu 22.04) para ces.eng.br
# Idempotente. Log em /home/ubuntu/install-mail.log
set -uo pipefail
exec > >(tee -a /home/ubuntu/install-mail.log) 2>&1
echo "===== install-mail $(date -u) ====="
DOMAIN="ces.eng.br"
HOST="mail.ces.eng.br"

# 1) SWAP 2G (1GB RAM precisa de folga)
if ! sudo swapon --show | grep -q swapfile; then
  echo "-- criando swap 2G"
  sudo fallocate -l 2G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
  sudo chmod 600 /swapfile; sudo mkswap /swapfile; sudo swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
  sudo sysctl vm.swappiness=20 >/dev/null
fi

# 2) Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "-- instalando Docker"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker ubuntu || true
fi

# 3) Abrir portas no iptables (imagem Oracle Ubuntu bloqueia por padrão) + persistir
echo "-- abrindo portas de mail no iptables"
for P in 25 80 443 110 143 465 587 993 995 4190; do
  sudo iptables -C INPUT -p tcp --dport $P -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 6 -p tcp --dport $P -j ACCEPT
done
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
sudo netfilter-persistent save >/dev/null 2>&1 || true

# 4) docker-mailserver
mkdir -p /home/ubuntu/dms && cd /home/ubuntu/dms
[ -f compose.yaml ] || curl -fsSL https://raw.githubusercontent.com/docker-mailserver/docker-mailserver/master/compose.yaml -o compose.yaml
[ -f mailserver.env ] || curl -fsSL https://raw.githubusercontent.com/docker-mailserver/docker-mailserver/master/mailserver.env -o mailserver.env

# hostname no compose
sed -i "s|hostname:.*|hostname: ${HOST}|" compose.yaml

# env: leve p/ 1GB
set_env(){ local k=$1 v=$2; if grep -q "^${k}=" mailserver.env; then sed -i "s|^${k}=.*|${k}=${v}|" mailserver.env; else echo "${k}=${v}" >> mailserver.env; fi; }
set_env ENABLE_CLAMAV 0
set_env ENABLE_RSPAMD 1
set_env ENABLE_OPENDKIM 0
set_env ENABLE_AMAVIS 0
set_env ENABLE_FAIL2BAN 1
set_env ENABLE_POP3 1
set_env ONE_DIR 1
set_env POSTMASTER_ADDRESS postmaster@${DOMAIN}
set_env SPOOF_PROTECTION 1
set_env SSL_TYPE ""        # self-signed até DNS+LE
set_env PERMIT_DOCKER none
set_env LOG_LEVEL info

echo "-- subindo container"
sudo docker compose up -d
echo "-- aguardando boot (40s)"; sleep 40

# 5) Caixas (senhas aleatórias) — 11 endereços
gen(){ openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16; }
CRED=/home/ubuntu/mail-credentials.txt; : > "$CRED"
for U in raphael contato comercial financeiro engenharia obras compras rh administrativo projetos diretoria; do
  PW=$(gen)
  sudo docker exec mailserver setup email add "${U}@${DOMAIN}" "${PW}" >/dev/null 2>&1 && echo "${U}@${DOMAIN}    ${PW}" >> "$CRED" && echo "  + ${U}@${DOMAIN}"
done

# 6) DKIM (rspamd, 2048)
echo "-- gerando DKIM"
sudo docker exec mailserver setup config dkim keysize 2048 domain "${DOMAIN}" >/dev/null 2>&1 || sudo docker exec mailserver setup config dkim >/dev/null 2>&1
sleep 3
DKIM_FILE=$(sudo find /home/ubuntu/dms -path '*rspamd/dkim*' -name '*.public.dns.txt' 2>/dev/null | head -1)
[ -z "$DKIM_FILE" ] && DKIM_FILE=$(sudo find /home/ubuntu/dms -path '*opendkim*' -name '*.txt' 2>/dev/null | head -1)

echo ""
echo "===================== RESULTADO ====================="
echo ">>> CAIXAS CRIADAS (credenciais em $CRED):"
cat "$CRED"
echo ""
echo ">>> REGISTRO DKIM (publicar no DNS):"
[ -n "$DKIM_FILE" ] && sudo cat "$DKIM_FILE" || echo "(DKIM não localizado — rodar: sudo docker exec mailserver cat /tmp/docker-mailserver/rspamd/dkim/*.public.dns.txt)"
echo ""
echo ">>> IP PÚBLICO: $(curl -s ifconfig.me)"
echo ">>> Container:"; sudo docker ps --format '  {{.Names}}  {{.Status}}'
echo ">>> Memória:"; free -h | grep -iE 'mem|swap'
echo "===================================================="
echo "install-mail FIM $(date -u)"
