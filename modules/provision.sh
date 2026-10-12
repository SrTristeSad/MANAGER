#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/product_policy.sh"
require_root

CONNECTION_MODULE="$MANAGER_HOME/modules/connection_engine.sh"
PRODUCT_MODULE="$MANAGER_HOME/modules/products.sh"
POLICY_MODULE="$MANAGER_HOME/modules/policy_engine.sh"
SESSION_MODULE="$MANAGER_HOME/modules/session_engine.sh"
RESELLER_MODULE="$MANAGER_HOME/modules/resellers.sh"
RESELLER_PRODUCT_QUOTA_MODULE="$MANAGER_HOME/modules/reseller_product_quotas.sh"
IPV6_GUARD_MODULE="$MANAGER_HOME/modules/ipv6_guard.sh"

PROVISION_LOCK="$IDENTITY_ROOT/provision.lock"
PROVISION_LOG="/var/log/manager/provision-events.log"
SSH_LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"
RESELLER_OWNERS_DIR="$MANAGER_ETC/access/owners"

WG_DIR="/etc/wireguard"
WG_STATE_DIR="$MANAGER_ETC/wireguard"
WG_CLIENT_DIR="$WG_STATE_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
WG_NET="10.66.66"
WG_NET6="fd66:66:66::"

OVPN_DIR="/etc/openvpn/server"
OVPN_CONF="$OVPN_DIR/manager.conf"
OVPN_STATE_DIR="$MANAGER_ETC/openvpn"
OVPN_EASYRSA_DIR="$OVPN_STATE_DIR/easy-rsa"
OVPN_CLIENT_DIR="$OVPN_STATE_DIR/clients"
OVPN_META_DIR="$OVPN_STATE_DIR/meta"
OVPN_TLS_KEY="$OVPN_DIR/manager-tls-crypt.key"
OVPN_CA_FILE="$OVPN_DIR/manager-ca.crt"
OVPN_CRL_FILE="$OVPN_DIR/manager-crl.pem"

PROV_SSH_PASSWORD=""
PROV_WG_PROFILE=""
PROV_WG_IP=""
PROV_WG_IP6=""
PROV_OVPN_PROFILE=""

provision_init() {
  identity_init
  install -d -m 0700 "$IDENTITY_ROOT"
  touch "$PROVISION_LOCK"
  chmod 0600 "$PROVISION_LOCK"
  install -d -m 0755 "$(dirname "$PROVISION_LOG")"
  touch "$PROVISION_LOG"
  chmod 0600 "$PROVISION_LOG"
}

log_event() {
  local action="$1" id="$2" product="$3" owner="$4" protocols="$5" result="$6"
  printf '%s action=%s id=%s product=%s owner=%s protocols=%s result=%s\n' \
    "$(date -Is)" "$action" "$id" "${product:--}" "${owner:--}" "${protocols:--}" "$result" >> "$PROVISION_LOG"
}

valid_owner() { [[ -z "${1:-}" || "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,47}$ ]]; }

normalize_protocols() {
  local input="${1:-}" item out="" seen=""
  input="${input// /}"
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    case "$item" in
      ssh|wireguard|openvpn)
        if [[ ",$seen," != *",$item,"* ]]; then
          [[ -n "$out" ]] && out+=","
          out+="$item"
          [[ -n "$seen" ]] && seen+=","
          seen+="$item"
        fi
        ;;
      *) return 1 ;;
    esac
  done
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

protocol_list_has() { [[ ",$1," == *",$2,"* ]]; }

select_protocols() {
  local product="$1" requested="${2:-}" allowed selected item
  allowed="$(product_read "$product" protocols)"
  if [[ -z "$requested" ]]; then
    [[ "$allowed" == "*" ]] && selected="ssh,wireguard,openvpn" || selected="$allowed"
  else
    selected="$(normalize_protocols "$requested")" || return 64
  fi
  if [[ "$allowed" != "*" ]]; then
    IFS=',' read -r -a selected_items <<< "$selected"
    for item in "${selected_items[@]}"; do protocol_list_has "$allowed" "$item" || return 67; done
  fi
  normalize_protocols "$selected"
}

resource_conflict() {
  local id="$1" protocols="$2"
  if protocol_list_has "$protocols" ssh && id "$id" >/dev/null 2>&1; then err "Usuário SSH já existe: $id"; return 65; fi
  if protocol_list_has "$protocols" wireguard && { [[ -e "$WG_CLIENT_DIR/$id.conf" ]] || [[ -e "$WG_CLIENT_DIR/$id.meta" ]]; }; then err "Cliente WireGuard já existe: $id"; return 65; fi
  if protocol_list_has "$protocols" openvpn && { [[ -e "$OVPN_CLIENT_DIR/$id.ovpn" ]] || [[ -e "$OVPN_META_DIR/$id.meta" ]]; }; then err "Cliente OpenVPN já existe: $id"; return 65; fi
}

preflight_protocols() {
  local protocols="$1"
  if protocol_list_has "$protocols" ssh; then
    if ! command_exists useradd || ! command_exists chpasswd || ! command_exists userdel; then
      err "Ferramentas de usuário Linux ausentes"
      return 69
    fi
  fi
  if protocol_list_has "$protocols" wireguard; then
    command_exists wg || { err "wireguard-tools não está instalado"; return 69; }
    [[ -f "$WG_CONF" && -f "$WG_DIR/server.pub" && -f "$WG_STATE_DIR/endpoint" && -f "$WG_STATE_DIR/port" ]] || { err "Servidor WireGuard do MANAGER não está configurado"; return 69; }
  fi
  if protocol_list_has "$protocols" openvpn; then
    [[ -f "$OVPN_CONF" && -x "$OVPN_EASYRSA_DIR/easyrsa" && -f "$OVPN_CA_FILE" && -f "$OVPN_TLS_KEY" ]] || { err "Servidor OpenVPN do MANAGER não está configurado"; return 69; }
    [[ -f "$OVPN_STATE_DIR/endpoint" && -f "$OVPN_STATE_DIR/port" && -f "$OVPN_STATE_DIR/transport" ]] || { err "Metadados do servidor OpenVPN estão incompletos"; return 69; }
  fi
}

preflight_owner() {
  local owner="$1" identity_id="$2" product="$3"
  [[ -n "$owner" ]] || return 0
  valid_owner "$owner" || { err "Proprietário inválido"; return 64; }
  [[ -x "$RESELLER_MODULE" && -x "$RESELLER_PRODUCT_QUOTA_MODULE" ]] || { err "Módulos de revenda/cota ausentes"; return 69; }
  "$RESELLER_MODULE" --can-create "$owner" "$identity_id" >/dev/null 2>&1 || { err "Cota/estado não permite nova identidade para $owner"; return 73; }
  "$RESELLER_PRODUCT_QUOTA_MODULE" --can-assign "$owner" "$product" "$identity_id" >/dev/null 2>&1 || { err "Cota do produto $product não permite nova identidade para $owner"; return 73; }
}

remove_limit_entry() {
  local user="$1" tmp
  [[ -f "$SSH_LIMITS_FILE" ]] || return 0
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$SSH_LIMITS_FILE" > "$tmp"
  install -m 0644 "$tmp" "$SSH_LIMITS_FILE"
  rm -f "$tmp"
}

create_ssh_resource() {
  local user="$1" expires_epoch="$2" expiry_date
  PROV_SSH_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [[ -n "$PROV_SSH_PASSWORD" ]] || return 1
  useradd -m -s /bin/bash "$user" || return 1
  if ! printf '%s:%s\n' "$user" "$PROV_SSH_PASSWORD" | chpasswd; then userdel -r "$user" >/dev/null 2>&1 || true; return 1; fi
  if [[ "$expires_epoch" =~ ^[0-9]+$ ]] && (( expires_epoch > 0 )); then
    expiry_date="$(date -d "@$expires_epoch" '+%F')"
    chage -E "$expiry_date" "$user" || return 1
  fi
  passwd -l "$user" >/dev/null 2>&1 || return 1
}

unlock_ssh_resource() { passwd -u "$1" >/dev/null 2>&1; }

remove_ssh_resource() {
  local user="$1"
  rm -f "$RESELLER_OWNERS_DIR/$user" 2>/dev/null || true
  if id "$user" >/dev/null 2>&1; then
    pkill -TERM -u "$user" 2>/dev/null || true
    sleep 0.1
    pkill -KILL -u "$user" 2>/dev/null || true
    userdel -r "$user" >/dev/null 2>&1 || userdel "$user" >/dev/null 2>&1 || true
  fi
  remove_limit_entry "$user" || true
}

wg_ipv6_enabled() { [[ -f "$WG_STATE_DIR/ipv6-enabled" && "$(tr -d '[:space:]' < "$WG_STATE_DIR/ipv6-enabled")" == 1 ]]; }

next_wg_octet() {
  local n
  install -d -m 0700 "$WG_CLIENT_DIR"
  for n in $(seq 2 254); do
    if ! grep -Rqs "Address = $WG_NET.$n/32" "$WG_CLIENT_DIR" 2>/dev/null && ! grep -Rqs "Address = $WG_NET.$n/32," "$WG_CLIENT_DIR" 2>/dev/null; then
      printf '%s\n' "$n"
      return 0
    fi
  done
  return 1
}

create_wireguard_resource() {
  local name="$1" octet ip4 ip6="" address allowed priv pub psk server_pub endpoint port endpoint_port dns file
  install -d -m 0700 "$WG_CLIENT_DIR"
  file="$WG_CLIENT_DIR/$name.conf"
  [[ ! -e "$file" && ! -e "$WG_CLIENT_DIR/$name.meta" ]] || return 1
  octet="$(next_wg_octet)" || return 1
  ip4="$WG_NET.$octet"
  address="$ip4/32"
  allowed="0.0.0.0/0"
  if wg_ipv6_enabled; then
    ip6="$WG_NET6$octet"
    address+=", $ip6/128"
    allowed+=", ::/0"
  fi
  priv="$(wg genkey)" || return 1
  pub="$(printf '%s' "$priv" | wg pubkey)" || return 1
  psk="$(wg genpsk)" || return 1
  server_pub="$(cat "$WG_DIR/server.pub")"
  endpoint="$(cat "$WG_STATE_DIR/endpoint")"
  port="$(cat "$WG_STATE_DIR/port")"
  endpoint_port="$(format_host_port "$endpoint" "$port")"
  dns="1.1.1.1"
  if grep -q "^listen-address=$WG_NET.1$" /etc/dnsmasq.d/90-manager-adblock.conf 2>/dev/null; then dns="$WG_NET.1"; fi

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
  cat > "$WG_CLIENT_DIR/$name.meta" <<EOF
name=$name
ip=$ip4
ip4=$ip4
ip6=$ip6
public_key=$pub
EOF
  chmod 0600 "$WG_CLIENT_DIR/$name.meta"
  cat >> "$WG_CONF" <<EOF

# MANAGER-PEER-BEGIN $name
[Peer]
PublicKey = $pub
PresharedKey = $psk
AllowedIPs = $address
# MANAGER-PEER-END $name
EOF
  chmod 0600 "$WG_CONF"
  if ! systemctl reload wg-quick@wg0 >/dev/null 2>&1 && ! systemctl restart wg-quick@wg0 >/dev/null 2>&1; then
    remove_wireguard_resource "$name"
    return 1
  fi
  PROV_WG_PROFILE="$file"
  PROV_WG_IP="$ip4"
  PROV_WG_IP6="$ip6"
}

remove_wireguard_resource() {
  local name="$1" meta pub tmp
  meta="$WG_CLIENT_DIR/$name.meta"
  if [[ -f "$meta" ]]; then
    pub="$(awk -F= '$1=="public_key" {print $2; exit}' "$meta")"
    [[ -z "$pub" ]] || wg set wg0 peer "$pub" remove >/dev/null 2>&1 || true
  fi
  if [[ -f "$WG_CONF" ]]; then
    tmp="$(mktemp)"
    awk -v n="$name" '$0 == "# MANAGER-PEER-BEGIN " n {skip=1; next} $0 == "# MANAGER-PEER-END " n {skip=0; next} !skip {print}' "$WG_CONF" > "$tmp"
    install -m 0600 "$tmp" "$WG_CONF"
    rm -f "$tmp"
  fi
  rm -f "$WG_CLIENT_DIR/$name.conf" "$meta"
  systemctl reload wg-quick@wg0 >/dev/null 2>&1 || true
}

extract_pem() {
  local begin="$1" end="$2" file="$3"
  awk -v b="$begin" -v e="$end" '$0 ~ b {p=1} p {print} $0 ~ e {exit}' "$file"
}

create_openvpn_resource() {
  local name="$1" endpoint port transport client_proto file ipv6=0
  install -d -m 0700 "$OVPN_CLIENT_DIR" "$OVPN_META_DIR"
  file="$OVPN_CLIENT_DIR/$name.ovpn"
  [[ ! -e "$file" && ! -e "$OVPN_META_DIR/$name.meta" ]] || return 1
  if ! ( cd "$OVPN_EASYRSA_DIR"; EASYRSA_BATCH=1 ./easyrsa build-client-full "$name" nopass ) >/dev/null 2>&1; then return 1; fi
  endpoint="$(cat "$OVPN_STATE_DIR/endpoint")"
  port="$(cat "$OVPN_STATE_DIR/port")"
  transport="$(cat "$OVPN_STATE_DIR/transport")"
  [[ -f "$OVPN_STATE_DIR/ipv6-enabled" && "$(tr -d '[:space:]' < "$OVPN_STATE_DIR/ipv6-enabled")" == 1 ]] && ipv6=1
  [[ "$transport" == tcp ]] && client_proto="tcp-client" || client_proto="udp"
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
$(cat "$OVPN_CA_FILE")
</ca>
<cert>
$(extract_pem '-----BEGIN CERTIFICATE-----' '-----END CERTIFICATE-----' "$OVPN_EASYRSA_DIR/pki/issued/$name.crt")
</cert>
<key>
$(cat "$OVPN_EASYRSA_DIR/pki/private/$name.key")
</key>
<tls-crypt>
$(cat "$OVPN_TLS_KEY")
</tls-crypt>
EOF
  chmod 0600 "$file"
  cat > "$OVPN_META_DIR/$name.meta" <<EOF
name=$name
created=$(date -Is)
status=active
ipv6=$ipv6
EOF
  chmod 0600 "$OVPN_META_DIR/$name.meta"
  PROV_OVPN_PROFILE="$file"
}

revoke_openvpn_resource() {
  local name="$1" purge_meta="${2:-0}" meta
  meta="$OVPN_META_DIR/$name.meta"
  if [[ -x "$OVPN_EASYRSA_DIR/easyrsa" && -f "$OVPN_EASYRSA_DIR/pki/issued/$name.crt" ]]; then
    ( cd "$OVPN_EASYRSA_DIR"; EASYRSA_BATCH=1 ./easyrsa revoke "$name" >/dev/null 2>&1 || true; EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl >/dev/null 2>&1 || true )
    [[ -f "$OVPN_EASYRSA_DIR/pki/crl.pem" ]] && install -m 0644 "$OVPN_EASYRSA_DIR/pki/crl.pem" "$OVPN_CRL_FILE"
  fi
  rm -f "$OVPN_CLIENT_DIR/$name.ovpn"
  if [[ "$purge_meta" == 1 ]]; then
    rm -f "$meta" "$OVPN_EASYRSA_DIR/pki/private/$name.key" "$OVPN_EASYRSA_DIR/pki/issued/$name.crt" "$OVPN_EASYRSA_DIR/pki/reqs/$name.req"
  elif [[ -f "$meta" ]]; then
    if grep -q '^status=' "$meta"; then sed -i 's/^status=.*/status=revoked/' "$meta"; else printf 'status=revoked\n' >> "$meta"; fi
  fi
}

rollback_fresh_identity() {
  local id="$1" product_assigned="$2" ssh_created="$3" wg_created="$4" ovpn_created="$5"
  (( ovpn_created == 0 )) || revoke_openvpn_resource "$id" 1 || true
  (( wg_created == 0 )) || remove_wireguard_resource "$id" || true
  (( ssh_created == 0 )) || remove_ssh_resource "$id" || true
  if (( product_assigned == 1 )); then "$PRODUCT_MODULE" --unassign "$id" >/dev/null 2>&1 || true; fi
  rm -f "$(identity_file "$id")"
  [[ ! -x "$RESELLER_MODULE" ]] || "$RESELLER_MODULE" --release-identity "$id" >/dev/null 2>&1 || true
  rm -f "$IDENTITY_ROOT/session-epochs/$id.epoch" "/var/lib/manager/identity-usage/identities/$id.state" 2>/dev/null || true
  identity_signal_change
}

reconcile_runtime() {
  "$PRODUCT_MODULE" --reconcile >/dev/null 2>&1 && "$POLICY_MODULE" --reconcile >/dev/null 2>&1 || return 1
  [[ ! -x "$IPV6_GUARD_MODULE" ]] || "$IPV6_GUARD_MODULE" --reconcile >/dev/null 2>&1 || return 1
}

provision_impl() {
  local id="$1" product="$2" owner="${3:-}" requested_protocols="${4:-}"
  local protocols plan_max base_max effective_expires effective_max rc
  local product_assigned=0 ssh_created=0 wg_created=0 ovpn_created=0

  identity_valid_id "$id" || { err "ID de identidade inválido"; return 64; }
  valid_owner "$owner" || { err "Proprietário inválido"; return 64; }
  product_exists "$product" || { err "Produto não encontrado: $product"; return 66; }
  [[ "$(product_read "$product" enabled)" == 1 ]] || { err "Produto está desativado: $product"; return 68; }
  identity_exists "$id" && { err "Identidade já existe: $id"; return 65; }
  protocols="$(select_protocols "$product" "$requested_protocols")" || { rc=$?; err "Protocolos solicitados não são compatíveis com o produto"; return "$rc"; }
  resource_conflict "$id" "$protocols" || return $?
  preflight_protocols "$protocols" || return $?
  preflight_owner "$owner" "$id" "$product" || return $?

  plan_max="$(product_read "$product" max_sessions)"
  [[ "$plan_max" =~ ^[0-9]+$ ]] || plan_max=0
  (( plan_max > 0 )) && base_max="$plan_max" || base_max=1

  if ! "$CONNECTION_MODULE" --create "$id" "$owner" 0 "$base_max" "$protocols" >/dev/null; then log_event provision "$id" "$product" "$owner" "$protocols" identity-create-failed; return 70; fi
  if ! "$PRODUCT_MODULE" --assign "$id" "$product" >/dev/null; then rollback_fresh_identity "$id" 0 0 0 0; log_event provision "$id" "$product" "$owner" "$protocols" product-assign-failed; return 70; fi
  product_assigned=1
  effective_expires="$(identity_read "$id" expires_epoch)"
  effective_max="$(identity_read "$id" max_sessions)"

  if protocol_list_has "$protocols" ssh; then
    if ! create_ssh_resource "$id" "$effective_expires"; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" ssh-create-failed; return 70; fi
    ssh_created=1
    if ! "$CONNECTION_MODULE" --bind "$id" ssh "$id" >/dev/null; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" ssh-bind-failed; return 70; fi
  fi
  if protocol_list_has "$protocols" wireguard; then
    if ! create_wireguard_resource "$id"; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" wireguard-create-failed; return 70; fi
    wg_created=1
    if ! "$CONNECTION_MODULE" --bind "$id" wireguard "$id" >/dev/null; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" wireguard-bind-failed; return 70; fi
  fi
  if protocol_list_has "$protocols" openvpn; then
    if ! create_openvpn_resource "$id"; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" openvpn-create-failed; return 70; fi
    ovpn_created=1
    if ! "$CONNECTION_MODULE" --bind "$id" openvpn "$id" >/dev/null; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" openvpn-bind-failed; return 70; fi
  fi

  if ! reconcile_runtime; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" reconcile-failed; return 70; fi
  if (( ssh_created == 1 )) && ! unlock_ssh_resource "$id"; then rollback_fresh_identity "$id" "$product_assigned" "$ssh_created" "$wg_created" "$ovpn_created"; log_event provision "$id" "$product" "$owner" "$protocols" ssh-unlock-failed; return 70; fi

  log_event provision "$id" "$product" "$owner" "$protocols" ok
  printf 'status=ok\nidentity_id=%s\nproduct_id=%s\nowner=%s\nprotocols=%s\nmax_sessions=%s\nexpires_epoch=%s\n' "$id" "$product" "$owner" "$protocols" "$effective_max" "$effective_expires"
  (( ssh_created == 0 )) || printf 'ssh_user=%s\nssh_password=%s\n' "$id" "$PROV_SSH_PASSWORD"
  if (( wg_created == 1 )); then
    printf 'wireguard_client=%s\nwireguard_ip=%s\nwireguard_ipv4=%s\nwireguard_ipv6=%s\nwireguard_profile=%s\n' "$id" "$PROV_WG_IP" "$PROV_WG_IP" "$PROV_WG_IP6" "$PROV_WG_PROFILE"
  fi
  if (( ovpn_created == 1 )); then
    printf 'openvpn_client=%s\nopenvpn_ipv6=%s\nopenvpn_profile=%s\n' "$id" "$([[ -f "$OVPN_STATE_DIR/ipv6-enabled" ]] && cat "$OVPN_STATE_DIR/ipv6-enabled" || echo 0)" "$PROV_OVPN_PROFILE"
  fi
}

rewrite_identity_protocols_local() {
  local id="$1" protocols="$2" owner enabled expires max_sessions created ssh_user wg ovpn
  owner="$(identity_read "$id" owner)"
  enabled="$(identity_read "$id" enabled)"
  expires="$(identity_read "$id" expires_epoch)"
  max_sessions="$(identity_read "$id" max_sessions)"
  created="$(identity_read "$id" created_epoch)"
  ssh_user="$(identity_read "$id" ssh_user)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  identity_write "$id" "$owner" "$enabled" "$expires" "$max_sessions" "$protocols" "$created" "$(date +%s)" "$ssh_user" "$wg" "$ovpn"
}

ensure_protocol_impl() {
  local id="$1" product="$2" protocol="$3" assigned state previous_protocols next_protocols binding created=0 expanded=0 expires
  identity_valid_id "$id" || { err "ID de identidade inválido"; return 64; }
  [[ "$protocol" == ssh || "$protocol" == wireguard || "$protocol" == openvpn ]] || { err "Protocolo inválido"; return 64; }
  product_exists "$product" || { err "Produto não encontrado no nó: $product"; return 66; }
  [[ "$(product_read "$product" enabled)" == 1 ]] || { err "Produto está desativado no nó: $product"; return 68; }
  select_protocols "$product" "$protocol" >/dev/null || { err "Produto $product não autoriza $protocol neste nó"; return 67; }

  if ! identity_exists "$id"; then
    provision_impl "$id" "$product" "" "$protocol" || return $?
    printf 'provision_action=created\nresource_created=1\n'
    return 0
  fi

  assigned="$(product_for_identity "$id" 2>/dev/null || true)"
  [[ "$assigned" == "$product" ]] || { err "Identidade local $id pertence a produto diferente ou sem produto"; return 67; }
  state="$(identity_effective_state "$id")"
  [[ "$state" == active ]] || { err "Identidade local $id não está ativa: $state"; return 67; }
  preflight_protocols "$protocol" || return $?

  previous_protocols="$(identity_read "$id" protocols)"
  if ! protocol_list_has "$previous_protocols" "$protocol"; then
    next_protocols="$(normalize_protocols "$previous_protocols,$protocol")" || return 64
    rewrite_identity_protocols_local "$id" "$next_protocols" || return 70
    expanded=1
  fi
  expires="$(identity_read "$id" expires_epoch)"

  case "$protocol" in
    ssh)
      binding="$(identity_read "$id" ssh_user)"
      if [[ -n "$binding" ]]; then
        [[ "$binding" == "$id" ]] && id "$binding" >/dev/null 2>&1 || { (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Binding SSH local inconsistente para $id"; return 67; }
      else
        if id "$id" >/dev/null 2>&1; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Usuário SSH local existe sem binding MANAGER: $id"; return 65; fi
        if ! create_ssh_resource "$id" "$expires"; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        if ! "$CONNECTION_MODULE" --bind "$id" ssh "$id" >/dev/null; then remove_ssh_resource "$id"; (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        if ! unlock_ssh_resource "$id"; then
          rewrite_identity_binding "$id" ssh "" >/dev/null 2>&1 || true
          remove_ssh_resource "$id"
          (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"
          return 70
        fi
        created=1
      fi
      ;;
    wireguard)
      binding="$(identity_read "$id" wireguard_client)"
      if [[ -n "$binding" ]]; then
        [[ "$binding" == "$id" && -f "$WG_CLIENT_DIR/$binding.conf" && -f "$WG_CLIENT_DIR/$binding.meta" ]] || { (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Binding WireGuard local inconsistente para $id"; return 67; }
      else
        if [[ -e "$WG_CLIENT_DIR/$id.conf" || -e "$WG_CLIENT_DIR/$id.meta" ]]; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Recurso WireGuard local existe sem binding MANAGER: $id"; return 65; fi
        if ! create_wireguard_resource "$id"; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        if ! "$CONNECTION_MODULE" --bind "$id" wireguard "$id" >/dev/null; then remove_wireguard_resource "$id"; (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        created=1
      fi
      ;;
    openvpn)
      binding="$(identity_read "$id" openvpn_client)"
      if [[ -n "$binding" ]]; then
        [[ "$binding" == "$id" && -f "$OVPN_CLIENT_DIR/$binding.ovpn" && -f "$OVPN_META_DIR/$binding.meta" ]] || { (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Binding OpenVPN local inconsistente para $id"; return 67; }
      else
        if [[ -e "$OVPN_CLIENT_DIR/$id.ovpn" || -e "$OVPN_META_DIR/$id.meta" ]]; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; err "Recurso OpenVPN local existe sem binding MANAGER: $id"; return 65; fi
        if ! create_openvpn_resource "$id"; then (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        if ! "$CONNECTION_MODULE" --bind "$id" openvpn "$id" >/dev/null; then revoke_openvpn_resource "$id" 1; (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"; return 70; fi
        created=1
      fi
      ;;
  esac

  if [[ "$protocol" == wireguard && "$created" == 0 ]]; then
    PROV_WG_IP="$(awk -F= '$1=="ip4" || $1=="ip" {print $2; exit}' "$WG_CLIENT_DIR/$id.meta")"
    PROV_WG_IP6="$(awk -F= '$1=="ip6" {print $2; exit}' "$WG_CLIENT_DIR/$id.meta")"
  fi
  if ! reconcile_runtime; then
    if (( created == 1 )); then
      case "$protocol" in
        ssh) rewrite_identity_binding "$id" ssh "" >/dev/null 2>&1 || true; remove_ssh_resource "$id" ;;
        wireguard) rewrite_identity_binding "$id" wireguard "" >/dev/null 2>&1 || true; remove_wireguard_resource "$id" ;;
        openvpn) rewrite_identity_binding "$id" openvpn "" >/dev/null 2>&1 || true; revoke_openvpn_resource "$id" 1 ;;
      esac
    fi
    (( expanded == 0 )) || rewrite_identity_protocols_local "$id" "$previous_protocols"
    err "Falha ao reconciliar política após ensure de $protocol/$id"
    return 70
  fi
  printf 'status=ok\nidentity_id=%s\nproduct_id=%s\nprotocols=%s\nprovision_action=%s\nresource_created=%s\n' \
    "$id" "$product" "$protocol" "$([[ "$created" == 1 ]] && echo created || echo reused)" "$created"
  case "$protocol" in
    ssh) printf 'ssh_user=%s\n' "$id"; (( created == 0 )) || printf 'ssh_password=%s\n' "$PROV_SSH_PASSWORD" ;;
    wireguard) printf 'wireguard_client=%s\nwireguard_ip=%s\nwireguard_ipv4=%s\nwireguard_ipv6=%s\nwireguard_profile=%s\n' "$id" "${PROV_WG_IP:-}" "${PROV_WG_IP:-}" "${PROV_WG_IP6:-}" "$WG_CLIENT_DIR/$id.conf" ;;
    openvpn) printf 'openvpn_client=%s\nopenvpn_profile=%s\n' "$id" "$OVPN_CLIENT_DIR/$id.ovpn" ;;
  esac
}


clear_identity_bindings() {
  local id="$1" owner enabled expires max_sessions protocols created
  owner="$(identity_read "$id" owner)"; enabled="$(identity_read "$id" enabled)"; expires="$(identity_read "$id" expires_epoch)"; max_sessions="$(identity_read "$id" max_sessions)"; protocols="$(identity_read "$id" protocols)"; created="$(identity_read "$id" created_epoch)"
  identity_write "$id" "$owner" "$enabled" "$expires" "$max_sessions" "$protocols" "$created" "$(date +%s)" "" "" ""
}

revoke_impl() {
  local id="$1" product owner protocols ssh_user wg_client ovpn_client failures=0
  identity_valid_id "$id" || return 64
  identity_exists "$id" || { err "Identidade não encontrada: $id"; return 66; }
  product="$(product_for_identity "$id" 2>/dev/null || true)"; owner="$(identity_read "$id" owner)"; protocols="$(identity_read "$id" protocols)"; ssh_user="$(identity_read "$id" ssh_user)"; wg_client="$(identity_read "$id" wireguard_client)"; ovpn_client="$(identity_read "$id" openvpn_client)"

  "$CONNECTION_MODULE" --disable "$id" >/dev/null 2>&1 || failures=$((failures + 1))
  "$SESSION_MODULE" --revoke-all "$id" >/dev/null 2>&1 || true
  "$POLICY_MODULE" --reconcile >/dev/null 2>&1 || true
  [[ ! -x "$IPV6_GUARD_MODULE" ]] || "$IPV6_GUARD_MODULE" --reconcile >/dev/null 2>&1 || true
  [[ -z "$ovpn_client" ]] || revoke_openvpn_resource "$ovpn_client" 0 || failures=$((failures + 1))
  [[ -z "$wg_client" ]] || remove_wireguard_resource "$wg_client" || failures=$((failures + 1))
  [[ -z "$ssh_user" ]] || remove_ssh_resource "$ssh_user" || failures=$((failures + 1))
  [[ -z "$product" ]] || "$PRODUCT_MODULE" --unassign "$id" >/dev/null 2>&1 || failures=$((failures + 1))
  clear_identity_bindings "$id" || failures=$((failures + 1))
  "$CONNECTION_MODULE" --disable "$id" >/dev/null 2>&1 || true
  "$POLICY_MODULE" --reconcile >/dev/null 2>&1 || true
  [[ ! -x "$IPV6_GUARD_MODULE" ]] || "$IPV6_GUARD_MODULE" --reconcile >/dev/null 2>&1 || true
  if (( failures == 0 )) && [[ -n "$owner" && -x "$RESELLER_MODULE" ]]; then "$RESELLER_MODULE" --release-identity "$id" >/dev/null 2>&1 || failures=$((failures + 1)); fi

  if (( failures > 0 )); then log_event revoke "$id" "$product" "$owner" "$protocols" partial; err "Revogação terminou com $failures falha(s). A identidade permaneceu desativada."; return 70; fi
  log_event revoke "$id" "$product" "$owner" "$protocols" ok
  printf 'status=revoked\nidentity_id=%s\nstate=%s\n' "$id" "$(identity_effective_state "$id")"
}

show_preflight() {
  local id="$1" product="$2" owner="${3:-}" requested_protocols="${4:-}" protocols
  identity_valid_id "$id" || return 64
  product_exists "$product" || return 66
  [[ "$(product_read "$product" enabled)" == 1 ]] || return 68
  ! identity_exists "$id" || return 65
  protocols="$(select_protocols "$product" "$requested_protocols")" || return $?
  resource_conflict "$id" "$protocols" || return $?
  preflight_protocols "$protocols" || return $?
  preflight_owner "$owner" "$id" "$product" || return $?
  printf 'status=ready\nidentity_id=%s\nproduct_id=%s\nowner=%s\nprotocols=%s\n' "$id" "$product" "$owner" "$protocols"
}

interactive_provision() {
  local id product owner protocols output
  header
  say "${C_WHITE}PROVISIONAMENTO UNIFICADO${C_RESET}\n"
  info "A identidade, o plano e os recursos técnicos serão criados como uma única operação."
  read -r -p "ID da identidade/cliente: " id
  read -r -p "Produto/plano: " product
  read -r -p "Proprietário/revendedor (vazio = admin): " owner
  read -r -p "Protocolos (vazio = usar o produto): " protocols
  if output="$(flock -x "$PROVISION_LOCK" "$0" --create-unlocked "$id" "$product" "$owner" "$protocols")"; then
    ok "Provisionamento concluído"; say ""; printf '%s\n' "$output"
    grep -q '^ssh_password=' <<< "$output" && say "\n${C_YELLOW}A senha SSH acima é exibida somente agora. Guarde-a em local seguro.${C_RESET}"
  else
    err "Provisionamento falhou; recursos criados nesta tentativa foram revertidos."
  fi
  pause
}

interactive_revoke() {
  local id
  header
  say "${C_WHITE}REVOGAR IDENTIDADE PROVISIONADA${C_RESET}\n"
  read -r -p "Identidade: " id
  identity_exists "$id" || { err "Identidade não encontrada"; pause; return; }
  warn "SSH será removido, WireGuard será revogado e o certificado OpenVPN será revogado quando vinculados."
  warn "A identidade lógica permanece desativada para histórico/auditoria e sua vaga de revenda é liberada após revogação completa."
  if confirm "Revogar definitivamente os acessos de $id?"; then
    flock -x "$PROVISION_LOCK" "$0" --revoke-unlocked "$id" && ok "Acessos revogados"
  fi
  pause
}

provision_init
case "${1:-}" in
  --preflight) show_preflight "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $? ;;
  --create) shift; flock -x "$PROVISION_LOCK" "$0" --create-unlocked "${1:-}" "${2:-}" "${3:-}" "${4:-}"; exit $? ;;
  --create-unlocked) provision_impl "${2:-}" "${3:-}" "${4:-}" "${5:-}"; exit $? ;;
  --ensure) shift; flock -x "$PROVISION_LOCK" "$0" --ensure-unlocked "${1:-}" "${2:-}" "${3:-}"; exit $? ;;
  --ensure-unlocked) ensure_protocol_impl "${2:-}" "${3:-}" "${4:-}"; exit $? ;;
  --revoke) shift; flock -x "$PROVISION_LOCK" "$0" --revoke-unlocked "${1:-}"; exit $? ;;
  --revoke-unlocked) revoke_impl "${2:-}"; exit $? ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}PROVISIONAMENTO UNIFICADO${C_RESET}\n"
  say " 1) Criar identidade + plano + acessos"
  say " 2) Revogar todos os acessos de uma identidade"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) interactive_provision ;;
    2) interactive_revoke ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
