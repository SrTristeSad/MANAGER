#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_META_DIR="$MANAGER_ETC/openvpn/meta"
RESELLER_MODULE="$MANAGER_HOME/modules/resellers.sh"

owner_valid() {
  local owner="$1"
  [[ -z "$owner" ]] && return 0
  [[ "$owner" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]]
}

protocol_binding_exists() {
  local protocol="$1" name="$2"
  case "$protocol" in
    ssh) id "$name" >/dev/null 2>&1 ;;
    wireguard) [[ -f "$WG_CLIENT_DIR/$name.meta" && -f "$WG_CLIENT_DIR/$name.conf" ]] ;;
    openvpn) [[ -f "$OVPN_META_DIR/$name.meta" ]] ;;
    *) return 1 ;;
  esac
}

reseller_can_accept_ssh_owner() {
  local owner="$1" user="$2" current
  [[ -n "$owner" ]] || return 0
  [[ -x "$RESELLER_MODULE" ]] || return 1
  current="$($RESELLER_MODULE --owner "$user" 2>/dev/null || true)"
  [[ "$current" == "$owner" ]] && return 0
  "$RESELLER_MODULE" --can-create "$owner" >/dev/null 2>&1
}

sync_ssh_owner() {
  local owner="$1" user="$2"
  [[ -n "$owner" && -n "$user" ]] || return 0
  reseller_can_accept_ssh_owner "$owner" "$user" || return 1
  "$RESELLER_MODULE" --assign "$user" "$owner" >/dev/null
}

normalize_protocols() {
  local input="$1" item out="" seen=""
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

create_identity_impl() {
  local id="$1" owner="$2" expires_epoch="$3" max_sessions="$4" protocols="$5"
  local now normalized
  identity_init
  identity_valid_id "$id" || { err "ID de identidade inválido"; return 64; }
  owner_valid "$owner" || { err "Proprietário inválido"; return 64; }
  [[ "$expires_epoch" =~ ^[0-9]+$ ]] || { err "expires_epoch inválido"; return 64; }
  [[ "$max_sessions" =~ ^[1-9][0-9]*$ ]] || { err "max_sessions inválido"; return 64; }
  (( max_sessions <= 10000 )) || { err "max_sessions muito alto"; return 64; }
  normalized="$(normalize_protocols "$protocols")" || { err "Protocolos inválidos"; return 64; }
  identity_exists "$id" && { err "Identidade já existe: $id"; return 65; }
  now="$(date +%s)"
  identity_write "$id" "$owner" 1 "$expires_epoch" "$max_sessions" "$normalized" "$now" "$now" "" "" ""
}

binding_field() {
  case "$1" in
    ssh) printf 'ssh_user\n' ;;
    wireguard) printf 'wireguard_client\n' ;;
    openvpn) printf 'openvpn_client\n' ;;
    *) return 1 ;;
  esac
}

rewrite_identity_binding() {
  local id="$1" protocol="$2" value="$3" owner enabled expires max_sessions protocols created now ssh_user wg ovpn
  owner="$(identity_read "$id" owner)"
  enabled="$(identity_read "$id" enabled)"
  expires="$(identity_read "$id" expires_epoch)"
  max_sessions="$(identity_read "$id" max_sessions)"
  protocols="$(identity_read "$id" protocols)"
  created="$(identity_read "$id" created_epoch)"
  ssh_user="$(identity_read "$id" ssh_user)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  case "$protocol" in
    ssh) ssh_user="$value" ;;
    wireguard) wg="$value" ;;
    openvpn) ovpn="$value" ;;
    *) return 1 ;;
  esac
  now="$(date +%s)"
  identity_write "$id" "$owner" "$enabled" "$expires" "$max_sessions" "$protocols" "$created" "$now" "$ssh_user" "$wg" "$ovpn"
}

bind_protocol_impl() {
  local id="$1" protocol="$2" name="$3" owner
  identity_exists "$id" || { err "Identidade não encontrada: $id"; return 66; }
  identity_has_protocol "$id" "$protocol" || { err "$protocol não está permitido para $id"; return 67; }
  protocol_binding_exists "$protocol" "$name" || { err "Recurso $protocol não encontrado: $name"; return 66; }
  owner="$(identity_read "$id" owner)"
  if [[ "$protocol" == ssh && -n "$owner" ]]; then
    sync_ssh_owner "$owner" "$name" || { err "Cota/estado do proprietário não permite vincular $name"; return 73; }
  fi
  rewrite_identity_binding "$id" "$protocol" "$name"
}

import_named_identity_impl() {
  local id="$1" owner="$2" expires_epoch="$3" max_sessions="$4" protocols="" created=0
  local ssh_bind="" wg_bind="" ovpn_bind=""
  id "$id" >/dev/null 2>&1 && { protocols="ssh"; ssh_bind="$id"; }
  if [[ -f "$WG_CLIENT_DIR/$id.meta" && -f "$WG_CLIENT_DIR/$id.conf" ]]; then
    [[ -n "$protocols" ]] && protocols+=","
    protocols+="wireguard"; wg_bind="$id"
  fi
  if [[ -f "$OVPN_META_DIR/$id.meta" ]]; then
    [[ -n "$protocols" ]] && protocols+=","
    protocols+="openvpn"; ovpn_bind="$id"
  fi
  [[ -n "$protocols" ]] || { err "Nenhum recurso SSH/WireGuard/OpenVPN encontrado com o nome $id"; return 66; }
  if ! identity_exists "$id"; then
    create_identity_impl "$id" "$owner" "$expires_epoch" "$max_sessions" "$protocols"
    created=1
  fi
  [[ -z "$ssh_bind" ]] || bind_protocol_impl "$id" ssh "$ssh_bind"
  [[ -z "$wg_bind" ]] || bind_protocol_impl "$id" wireguard "$wg_bind"
  [[ -z "$ovpn_bind" ]] || bind_protocol_impl "$id" openvpn "$ovpn_bind"
  printf 'id=%s created=%s protocols=%s\n' "$id" "$created" "$protocols"
}

set_enabled_impl() {
  local id="$1" enabled="$2" owner expires max_sessions protocols created ssh_user wg ovpn
  identity_exists "$id" || return 66
  [[ "$enabled" == 0 || "$enabled" == 1 ]] || return 64
  owner="$(identity_read "$id" owner)"
  expires="$(identity_read "$id" expires_epoch)"
  max_sessions="$(identity_read "$id" max_sessions)"
  protocols="$(identity_read "$id" protocols)"
  created="$(identity_read "$id" created_epoch)"
  ssh_user="$(identity_read "$id" ssh_user)"
  wg="$(identity_read "$id" wireguard_client)"
  ovpn="$(identity_read "$id" openvpn_client)"
  identity_write "$id" "$owner" "$enabled" "$expires" "$max_sessions" "$protocols" "$created" "$(date +%s)" "$ssh_user" "$wg" "$ovpn"
}

show_identity_machine() {
  local id="$1" state
  identity_exists "$id" || return 66
  state="$(identity_effective_state "$id")"
  printf 'id=%s\n' "$id"
  printf 'state=%s\n' "$state"
  printf 'owner=%s\n' "$(identity_read "$id" owner)"
  printf 'enabled=%s\n' "$(identity_read "$id" enabled)"
  printf 'expires_epoch=%s\n' "$(identity_read "$id" expires_epoch)"
  printf 'max_sessions=%s\n' "$(identity_read "$id" max_sessions)"
  printf 'protocols=%s\n' "$(identity_read "$id" protocols)"
  printf 'ssh_user=%s\n' "$(identity_read "$id" ssh_user)"
  printf 'wireguard_client=%s\n' "$(identity_read "$id" wireguard_client)"
  printf 'openvpn_client=%s\n' "$(identity_read "$id" openvpn_client)"
}

list_machine() {
  local file id
  identity_init
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"; id="${id%.conf}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(identity_effective_state "$id")" "$(identity_read "$id" owner)" "$(identity_read "$id" max_sessions)" "$(identity_read "$id" protocols)"
  done
}

interactive_list() {
  header
  identity_init
  say "${C_WHITE}IDENTIDADES MANAGER${C_RESET}\n"
  printf '%-18s %-10s %-18s %-10s %-24s\n' "ID" "ESTADO" "PROPRIETÁRIO" "SESSÕES" "PROTOCOLOS"
  printf '%-18s %-10s %-18s %-10s %-24s\n' "------------------" "----------" "------------------" "----------" "------------------------"
  local file id found=0
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    id="${file##*/}"; id="${id%.conf}"
    printf '%-18s %-10s %-18s %-10s %-24s\n' "$id" "$(identity_effective_state "$id")" "$(identity_read "$id" owner)" "$(identity_read "$id" max_sessions)" "$(identity_read "$id" protocols)"
  done
  (( found == 1 )) || info "Nenhuma identidade criada"
  pause
}

interactive_create() {
  header
  local id owner expiry max_sessions protocols expires_epoch=0
  say "${C_WHITE}CRIAR IDENTIDADE MANAGER${C_RESET}\n"
  read -r -p "ID: " id
  read -r -p "Proprietário/revendedor (vazio = admin): " owner
  read -r -p "Expiração YYYY-MM-DD (vazio = nunca): " expiry
  if [[ -n "$expiry" ]]; then
    date -d "$expiry" '+%F' >/dev/null 2>&1 || { err "Data inválida"; pause; return; }
    expires_epoch="$(date -d "$expiry 23:59:59" +%s)"
  fi
  read -r -p "Máximo de sessões simultâneas [1]: " max_sessions
  max_sessions="${max_sessions:-1}"
  read -r -p "Protocolos permitidos [ssh,wireguard,openvpn]: " protocols
  protocols="${protocols:-ssh,wireguard,openvpn}"
  if ( flock -x 9; create_identity_impl "$id" "$owner" "$expires_epoch" "$max_sessions" "$protocols" ) 9>"$IDENTITY_LOCK"; then
    ok "Identidade $id criada"
  fi
  pause
}

interactive_import() {
  header
  local id owner expiry max_sessions expires_epoch=0
  say "${C_WHITE}IMPORTAR RECURSOS EXISTENTES POR NOME${C_RESET}\n"
  info "Procura o mesmo nome em usuário Linux, WireGuard e OpenVPN."
  read -r -p "Nome/ID existente: " id
  read -r -p "Proprietário/revendedor (vazio = admin): " owner
  read -r -p "Expiração YYYY-MM-DD (vazio = nunca): " expiry
  if [[ -n "$expiry" ]]; then
    date -d "$expiry" '+%F' >/dev/null 2>&1 || { err "Data inválida"; pause; return; }
    expires_epoch="$(date -d "$expiry 23:59:59" +%s)"
  fi
  read -r -p "Máximo de sessões simultâneas [1]: " max_sessions
  max_sessions="${max_sessions:-1}"
  if ( flock -x 9; import_named_identity_impl "$id" "$owner" "$expires_epoch" "$max_sessions" ) 9>"$IDENTITY_LOCK"; then
    ok "Importação/vínculo concluído"
  fi
  pause
}

interactive_bind() {
  header
  local id protocol name
  read -r -p "Identidade: " id
  read -r -p "Protocolo [ssh/wireguard/openvpn]: " protocol
  read -r -p "Nome do recurso existente: " name
  if ( flock -x 9; bind_protocol_impl "$id" "$protocol" "$name" ) 9>"$IDENTITY_LOCK"; then
    ok "$protocol/$name vinculado a $id"
  fi
  pause
}

interactive_toggle() {
  header
  local id current next
  read -r -p "Identidade: " id
  identity_exists "$id" || { err "Identidade não existe"; pause; return; }
  current="$(identity_read "$id" enabled)"
  if [[ "$current" == 1 ]]; then next=0; else next=1; fi
  ( flock -x 9; set_enabled_impl "$id" "$next" ) 9>"$IDENTITY_LOCK"
  ok "Estado atualizado: $(identity_effective_state "$id")"
  warn "Nesta primeira etapa, o estado é política do Connection Engine; enforcement automático nos três protocolos entra nas próximas iterações da 0.6.x."
  pause
}

identity_init
case "${1:-}" in
  --init) printf '%s\n' "$IDENTITY_ROOT"; exit 0 ;;
  --list) list_machine; exit 0 ;;
  --show) show_identity_machine "${2:-}"; exit $? ;;
  --create)
    shift
    ( flock -x 9; create_identity_impl "${1:-}" "${2:-}" "${3:-0}" "${4:-1}" "${5:-ssh}" ) 9>"$IDENTITY_LOCK"
    exit $?
    ;;
  --bind)
    shift
    ( flock -x 9; bind_protocol_impl "${1:-}" "${2:-}" "${3:-}" ) 9>"$IDENTITY_LOCK"
    exit $?
    ;;
  --import-name)
    shift
    ( flock -x 9; import_named_identity_impl "${1:-}" "${2:-}" "${3:-0}" "${4:-1}" ) 9>"$IDENTITY_LOCK"
    exit $?
    ;;
  --enable) ( flock -x 9; set_enabled_impl "${2:-}" 1 ) 9>"$IDENTITY_LOCK"; exit $? ;;
  --disable) ( flock -x 9; set_enabled_impl "${2:-}" 0 ) 9>"$IDENTITY_LOCK"; exit $? ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}CONNECTION ENGINE — IDENTIDADES${C_RESET}\n"
  say " 1) Listar identidades"
  say " 2) Criar identidade"
  say " 3) Importar/vincular recursos existentes pelo mesmo nome"
  say " 4) Vincular recurso existente manualmente"
  say " 5) Ativar/desativar identidade"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) interactive_list ;;
    2) interactive_create ;;
    3) interactive_import ;;
    4) interactive_bind ;;
    5) interactive_toggle ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
