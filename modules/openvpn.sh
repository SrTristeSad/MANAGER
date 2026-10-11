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
VPN_NET6="fd66:8::/64"

service_name() { printf 'openvpn-server@%s' "$OVPN_NAME"; }

state_value() {
  local key="$1"
  [[ -f "$STATE_DIR/$key" ]] && tr -d '[:space:]' < "$STATE_DIR/$key" || true
}

ipv6_enabled() { [[ "$(state_value ipv6-enabled)" == 1 ]]; }

write_ipv6_state() {
  local enabled="$1" iface6="${2:-}"
  install -d -m 0700 "$STATE_DIR"
  printf '%s\n' "$enabled" > "$STATE_DIR/ipv6-enabled"
  printf '%s\n' "$iface6" > "$STATE_DIR/egress6-interface"
  chmod 0600 "$STATE_DIR/ipv6-enabled" "$STATE_DIR/egress6-interface"
}

extract_pem() {
  local begin="$1" end="$2" file="$3"
  awk -v b="$begin" -v e="$end" '$0 ~ b {p=1} p {print} $0 ~ e {exit}' "$file"
}

port_busy() {
  local port="$1" transport="$2"
  if [[ "$transport" == udp ]]; then
    ss -Hlun "sport = :$port" 2>/dev/null | grep -q .
  else
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q .
  fi
}

write_network_override() {
  local iface4="$1" iface6="${2:-}" ipv6="${3:-0}"
  install -d -m 0755 "$OVERRIDE_DIR"
  cat > "$OVERRIDE_FILE" <<EOF
[Service]
ExecStartPost=/bin/sh -c '/usr/sbin/iptables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD 1 -i tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c '/usr/sbin/iptables -C FORWARD -o tun0 -j ACCEPT 2>/dev/null || /usr/sbin/iptables -I FORWARD 1 -o tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c '/usr/sbin/iptables -t nat -C POSTROUTING -s $VPN_NET/24 -o $iface4 -j MASQUERADE 2>/dev/null || /usr/sbin/iptables -t nat -A POSTROUTING -s $VPN_NET/24 -o $iface4 -j MASQUERADE'
ExecStopPost=-/usr/sbin/iptables -D FORWARD -i tun0 -j ACCEPT
ExecStopPost=-/usr/sbin/iptables -D FORWARD -o tun0 -j ACCEPT
ExecStopPost=-/usr/sbin/iptables -t nat -D POSTROUTING -s $VPN_NET/24 -o $iface4 -j MASQUERADE
EOF
  if [[ "$ipv6" == 1 ]]; then
    cat >> "$OVERRIDE_FILE" <<EOF
ExecStartPost=/bin/sh -c '/usr/sbin/ip6tables -C FORWARD -i tun0 -j ACCEPT 2>/dev/null || /usr/sbin/ip6tables -I FORWARD 1 -i tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c '/usr/sbin/ip6tables -C FORWARD -o tun0 -j ACCEPT 2>/dev/null || /usr/sbin/ip6tables -I FORWARD 1 -o tun0 -j ACCEPT'
ExecStartPost=/bin/sh -c '/usr/sbin/ip6tables -t nat -C POSTROUTING -s $VPN_NET6 -o $iface6 -j MASQUERADE 2>/dev/null || /usr/sbin/ip6tables -t nat -A POSTROUTING -s $VPN_NET6 -o $iface6 -j MASQUERADE'
ExecStopPost=-/usr/sbin/ip6tables -D FORWARD -i tun0 -j ACCEPT
ExecStopPost=-/usr/sbin/ip6tables -D FORWARD -o tun0 -j ACCEPT
ExecStopPost=-/usr/sbin/ip6tables -t nat -D POSTROUTING -s $VPN_NET6 -o $iface6 -j MASQUERADE
EOF
  fi
}

install_server() {
  header
  say "${C_WHITE}INSTALAR OPENVPN${C_RESET}\n"
  if [[ -f "$OVPN_CONF" ]]; then
    warn "$OVPN_CONF já existe. O MANAGER não irá sobrescrever o servidor existente."
    info "Use a opção de reconciliar IPv6 para atualizar uma instalação MANAGER existente."
    pause
    return
  fi

  local port transport server_proto iface iface6 endpoint endpoint_in ipv6=0
  read -r -p "Porta [1194]: " port
  port="${port:-1194}"
  is_valid_port "$port" || { err "Porta inválida"; pause; return; }
  read -r -p "Transporte [udp/tcp] (udp): " transport
  transport="${transport:-udp}"
  [[ "$transport" == udp || "$transport" == tcp ]] || { err "Protocolo inválido"; pause; return; }
  if port_busy "$port" "$transport"; then
    err "A porta $port/$transport já está em uso."
    pause
    return
  fi
  if [[ "$transport" == tcp ]]; then server_proto="tcp-server"; else server_proto="udp"; fi

  iface="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  [[ -n "$iface" ]] || { err "Não encontrei a interface de saída IPv4 padrão"; pause; return; }
  if ipv6_egress_available; then
    iface6="$(ipv6_default_interface)"
    ipv6=1
  else
    iface6=""
  fi
  endpoint="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  read -r -p "IP/domínio público do servidor [$endpoint]: " endpoint_in
  endpoint="${endpoint_in:-$endpoint}"
  [[ -n "$endpoint" ]] || { err "Informe um endpoint público"; pause; return; }

  say "\nRede VPN IPv4: $VPN_NET/24"
  if (( ipv6 == 1 )); then say "Rede VPN IPv6: $VPN_NET6 (saída por $iface6)"; else say "IPv6: indisponível nesta VPS; túnel será IPv4-only."; fi
  say "Serviço: $(service_name)"
  say "PKI: Easy-RSA local, sem depender de CA externa."
  confirm "Instalar OpenVPN em $endpoint:$port/$transport?" || return

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
  chmod 0644 "$SERVER_CERT"
  install -m 0600 "$EASYRSA_DIR/pki/private/server.key" "$SERVER_KEY"
  install -m 0644 "$EASYRSA_DIR/pki/crl.pem" "$CRL_FILE"
  openvpn --genkey secret "$TLS_KEY"
  chmod 0600 "$TLS_KEY" "$SERVER_KEY"
  chmod 0644 "$CA_FILE" "$SERVER_CERT" "$CRL_FILE"

  printf '%s\n' "$endpoint" > "$STATE_DIR/endpoint"
  printf '%s\n' "$port" > "$STATE_DIR/port"
  printf '%s\n' "$transport" > "$STATE_DIR/transport"
  printf '%s\n' "$iface" > "$STATE_DIR/egress-interface"
  chmod 0600 "$STATE_DIR/endpoint" "$STATE_DIR/port" "$STATE_DIR/transport" "$STATE_DIR/egress-interface"
  write_ipv6_state "$ipv6" "$iface6"

  cat > "$OVPN_CONF" <<EOF
port $port
proto $server_proto
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
user nobody
group nogroup
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 9.9.9.9"
status /run/openvpn/manager-status.log
verb 3
EOF
  if (( ipv6 == 1 )); then
    {
      printf 'server-ipv6 %s\n' "$VPN_NET6"
      printf 'push "redirect-gateway ipv6"\n'
    } >> "$OVPN_CONF"
  fi
  chmod 0644 "$OVPN_CONF"

  backup_file "$SYSCTL_FILE"
  {
    printf 'net.ipv4.ip_forward = 1\n'
    (( ipv6 == 0 )) || printf 'net.ipv6.conf.all.forwarding = 1\n'
  } > "$SYSCTL_FILE"
  chmod 0644 "$SYSCTL_FILE"
  enable_ipv4_forwarding
  (( ipv6 == 0 )) || enable_ipv6_forwarding

  write_network_override "$iface" "$iface6" "$ipv6"
  systemctl daemon-reload
  systemctl enable --now "$(service_name)"
  if ! systemctl is-active --quiet "$(service_name)"; then
    err "OpenVPN não iniciou. Veja os logs pelo módulo Logs ou journalctl."
    systemctl --no-pager --full status "$(service_name)" 2>/dev/null | sed -n '1,30p' || true
    pause
    return
  fi

  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port/$transport" comment 'MANAGER OpenVPN' >/dev/null
    info "UFW ativo: $port/$transport foi liberada."
  fi
  ok "OpenVPN ativo em $endpoint:$port/$transport"
  pause
}

add_client() {
  header
  [[ -f "$OVPN_CONF" && -x "$EASYRSA_DIR/easyrsa" ]] || { err "Instale o servidor OpenVPN primeiro"; pause; return; }
  local name endpoint port transport client_proto file
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
  transport="$(cat "$STATE_DIR/transport")"
  if [[ "$transport" == tcp ]]; then client_proto="tcp-client"; else client_proto="udp"; fi

  cat > "$file" <<EOF
client
dev tun
proto $client_proto
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
ipv6=$(ipv6_enabled && echo 1 || echo 0)
EOF
  chmod 0600 "$META_DIR/$name.meta"
  ok "Cliente criado: $file"
  ipv6_enabled && info "O servidor entregará também um endereço IPv6 de $VPN_NET6."
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

enable_ipv6_existing() {
  header
  say "${C_WHITE}OPENVPN DUAL-STACK IPV6${C_RESET}\n"
  [[ -f "$OVPN_CONF" && -f "$STATE_DIR/egress-interface" ]] || { err "Servidor OpenVPN do MANAGER não encontrado"; pause; return; }
  if ipv6_enabled; then ok "IPv6 já está habilitado para o OpenVPN do MANAGER."; pause; return; fi
  ipv6_egress_available || { err "A VPS não possui rota IPv6 padrão com endereço global utilizável."; pause; return; }
  command_exists ip6tables || { err "ip6tables não está disponível"; pause; return; }

  local iface4 iface6 conf_backup override_backup sysctl_backup="" had_override=0
  iface4="$(state_value egress-interface)"
  iface6="$(ipv6_default_interface)"
  [[ -n "$iface4" && -n "$iface6" ]] || { err "Interfaces de saída incompletas"; pause; return; }
  confirm "Ativar $VPN_NET6 e reiniciar OpenVPN? Clientes conectados serão reconectados." || return

  conf_backup="$(mktemp)"
  override_backup="$(mktemp)"
  cp -a "$OVPN_CONF" "$conf_backup"
  if [[ -f "$OVERRIDE_FILE" ]]; then cp -a "$OVERRIDE_FILE" "$override_backup"; had_override=1; fi
  if [[ -f "$SYSCTL_FILE" ]]; then sysctl_backup="$(mktemp)"; cp -a "$SYSCTL_FILE" "$sysctl_backup"; fi

  grep -q '^server-ipv6 ' "$OVPN_CONF" || printf 'server-ipv6 %s\n' "$VPN_NET6" >> "$OVPN_CONF"
  grep -Fqx 'push "redirect-gateway ipv6"' "$OVPN_CONF" || printf 'push "redirect-gateway ipv6"\n' >> "$OVPN_CONF"
  if ! grep -q '^net.ipv6.conf.all.forwarding' "$SYSCTL_FILE" 2>/dev/null; then printf 'net.ipv6.conf.all.forwarding = 1\n' >> "$SYSCTL_FILE"; fi
  chmod 0644 "$SYSCTL_FILE"
  enable_ipv6_forwarding
  write_network_override "$iface4" "$iface6" 1
  systemctl daemon-reload
  write_ipv6_state 1 "$iface6"

  if ! systemctl restart "$(service_name)" || ! systemctl is-active --quiet "$(service_name)"; then
    install -m 0644 "$conf_backup" "$OVPN_CONF"
    if (( had_override == 1 )); then install -m 0644 "$override_backup" "$OVERRIDE_FILE"; else rm -f "$OVERRIDE_FILE"; fi
    if [[ -n "$sysctl_backup" ]]; then install -m 0644 "$sysctl_backup" "$SYSCTL_FILE"; fi
    write_ipv6_state 0 ""
    systemctl daemon-reload
    systemctl restart "$(service_name)" >/dev/null 2>&1 || true
    rm -f "$conf_backup" "$override_backup" ${sysctl_backup:+"$sysctl_backup"}
    err "OpenVPN rejeitou a atualização IPv6; configuração anterior restaurada."
    pause
    return
  fi
  rm -f "$conf_backup" "$override_backup" ${sysctl_backup:+"$sysctl_backup"}
  ok "OpenVPN atualizado para dual-stack em $VPN_NET6."
  pause
}

status_server() {
  header
  say "${C_WHITE}STATUS OPENVPN${C_RESET}\n"
  printf 'IPv6 VPN: %s\n' "$(ipv6_enabled && printf 'ativo (%s)' "$VPN_NET6" || printf 'desativado')"
  if ipv6_enabled; then printf 'Saída IPv6: %s\n' "$(state_value egress6-interface)"; fi
  systemctl --no-pager --full status "$(service_name)" 2>/dev/null | sed -n '1,18p' || true
  say "\nInterfaces:"
  ip -br addr show tun0 2>/dev/null || true
  say "\nStatus OpenVPN:"
  sed -n '1,80p' /run/openvpn/manager-status.log 2>/dev/null || true
  pause
}

machine_state() {
  printf 'ipv6_enabled=%s\n' "$(ipv6_enabled && echo 1 || echo 0)"
  printf 'ipv6_prefix=%s\n' "$VPN_NET6"
  printf 'ipv6_egress_interface=%s\n' "$(state_value egress6-interface)"
}

case "${1:-}" in
  --network-state) machine_state; exit 0 ;;
  *) ;;
esac

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
  say " 8) Ativar/reconciliar IPv6 dual-stack"
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
    8) enable_ipv6_existing ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
