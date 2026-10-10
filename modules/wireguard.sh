#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

WG_DIR="/etc/wireguard"
STATE_DIR="$MANAGER_ETC/wireguard"
CLIENT_DIR="$STATE_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
WG_NET="10.66.66"
WG_SERVER_IP="$WG_NET.1"

install_server() {
  header
  say "${C_WHITE}INSTALAR WIREGUARD${C_RESET}\n"
  if [[ -f "$WG_CONF" ]]; then
    warn "$WG_CONF já existe. O MANAGER não irá sobrescrever uma VPN existente."
    pause
    return
  fi

  local port iface endpoint endpoint_in private public
  iface="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  [[ -n "$iface" ]] || { err "Não encontrei a interface de saída padrão"; pause; return; }
  read -r -p "Porta UDP [51820]: " port
  port="${port:-51820}"
  if ! is_valid_port "$port"; then
    err "Porta inválida"
    pause
    return
  fi
  if ss -Hlun "sport = :$port" 2>/dev/null | grep -q .; then
    err "A porta UDP $port já está em uso."
    pause
    return
  fi
  endpoint="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  read -r -p "IP/domínio público do servidor [$endpoint]: " endpoint_in
  endpoint="${endpoint_in:-$endpoint}"
  [[ -n "$endpoint" ]] || { err "Informe um endpoint público"; pause; return; }

  confirm "Instalar WireGuard em $WG_SERVER_IP/24, UDP $port?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y wireguard wireguard-tools qrencode iptables
  install -d -m 0700 "$WG_DIR" "$STATE_DIR" "$CLIENT_DIR"

  private="$(wg genkey)"
  public="$(printf '%s' "$private" | wg pubkey)"
  printf '%s\n' "$private" > "$WG_DIR/server.key"
  printf '%s\n' "$public" > "$WG_DIR/server.pub"
  chmod 0600 "$WG_DIR/server.key" "$WG_DIR/server.pub"
  printf '%s\n' "$endpoint" > "$STATE_DIR/endpoint"
  printf '%s\n' "$port" > "$STATE_DIR/port"
  chmod 0600 "$STATE_DIR/endpoint" "$STATE_DIR/port"

  cat > "$WG_CONF" <<EOF
[Interface]
Address = $WG_SERVER_IP/24
ListenPort = $port
PrivateKey = $private
SaveConfig = false
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE 2>/dev/null || true
EOF
  chmod 0600 "$WG_CONF"

  backup_file /etc/sysctl.d/99-manager-wireguard.conf
  cat > /etc/sysctl.d/99-manager-wireguard.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  chmod 0644 /etc/sysctl.d/99-manager-wireguard.conf
  enable_ipv4_forwarding
  systemctl enable --now wg-quick@wg0

  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port/udp" comment 'MANAGER WireGuard' >/dev/null
    info "UFW ativo: UDP $port foi liberada."
  fi
  ok "WireGuard ativo. Verifique também o firewall do seu provedor/cloud, se houver."
  pause
}

next_client_octet() {
  local n
  for n in $(seq 2 254); do
    if ! grep -Rqs "Address = $WG_NET.$n/32" "$CLIENT_DIR" 2>/dev/null; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

add_client() {
  header
  [[ -f "$WG_CONF" ]] || { err "Instale o servidor WireGuard primeiro"; pause; return; }
  local name octet ip priv pub psk server_pub endpoint port dns file
  read -r -p "Nome do cliente: " name
  is_valid_username "$name" || { err "Nome inválido"; pause; return; }
  file="$CLIENT_DIR/$name.conf"
  [[ ! -e "$file" ]] || { err "Cliente já existe"; pause; return; }
  octet="$(next_client_octet)" || { err "Faixa de clientes esgotada"; pause; return; }
  ip="$WG_NET.$octet"
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  psk="$(wg genpsk)"
  server_pub="$(cat "$WG_DIR/server.pub")"
  endpoint="$(cat "$STATE_DIR/endpoint")"
  port="$(cat "$STATE_DIR/port")"
  dns="1.1.1.1"
  if grep -q "^listen-address=$WG_SERVER_IP$" /etc/dnsmasq.d/90-manager-adblock.conf 2>/dev/null; then
    dns="$WG_SERVER_IP"
  fi

  cat > "$file" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $dns

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint:$port
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  chmod 0600 "$file"
  cat > "$CLIENT_DIR/$name.meta" <<EOF
name=$name
ip=$ip
public_key=$pub
EOF
  chmod 0600 "$CLIENT_DIR/$name.meta"

  cat >> "$WG_CONF" <<EOF

# MANAGER-PEER-BEGIN $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $ip/32
# MANAGER-PEER-END $name
EOF
  chmod 0600 "$WG_CONF"
  systemctl reload wg-quick@wg0 2>/dev/null || systemctl restart wg-quick@wg0
  ok "Cliente $name criado em $file"
  say "\n${C_WHITE}QR CODE:${C_RESET}"
  qrencode -t ANSIUTF8 < "$file" || true
  pause
}

list_clients() {
  header
  say "${C_WHITE}CLIENTES WIREGUARD${C_RESET}\n"
  if ! compgen -G "$CLIENT_DIR/*.meta" >/dev/null 2>&1; then
    warn "Nenhum cliente criado pelo MANAGER"
  else
    local meta name ip pub handshake
    printf '%-18s %-16s %-22s\n' "CLIENTE" "IP" "ÚLTIMO HANDSHAKE"
    for meta in "$CLIENT_DIR"/*.meta; do
      name="$(awk -F= '$1=="name"{print $2}' "$meta")"
      ip="$(awk -F= '$1=="ip"{print $2}' "$meta")"
      pub="$(awk -F= '$1=="public_key"{print $2}' "$meta")"
      handshake="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p {if ($2==0) print "nunca"; else {cmd="date -d @"$2" +%Y-%m-%d_%H:%M"; cmd | getline d; close(cmd); print d}}')"
      printf '%-18s %-16s %-22s\n' "$name" "$ip" "${handshake:-nunca}"
    done
  fi
  pause
}

show_client() {
  header
  local name file
  read -r -p "Cliente: " name
  file="$CLIENT_DIR/$name.conf"
  [[ -f "$file" ]] || { err "Cliente não encontrado"; pause; return; }
  say "${C_WHITE}CONFIGURAÇÃO: $file${C_RESET}\n"
  cat "$file"
  say "\n${C_WHITE}QR CODE:${C_RESET}"
  if command_exists qrencode; then
    qrencode -t ANSIUTF8 < "$file" || true
  fi
  pause
}

remove_client() {
  header
  local name meta pub tmp
  read -r -p "Cliente para remover: " name
  meta="$CLIENT_DIR/$name.meta"
  [[ -f "$meta" ]] || { err "Cliente não encontrado"; pause; return; }
  confirm "Revogar $name?" || return
  pub="$(awk -F= '$1=="public_key"{print $2}' "$meta")"
  wg set wg0 peer "$pub" remove 2>/dev/null || true
  tmp="$(mktemp)"
  awk -v n="$name" '
    $0 == "# MANAGER-PEER-BEGIN " n {skip=1; next}
    $0 == "# MANAGER-PEER-END " n {skip=0; next}
    !skip {print}
  ' "$WG_CONF" > "$tmp"
  install -m 0600 "$tmp" "$WG_CONF"
  rm -f "$tmp" "$CLIENT_DIR/$name.conf" "$meta"
  systemctl reload wg-quick@wg0 2>/dev/null || true
  ok "Cliente revogado"
  pause
}

status_wg() {
  header
  say "${C_WHITE}STATUS WIREGUARD${C_RESET}\n"
  systemctl --no-pager --full status wg-quick@wg0 2>/dev/null | sed -n '1,12p' || true
  say ""
  wg show 2>/dev/null || true
  pause
}

while true; do
  header
  say "${C_WHITE}WIREGUARD${C_RESET}\n"
  say " 1) Instalar servidor"
  say " 2) Criar cliente + QR Code"
  say " 3) Listar clientes"
  say " 4) Mostrar configuração/QR"
  say " 5) Revogar cliente"
  say " 6) Status"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) install_server ;;
    2) add_client ;;
    3) list_clients ;;
    4) show_client ;;
    5) remove_client ;;
    6) status_wg ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
