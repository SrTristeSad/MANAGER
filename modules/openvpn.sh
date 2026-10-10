#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

OVPN_NAME="manager"
OVPN_DIR="/etc/openvpn/server"
OVPN_CONF="$OVPN_DIR/$OVPN_NAME.conf"
STATE_DIR="$MANAGER_ETC/openvpn"
EASYRSA_DIR="$STATE_DIR/easy-rsa"
CLIENT_DIR="$STATE_DIR/clients"
META_DIR="$STATE_DIR/meta"
TLS_KEY="$OVPN_DIR/manager-tls-crypt.key"
CA_FILE="$OVPN_DIR/manager-ca.crt"
SERVER_CERT="$OVPN_DIR/manager-server.crt"
SERVER_KEY="$OVPN_DIR/manager-server.key"
CRL_FILE="$OVPN_DIR/manager-crl.pem"
SYSCTL_FILE="/etc/sysctl.d/99-manager-openvpn.conf"
OVERRIDE_DIR="/etc/systemd/system/openvpn-server@manager.service.d"
OVERRIDE_FILE="$OVERRIDE_DIR/10-manager-network.conf"
VPN_NET="10.8.0.0"
VPN_MASK="255.255.255.0"
VPN_SERVER_IP="10.8.0.1"

service_name() { printf 'openvpn-server@%s' "$OVPN_NAME"; }

extract_pem() {
  local begin="$1" end="$2" file="$3"
  awk -v b="$begin" -v e="$end" '$0 ~ b {p=1} p {print} $0 ~ e {exit}' "$file"
}

install_server() {
  header
  say "${C_WHITE}INSTALAR OPENVPN${C_RESET}\n"
  if [[ -f "$OVPN_CONF" ]]; then
    warn "$OVPN_CONF já existe. O MANAGER não irá sobrescrever o servidor existente."
    pause
    return
  fi

  local port proto iface endpoint endpoint_in
  read -r -p "Porta [1194]: " port
  port="${port:-1194}"
  is_valid_port "$port" || { err "Porta inválida"; pause; return; }
  read -r -p "Protocolo [udp/tcp] (udp): " proto
  proto="${proto:-udp}"
  [[ "$proto" == udp || "$proto" == tcp ]] || { err "Protocolo inválido"; pause; return; }
  iface="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  [[ -n "$iface" ]] || { err "Não encontrei a interface de saída padrão"; pause; return; }
  endpoint="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  read -r -p "IP/domínio público do servidor [$endpoint]: " endpoint_in
  endpoint="${endpoint_in:-$endpoint}"
  [[ -n "$endpoint" ]] || { err "Informe um endpoint público"; pause; return; }

  say "\nRede VPN: $VPN_NET/24"
  say "Serviço: $(service_name)"
  say "PKI: Easy-RSA local, sem depender de CA externa."
  confirm "Instalar OpenVPN em $endpoint:$port/$proto?" || return

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y openvpn easy-rsa iptables ca-certificates
  install -d -m 0700 "$STATE_DIR" "$EASYRSA_DIR" "$CLIENT_DIR" "$META_DIR"
  install -d -m 0755 "$OVPN_DIR" "$OVERRIDE_DIR"

  cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
  chmod -R go-rwx "$EASYRSA_DIR"
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa init-pki
    EASYRSA_BATCH=1 EASYRSA_REQ_CN="MANAGER VPN CA" ./easyrsa build-ca nopass
    EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass
    EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
  )

  install -m 0644 "$EASYRSA_DIR/pki/ca.crt" "$CA_FILE"
  extract_pem '-----BEGIN CERTIFICATE-----' '-----END CERTIFICATE-----' "$EASYRSA_DIR/pki/issued/server.crt" > "$SERVER_CERT"
  install -m 0600 "$EASYRSA_DIR/pki/private/server.key" "$SERVER_KEY"
  install -m 0644 "$EASYRSA_DIR/pki/crl.pem" "$CRL_FILE"
  openvpn --genkey secret "$TLS_KEY"
  chmod 0600 "$TLS_KEY" "$SERVER_KEY"
  chmod 0644 "$CA_FILE" "$SERVER_CERT" "$CRL_FILE"

  printf '%s\n' "$endpoint" > "$STATE_DIR/endpoint"
  printf '%s\n' "$port" > "$STATE_DIR/port"
  printf '%s\n' "$proto" > "$STATE_DIR/proto"
  printf '%s\n' "$iface" > "$STATE_DIR/egress-interface"
  chmod 0600 "$STATE_DIR/endpoint" "$STATE_DIR/port" "$STATE_DIR/proto" "$STATE_DIR/egress-interface"

  cat > "$OVPN_CONF" <<EOF
port $port
proto $proto
dev tun0
topology subnet
server $VPN_NET $VPN_MASK
ca $CA_FILE
cert $SERVER_CERT
key $SERVER_KEY
crl-verify $CRL_FILE
tls-crypt $TLS_KEY
dh none
ecdh-curve prime256v1
tls-version-min 1.2
remote-cert-tls client
auth SHA256
data-ciphers CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM
data-ciphers-fallback AES-256-GCM
keepalive 10 120
persist-key
persist-tun
explicit-exit-notify 1
user nobody
group nogroup
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 9.9.9.9"
status /run/openvpn/manager-status.log
verb 3
EOF
  chmod 0644 "$OVPN_CONF"

  backup_file "$SYSCTL_FILE"
  cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward = 1
EOF
  chmod 0644 "$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null

  cat > "$OVERRIDE_FILE" <<EOF
[Service]
ExecStartPost=/bin/sh -c 'iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c 'iptables -C FORWARD -o tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c 'iptables -t nat -C POSTROUTING -s $VPN_NET/24 -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $VPN_NET/24 -o $iface -j MASQUERADE'
ExecStopPost=-/sbin/iptables -D FORWARD -i tun0 -j ACCEPT
ExecStopPost=-/sbin/iptables -D FORWARD -o tun0 -j ACCEPT
ExecStopPost=-/sbin/iptables -t nat -D POSTROUTING -s $VPN_NET/24 -o $iface -j MASQUERADE
EOF

  systemctl daemon-reload
  systemctl enable --now "$(service_name)"
  if ! systemctl is-active --quiet "$(service_name)"; then
    err "OpenVPN não iniciou. Veja os logs pelo módulo Logs ou journalctl."
    systemctl --no-pager --full status "$(service_name)" 2>/dev/null | sed -n '1,30p' || true
    pause
    return
  fi

  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port/$proto" comment 'MANAGER OpenVPN' >/dev/null
    info "UFW ativo: $port/$proto foi liberada."
  fi
  ok "OpenVPN ativo em $endpoint:$port/$proto"
  pause
}

add_client() {
  header
  [[ -f "$OVPN_CONF" && -x "$EASYRSA_DIR/easyrsa" ]] || { err "Instale o servidor OpenVPN primeiro"; pause; return; }
  local name endpoint port proto file
  read -r -p "Nome do cliente: " name
  is_valid_username "$name" || { err "Nome inválido"; pause; return; }
  file="$CLIENT_DIR/$name.ovpn"
  [[ ! -e "$file" ]] || { err "Cliente já existe"; pause; return; }

  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa build-client-full "$name" nopass
  )
  endpoint="$(cat "$STATE_DIR/endpoint")"
  port="$(cat "$STATE_DIR/port")"
  proto="$(cat "$STATE_DIR/proto")"

  cat > "$file" <<EOF
client
dev tun
proto $proto
remote $endpoint $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
data-ciphers CHACHA20-POLY1305:AES-256-GCM:AES-128-GCM
auth-nocache
verb 3
<ca>
$(cat "$CA_FILE")
</ca>
<cert>
$(extract_pem '-----BEGIN CERTIFICATE-----' '-----END CERTIFICATE-----' "$EASYRSA_DIR/pki/issued/$name.crt")
</cert>
<key>
$(cat "$EASYRSA_DIR/pki/private/$name.key")
</key>
<tls-crypt>
$(cat "$TLS_KEY")
</tls-crypt>
EOF
  chmod 0600 "$file"
  cat > "$META_DIR/$name.meta" <<EOF
name=$name
created=$(date -Is)
status=active
EOF
  chmod 0600 "$META_DIR/$name.meta"
  ok "Cliente criado: $file"
  say "Importe esse arquivo no aplicativo OpenVPN Connect ou cliente compatível."
  pause
}

list_clients() {
  header
  say "${C_WHITE}CLIENTES OPENVPN${C_RESET}\n"
  if ! compgen -G "$META_DIR/*.meta" >/dev/null 2>&1; then
    warn "Nenhum cliente criado pelo MANAGER"
  else
    local meta name created status
    printf '%-20s %-26s %-10s\n' "CLIENTE" "CRIADO" "ESTADO"
    for meta in "$META_DIR"/*.meta; do
      name="$(awk -F= '$1=="name"{print $2}' "$meta")"
      created="$(awk -F= '$1=="created"{sub(/^created=/,""); print}' "$meta")"
      status="$(awk -F= '$1=="status"{print $2}' "$meta")"
      printf '%-20s %-26s %-10s\n' "$name" "$created" "$status"
    done
  fi
  pause
}

show_client() {
  header
  local name file
  read -r -p "Cliente: " name
  file="$CLIENT_DIR/$name.ovpn"
  [[ -f "$file" ]] || { err "Cliente não encontrado"; pause; return; }
  warn "O perfil contém uma chave privada. Não o publique."
  say "Arquivo: $file"
  pause
}

revoke_client() {
  header
  local name meta
  read -r -p "Cliente para revogar: " name
  meta="$META_DIR/$name.meta"
  [[ -f "$meta" ]] || { err "Cliente não encontrado"; pause; return; }
  if grep -q '^status=revoked$' "$meta"; then
    warn "Cliente já revogado"
    pause
    return
  fi
  confirm "Revogar permanentemente o certificado de $name?" || return
  (
    cd "$EASYRSA_DIR"
    EASYRSA_BATCH=1 ./easyrsa revoke "$name"
    EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
  )
  install -m 0644 "$EASYRSA_DIR/pki/crl.pem" "$CRL_FILE"
  sed -i 's/^status=.*/status=revoked/' "$meta"
  rm -f "$CLIENT_DIR/$name.ovpn"
  systemctl reload "$(service_name)" 2>/dev/null || systemctl restart "$(service_name)"
  ok "Cliente revogado"
  pause
}

use_adblock_dns() {
  header
  [[ -f "$OVPN_CONF" ]] || { err "OpenVPN não instalado pelo MANAGER"; pause; return; }
  if ! grep -q "^listen-address=$VPN_SERVER_IP$" /etc/dnsmasq.d/90-manager-adblock.conf 2>/dev/null; then
    err "Configure primeiro o Ad Block para escutar em $VPN_SERVER_IP."
    info "Com tun0 ativo, abra o módulo DNS Ad Block e escolha $VPN_SERVER_IP como endereço."
    pause
    return
  fi
  backup_file "$OVPN_CONF"
  sed -i '/^push "dhcp-option DNS /d' "$OVPN_CONF"
  printf 'push "dhcp-option DNS %s"\n' "$VPN_SERVER_IP" >> "$OVPN_CONF"
  systemctl restart "$(service_name)"
  ok "Clientes OpenVPN passarão a usar o DNS adblock $VPN_SERVER_IP"
  pause
}

status_server() {
  header
  say "${C_WHITE}STATUS OPENVPN${C_RESET}\n"
  systemctl --no-pager --full status "$(service_name)" 2>/dev/null | sed -n '1,18p' || true
  say "\nInterfaces:"
  ip -br addr show tun0 2>/dev/null || true
  say "\nStatus OpenVPN:"
  sed -n '1,80p' /run/openvpn/manager-status.log 2>/dev/null || true
  pause
}

while true; do
  header
  say "${C_WHITE}OPENVPN${C_RESET}\n"
  say " 1) Instalar servidor"
  say " 2) Criar cliente .ovpn"
  say " 3) Listar clientes"
  say " 4) Localizar perfil de cliente"
  say " 5) Revogar cliente"
  say " 6) Usar DNS Ad Block na VPN"
  say " 7) Status"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) install_server ;;
    2) add_client ;;
    3) list_clients ;;
    4) show_client ;;
    5) revoke_client ;;
    6) use_adblock_dns ;;
    7) status_server ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
