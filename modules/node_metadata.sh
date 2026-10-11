#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/node"
CONF="$STATE_DIR/node.conf"
LOCK_FILE="$STATE_DIR/.lock"

read_field() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$CONF" 2>/dev/null || true
}

safe_label() {
  local value="${1:-}"
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]
}

valid_country() {
  local value="${1:-}"
  [[ -z "$value" || "$value" =~ ^[A-Z]{2}$ ]]
}

valid_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

generate_node_id() {
  local hex
  if command_exists openssl; then
    hex="$(openssl rand -hex 8)"
  else
    hex="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  printf 'node-%s\n' "$hex"
}

write_config() {
  local node_id="$1" name="$2" country="$3" region="$4" pool="$5" provider="$6" city="$7" capacity="$8" weight="$9" max_sessions="${10}" enabled="${11}" created="${12}" updated="${13}" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'node_id=%s\n' "$node_id"
    printf 'name=%s\n' "$name"
    printf 'country=%s\n' "$country"
    printf 'region=%s\n' "$region"
    printf 'pool=%s\n' "$pool"
    printf 'provider=%s\n' "$provider"
    printf 'city=%s\n' "$city"
    printf 'capacity=%s\n' "$capacity"
    printf 'weight=%s\n' "$weight"
    printf 'max_sessions=%s\n' "$max_sessions"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$CONF"
  rm -f "$tmp"
}

init_state_unlocked() {
  local now node_id name
  install -d -m 0700 "$STATE_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
  [[ -f "$CONF" ]] && return 0
  now="$(date +%s)"
  node_id="$(generate_node_id)"
  name="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'manager-node')"
  safe_label "$name" || name="$node_id"
  write_config "$node_id" "$name" "" "" "" "" "" 1 1 0 1 "$now" "$now"
}

init_state() {
  install -d -m 0700 "$STATE_DIR"
  touch "$LOCK_FILE"
  chmod 0600 "$LOCK_FILE"
  flock -x "$LOCK_FILE" bash -c '
    set -Eeuo pipefail
    export MANAGER_HOME="$1" MANAGER_ETC="$2"
    exec "$1/modules/node_metadata.sh" --init-unlocked
  ' _ "$MANAGER_HOME" "$MANAGER_ETC"
}

field_value_or_default() {
  local key="$1" default="$2" value
  value="$(read_field "$key")"
  printf '%s\n' "${value:-$default}"
}

set_field_unlocked() {
  local field="$1" value="$2"
  local node_id name country region pool provider city capacity weight max_sessions enabled created now
  [[ -f "$CONF" ]] || init_state_unlocked

  node_id="$(read_field node_id)"
  name="$(field_value_or_default name "$node_id")"
  country="$(read_field country)"
  region="$(read_field region)"
  pool="$(read_field pool)"
  provider="$(read_field provider)"
  city="$(read_field city)"
  capacity="$(field_value_or_default capacity 1)"
  weight="$(field_value_or_default weight 1)"
  max_sessions="$(field_value_or_default max_sessions 0)"
  enabled="$(field_value_or_default enabled 1)"
  created="$(field_value_or_default created_epoch "$(date +%s)")"

  case "$field" in
    name|region|pool|provider|city)
      safe_label "$value" || { err "Valor inválido para $field. Use letras, números e . _ : -"; return 64; }
      ;;
    country)
      value="${value^^}"
      valid_country "$value" || { err "country deve ser vazio ou código ISO de 2 letras, como BR"; return 64; }
      ;;
    capacity|weight)
      valid_uint "$value" && (( value >= 1 && value <= 1000000 )) || { err "$field deve ser inteiro entre 1 e 1000000"; return 64; }
      ;;
    max_sessions)
      valid_uint "$value" && (( value <= 10000000 )) || { err "max_sessions deve ser 0 (sem limite declarado) ou inteiro positivo"; return 64; }
      ;;
    enabled)
      [[ "$value" == 0 || "$value" == 1 ]] || { err "enabled aceita somente 0 ou 1"; return 64; }
      ;;
    node_id|version|created_epoch|updated_epoch)
      err "$field é somente leitura"
      return 73
      ;;
    *)
      err "Campo não permitido: $field"
      return 64
      ;;
  esac

  case "$field" in
    name) name="$value" ;;
    country) country="$value" ;;
    region) region="$value" ;;
    pool) pool="$value" ;;
    provider) provider="$value" ;;
    city) city="$value" ;;
    capacity) capacity="$value" ;;
    weight) weight="$value" ;;
    max_sessions) max_sessions="$value" ;;
    enabled) enabled="$value" ;;
  esac

  now="$(date +%s)"
  write_config "$node_id" "$name" "$country" "$region" "$pool" "$provider" "$city" "$capacity" "$weight" "$max_sessions" "$enabled" "$created" "$now"
}

set_field() {
  local field="$1" value="$2"
  init_state
  flock -x "$LOCK_FILE" "$0" --set-unlocked "$field" "$value"
}

capability_ssh() {
  command_exists sshd || [[ -x /usr/sbin/sshd || -x /usr/sbin/ssh ]] 
}

capability_wireguard() {
  [[ -f /etc/wireguard/wg0.conf ]]
}

capability_openvpn() {
  [[ -f /etc/openvpn/server/manager.conf ]]
}

capability_ipv6() {
  local wg6=0 ovpn6=0
  [[ -f "$MANAGER_ETC/wireguard/ipv6-enabled" ]] && [[ "$(tr -d '[:space:]' < "$MANAGER_ETC/wireguard/ipv6-enabled")" == 1 ]] && wg6=1
  [[ -f "$MANAGER_ETC/openvpn/ipv6-enabled" ]] && [[ "$(tr -d '[:space:]' < "$MANAGER_ETC/openvpn/ipv6-enabled")" == 1 ]] && ovpn6=1
  (( wg6 == 1 || ovpn6 == 1 )) || ipv6_egress_available
}

protocols_csv() {
  local items=()
  capability_ssh && items+=(ssh)
  capability_wireguard && items+=(wireguard)
  capability_openvpn && items+=(openvpn)
  local IFS=,
  printf '%s\n' "${items[*]}"
}

endpoint_value() {
  local service="$1" file="$MANAGER_ETC/$service/endpoint"
  [[ -f "$file" ]] && tr -d '\r\n' < "$file"
}

show_state() {
  init_state
  local ipv4 ipv6 iface4 iface6
  iface4="$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')"
  iface6="$(ipv6_default_interface)"
  ipv4=""
  ipv6=""
  [[ -z "$iface4" ]] || ipv4="$(ip -4 -o addr show dev "$iface4" scope global 2>/dev/null | awk 'NR==1 {sub(/\/.*/,"",$4); print $4}')"
  [[ -z "$iface6" ]] || ipv6="$(ipv6_global_address "$iface6" 2>/dev/null || true)"
  cat "$CONF"
  printf 'protocols=%s\n' "$(protocols_csv)"
  printf 'ipv6_capable=%s\n' "$(capability_ipv6 && echo 1 || echo 0)"
  printf 'default_ipv4_interface=%s\n' "$iface4"
  printf 'default_ipv6_interface=%s\n' "$iface6"
  printf 'local_ipv4=%s\n' "$ipv4"
  printf 'local_ipv6=%s\n' "$ipv6"
  printf 'wireguard_endpoint=%s\n' "$(endpoint_value wireguard)"
  printf 'openvpn_endpoint=%s\n' "$(endpoint_value openvpn)"
}

show_context() {
  init_state
  printf 'node=%s\n' "$(read_field node_id)"
  printf 'country=%s\n' "$(read_field country)"
  printf 'region=%s\n' "$(read_field region)"
  printf 'pool=%s\n' "$(read_field pool)"
}

show_capabilities() {
  init_state
  printf 'protocols=%s\n' "$(protocols_csv)"
  printf 'ipv6=%s\n' "$(capability_ipv6 && echo 1 || echo 0)"
  printf 'capacity=%s\n' "$(field_value_or_default capacity 1)"
  printf 'weight=%s\n' "$(field_value_or_default weight 1)"
  printf 'max_sessions=%s\n' "$(field_value_or_default max_sessions 0)"
  printf 'enabled=%s\n' "$(field_value_or_default enabled 1)"
}

interactive_set() {
  local field value
  header
  say "${C_WHITE}ALTERAR METADADO DO NÓ${C_RESET}\n"
  say "Campos: name, country, region, pool, provider, city, capacity, weight, max_sessions, enabled"
  read -r -p "Campo: " field
  read -r -p "Valor (vazio é permitido em labels opcionais): " value
  if set_field "$field" "$value"; then ok "$field atualizado"; fi
  pause
}

interactive_show() {
  header
  say "${C_WHITE}IDENTIDADE / METADADOS DO NÓ${C_RESET}\n"
  show_state
  pause
}

case "${1:-}" in
  --init)
    init_state
    printf '%s\n' "$CONF"
    exit 0
    ;;
  --init-unlocked)
    init_state_unlocked
    exit 0
    ;;
  --show)
    show_state
    exit 0
    ;;
  --context)
    show_context
    exit 0
    ;;
  --capabilities)
    show_capabilities
    exit 0
    ;;
  --set)
    [[ -n "${2:-}" ]] || { err "Informe o campo"; exit 64; }
    set_field "$2" "${3:-}"
    exit $?
    ;;
  --set-unlocked)
    [[ -n "${2:-}" ]] || exit 64
    set_field_unlocked "$2" "${3:-}"
    exit $?
    ;;
esac

init_state
while true; do
  header
  say "${C_WHITE}IDENTIDADE / METADADOS DO NÓ${C_RESET}\n"
  printf ' node_id:      %s\n' "$(read_field node_id)"
  printf ' nome:         %s\n' "$(read_field name)"
  printf ' país:         %s\n' "$(read_field country)"
  printf ' região:       %s\n' "$(read_field region)"
  printf ' pool:         %s\n' "$(read_field pool)"
  printf ' capacidade:   %s\n' "$(read_field capacity)"
  printf ' peso:         %s\n' "$(read_field weight)"
  printf ' protocolos:   %s\n' "$(protocols_csv)"
  say ""
  say " 1) Ver detalhes completos"
  say " 2) Alterar metadado"
  say " 3) Mostrar contexto region/pool/node"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) interactive_show ;;
    2) interactive_set ;;
    3) header; show_context; pause ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
