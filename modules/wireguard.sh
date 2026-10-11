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
WG_NET6="fd66:66:66::"
WG_SERVER_IP6="fd66:66:66::1"

state_value() {
  local key="$1"
  if [[ -f "$STATE_DIR/$key" ]]; then
    tr -d '[:space:]' < "$STATE_DIR/$key"
  fi
}

ipv6_enabled() { [[ "$(state_value ipv6-enabled)" == 1 ]]; }

write_ipv6_state() {
  local enabled="$1" iface6="${2:-}"
  install -d -m 0700 "$STATE_DIR"
  printf '%s\n' "$enabled" > "$STATE_DIR/ipv6-enabled"
  printf '%s\n' "$iface6" > "$STATE_DIR/egress6-interface"
  chmod 0600 "$STATE_DIR/ipv6-enabled" "$STATE_DIR/egress6-interface"
}

wg_endpoint() {
  local host="$1" port="$2"
  format_host_port "$host" "$port"
}

install_server() {
  header
  say "${C_WHITE}INSTALAR WIREGUARD${C_RESET}\n"
  if [[ -f "$WG_CONF" ]]; then
    warn "$WG_CONF já existe. O MANAGER não irá sobrescrever uma VPN existente."
    info "Use a opção de reconciliar IPv6 para atualizar uma instalação MANAGER existente."
    pause
    return
  fi

  local port iface iface6 endpoint endpoint_in private public ipv6=0 post_up post_down address
  iface="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  [[ -n "$iface" ]] || { err "Não encontrei a interface de saída IPv4 padrão"; pause; return; }
  if ipv6_egress_available; then
    iface6="$(ipv6_default_interface)"
    ipv6=1
  else
    iface6=""
  fi

  read -r -p "Porta UDP [51820]: " port
  port="${port:-51820}"
  if ! is_valid_port "$port"; then err "Porta inválida"; pause; return; fi
  if ss -Hlun "sport = :$port" 2>/dev/null | grep -q .; then err "A porta UDP $port já está em uso."; pause; return; fi
  endpoint="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
  read -r -p "IP/domínio público do servidor [$endpoint]: " endpoint_in
  endpoint="${endpoint_in:-$endpoint}"
  [[ -n "$endpoint" ]] || { err "Informe um endpoint público"; pause; return; }

  if (( ipv6 == 1 )); then
    say "IPv6: dual-stack detectado em $iface6; clientes receberão IPv4 + IPv6."
    address="$WG_SERVER_IP/24, $WG_SERVER_IP6/64"
  else
    say "IPv6: sem rota/endereço global utilizável; esta VPN será IPv4-only."
    address="$WG_SERVER_IP/24"
  fi
  confirm "Instalar WireGuard em $address, UDP $port?" || return

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
  write_ipv6_state "$ipv6" "$iface6"

  post_up="iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE"
  post_down="iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s $WG_NET.0/24 -o $iface -j MASQUERADE 2>/dev/null || true"
  if (( ipv6 == 1 )); then
    post_up+="; ip6tables -C FORWARD -i %i -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i %i -j ACCEPT; ip6tables -C FORWARD -o %i -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -o %i -j ACCEPT; ip6tables -t nat -C POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE"
    post_down+="; ip6tables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; ip6tables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; ip6tables -t nat -D POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE 2>/dev/null || true"
  fi

  cat > "$WG_CONF" <<EOF
[Interface]
Address = $address
ListenPort = $port
PrivateKey = $private
SaveConfig = false
PostUp = $post_up
PostDown = $post_down
EOF
  chmod 0600 "$WG_CONF"

  backup_file /etc/sysctl.d/99-manager-wireguard.conf
  {
    printf 'net.ipv4.ip_forward = 1\n'
    (( ipv6 == 0 )) || printf 'net.ipv6.conf.all.forwarding = 1\n'
  } > /etc/sysctl.d/99-manager-wireguard.conf
  chmod 0644 /etc/sysctl.d/99-manager-wireguard.conf
  enable_ipv4_forwarding
  (( ipv6 == 0 )) || enable_ipv6_forwarding
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
    if ! grep -Rqs "Address = $WG_NET.$n/32" "$CLIENT_DIR" 2>/dev/null && ! grep -Rqs "Address = $WG_NET.$n/32," "$CLIENT_DIR" 2>/dev/null; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

write_client_meta() {
  local name="$1" ip4="$2" ip6="$3" pub="$4"
  cat > "$CLIENT_DIR/$name.meta" <<EOF
name=$name
ip=$ip4
ip4=$ip4
ip6=$ip6
public_key=$pub
EOF
  chmod 0600 "$CLIENT_DIR/$name.meta"
}

add_client() {
  header
  [[ -f "$WG_CONF" ]] || { err "Instale o servidor WireGuard primeiro"; pause; return; }
  local name octet ip4 ip6="" address allowed priv pub psk server_pub endpoint port endpoint_port dns file
  read -r -p "Nome do cliente: " name
  is_valid_username "$name" || { err "Nome inválido"; pause; return; }
  file="$CLIENT_DIR/$name.conf"
  [[ ! -e "$file" ]] || { err "Cliente já existe"; pause; return; }
  octet="$(next_client_octet)" || { err "Faixa de clientes esgotada"; pause; return; }
  ip4="$WG_NET.$octet"
  address="$ip4/32"
  allowed="0.0.0.0/0"
  if ipv6_enabled; then ip6="$WG_NET6$octet"; address+=", $ip6/128"; allowed+=", ::/0"; fi
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  psk="$(wg genpsk)"
  server_pub="$(cat "$WG_DIR/server.pub")"
  endpoint="$(cat "$STATE_DIR/endpoint")"
  port="$(cat "$STATE_DIR/port")"
  endpoint_port="$(wg_endpoint "$endpoint" "$port")"
  dns="1.1.1.1"
  if grep -q "^listen-address=$WG_SERVER_IP$" /etc/dnsmasq.d/90-manager-adblock.conf 2>/dev/null; then dns="$WG_SERVER_IP"; fi

  cat > "$file" <<EOF
[Interface]
PrivateKey = $priv
Address = $address
DNS = $dns

[Peer]
PublicKey = $server_pub
PresharedKey = $psk
Endpoint = $endpoint_port
AllowedIPs = $allowed
PersistentKeepalive = 25
EOF
  chmod 0600 "$file"
  write_client_meta "$name" "$ip4" "$ip6" "$pub"
  cat >> "$WG_CONF" <<EOF

# MANAGER-PEER-BEGIN $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $address
# MANAGER-PEER-END $name
EOF
  chmod 0600 "$WG_CONF"
  systemctl reload wg-quick@wg0 2>/dev/null || systemctl restart wg-quick@wg0
  ok "Cliente $name criado em $file"
  [[ -z "$ip6" ]] || info "Dual-stack: $ip4 + $ip6"
  say "\n${C_WHITE}QR CODE:${C_RESET}"
  qrencode -t ANSIUTF8 < "$file" || true
  pause
}

upgrade_existing_clients_ipv6() {
  local meta name ip4 ip6 pub octet conf tmp
  for meta in "$CLIENT_DIR"/*.meta; do
    [[ -f "$meta" ]] || continue
    name="$(awk -F= '$1=="name"{print $2; exit}' "$meta")"
    ip4="$(awk -F= '$1=="ip4"{print $2; exit}' "$meta")"
    [[ -n "$ip4" ]] || ip4="$(awk -F= '$1=="ip"{print $2; exit}' "$meta")"
    pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta")"
    [[ "$ip4" == "$WG_NET."* ]] || continue
    octet="${ip4##*.}"
    [[ "$octet" =~ ^[0-9]+$ ]] || continue
    ip6="$WG_NET6$octet"
    conf="$CLIENT_DIR/$name.conf"
    if [[ -f "$conf" ]]; then
      sed -i -E "s#^Address = ${ip4//./\.}/32(, .*)?$#Address = $ip4/32, $ip6/128#" "$conf"
      sed -i -E 's#^AllowedIPs = 0\.0\.0\.0/0$#AllowedIPs = 0.0.0.0/0, ::/0#' "$conf"
    fi
    write_client_meta "$name" "$ip4" "$ip6" "$pub"
    if [[ -f "$WG_CONF" ]]; then
      tmp="$(mktemp)"
      awk -v begin="# MANAGER-PEER-BEGIN $name" -v end="# MANAGER-PEER-END $name" -v v4="$ip4/32" -v v6="$ip6/128" '
        $0==begin {inside=1}
        inside && $0=="AllowedIPs = " v4 {$0="AllowedIPs = " v4 ", " v6}
        {print}
        $0==end {inside=0}
      ' "$WG_CONF" > "$tmp"
      install -m 0600 "$tmp" "$WG_CONF"
      rm -f "$tmp"
    fi
  done
}

enable_ipv6_existing() {
  header
  say "${C_WHITE}WIREGUARD DUAL-STACK IPV6${C_RESET}\n"
  [[ -f "$WG_CONF" && -d "$STATE_DIR" ]] || { err "Servidor WireGuard do MANAGER não encontrado"; pause; return; }
  if ipv6_enabled; then ok "IPv6 já está habilitado para o WireGuard do MANAGER."; pause; return; fi
  ipv6_egress_available || { err "A VPS não possui rota IPv6 padrão com endereço global utilizável."; pause; return; }
  command_exists ip6tables || { err "ip6tables não está disponível"; pause; return; }
  local iface6 backup
  iface6="$(ipv6_default_interface)"
  confirm "Ativar IPv6 nos clientes atuais e futuros usando $WG_NET6/64 via $iface6?" || return
  backup="$(mktemp)"
  cp -a "$WG_CONF" "$backup"

  sed -i -E "s#^Address = $WG_SERVER_IP/24$#Address = $WG_SERVER_IP/24, $WG_SERVER_IP6/64#" "$WG_CONF"
  sed -i "/^PostUp = / s#\$#; ip6tables -C FORWARD -i %i -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i %i -j ACCEPT; ip6tables -C FORWARD -o %i -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -o %i -j ACCEPT; ip6tables -t nat -C POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE#" "$WG_CONF"
  sed -i "/^PostDown = / s#\$#; ip6tables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; ip6tables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; ip6tables -t nat -D POSTROUTING -s $WG_NET6/64 -o $iface6 -j MASQUERADE 2>/dev/null || true#" "$WG_CONF"
  upgrade_existing_clients_ipv6

  backup_file /etc/sysctl.d/99-manager-wireguard.conf
  if ! grep -q '^net.ipv6.conf.all.forwarding' /etc/sysctl.d/99-manager-wireguard.conf 2>/dev/null; then printf 'net.ipv6.conf.all.forwarding = 1\n' >> /etc/sysctl.d/99-manager-wireguard.conf; fi
  enable_ipv6_forwarding
  write_ipv6_state 1 "$iface6"
  if ! systemctl restart wg-quick@wg0; then
    install -m 0600 "$backup" "$WG_CONF"
    write_ipv6_state 0 ""
    rm -f "$backup"
    err "WireGuard não reiniciou com IPv6; configuração do servidor foi restaurada."
    pause
    return
  fi
  rm -f "$backup"
  ok "WireGuard atualizado para dual-stack. Perfis existentes receberam endereço IPv6 correspondente."
  pause
}

list_clients() {
  header
  say "${C_WHITE}CLIENTES WIREGUARD${C_RESET}\n"
  if ! compgen -G "$CLIENT_DIR/*.meta" >/dev/null 2>&1; then
    warn "Nenhum cliente criado pelo MANAGER"
  else
    local meta name ip4 ip6 pub handshake
    printf '%-18s %-16s %-24s %-22s\n' "CLIENTE" "IPv4" "IPv6" "ÚLTIMO HANDSHAKE"
    for meta in "$CLIENT_DIR"/*.meta; do
      name="$(awk -F= '$1=="name"{print $2}' "$meta")"
      ip4="$(awk -F= '$1=="ip4"{print $2}' "$meta")"; [[ -n "$ip4" ]] || ip4="$(awk -F= '$1=="ip"{print $2}' "$meta")"
      ip6="$(awk -F= '$1=="ip6"{print $2}' "$meta")"
      pub="$(awk -F= '$1=="public_key"{print $2}' "$meta")"
      handshake="$(wg show wg0 latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p {if ($2==0) print "nunca"; else {cmd="date -d @"$2" +%Y-%m-%d_%H:%M"; cmd | getline d; close(cmd); print d}}')"
      printf '%-18s %-16s %-24s %-22s\n' "$name" "${ip4:--}" "${ip6:--}" "${handshake:-nunca}"
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
  if command_exists qrencode; then qrencode -t ANSIUTF8 < "$file" || true; fi
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
  awk -v n="$name" '$0 == "# MANAGER-PEER-BEGIN " n {skip=1; next} $0 == "# MANAGER-PEER-END " n {skip=0; next} !skip {print}' "$WG_CONF" > "$tmp"
  install -m 0600 "$tmp" "$WG_CONF"
  rm -f "$tmp" "$CLIENT_DIR/$name.conf" "$meta"
  systemctl reload wg-quick@wg0 2>/dev/null || true
  ok "Cliente revogado"
  pause
}

status_wg() {
  header
  say "${C_WHITE}STATUS WIREGUARD${C_RESET}\n"
  printf 'IPv6 VPN: %s\n' "$(ipv6_enabled && printf 'ativo (%s/64)' "$WG_NET6" || printf 'desativado')"
  if ipv6_enabled; then printf 'Saída IPv6: %s\n' "$(state_value egress6-interface)"; fi
  systemctl --no-pager --full status wg-quick@wg0 2>/dev/null | sed -n '1,12p' || true
  say ""
  wg show 2>/dev/null || true
  pause
}

machine_state() {
  printf 'ipv6_enabled=%s\n' "$(ipv6_enabled && echo 1 || echo 0)"
  printf 'ipv6_prefix=%s/64\n' "$WG_NET6"
  printf 'ipv6_egress_interface=%s\n' "$(state_value egress6-interface)"
}

case "${1:-}" in
  --network-state) machine_state; exit 0 ;;
  *) ;;
esac

while true; do
  header
  say "${C_WHITE}WIREGUARD${C_RESET}\n"
  say " 1) Instalar servidor"
  say " 2) Criar cliente + QR Code"
  say " 3) Listar clientes"
  say " 4) Mostrar configuração/QR"
  say " 5) Revogar cliente"
  say " 6) Status"
  say " 7) Ativar/reconciliar IPv6 dual-stack"
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
    7) enable_ipv6_existing ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
