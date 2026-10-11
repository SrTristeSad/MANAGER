#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/identity.sh"
require_root

SESSION_ENGINE="$MANAGER_HOME/modules/session_engine.sh"
USAGE_ROOT="${MANAGER_USAGE_ROOT:-/var/lib/manager/identity-usage}"
STATE_DIR="$USAGE_ROOT/identities"
SOURCE_DIR="$USAGE_ROOT/sources"
USAGE_LOCK="$USAGE_ROOT/.lock"
USAGE_SERVICE="/etc/systemd/system/manager-identity-usage.service"
USAGE_TIMER="/etc/systemd/system/manager-identity-usage.timer"
WG_CLIENT_DIR="$MANAGER_ETC/wireguard/clients"
OVPN_STATUS="/run/openvpn/manager-status.log"
LEASE_CACHE=""

usage_init() {
  identity_init
  install -d -m 0700 "$USAGE_ROOT" "$STATE_DIR" "$SOURCE_DIR"
  touch "$USAGE_LOCK"
  chmod 0600 "$USAGE_LOCK"
}

valid_counter() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
valid_protocol() { [[ "${1:-}" == wireguard || "${1:-}" == openvpn ]]; }
valid_resource() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,63}$ ]]; }
valid_source_key() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 512 && "$value" != *$'\n'* && "$value" != *$'\t'* ]]
}

state_file() { printf '%s/%s.state\n' "$STATE_DIR" "$1"; }

state_read() {
  local id="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$(state_file "$id")" 2>/dev/null || true
}

state_number() {
  local id="$1" key="$2" value
  value="$(state_read "$id" "$key")"
  if valid_counter "$value"; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

source_hash() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

source_file() {
  local identity="$1" protocol="$2" source_key="$3"
  printf '%s/%s-%s-%s.snapshot\n' "$SOURCE_DIR" "$protocol" "$identity" "$(source_hash "$source_key")"
}

source_read() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

write_state() {
  local id="$1" download="$2" upload="$3" wg_download="$4" wg_upload="$5" ovpn_download="$6" ovpn_upload="$7"
  local last_activity="$8" last_protocol="$9" last_resource="${10}" tracking_started="${11}" updated="${12}" file tmp
  file="$(state_file "$id")"
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'id=%s\n' "$id"
    printf 'download_bytes=%s\n' "$download"
    printf 'upload_bytes=%s\n' "$upload"
    printf 'wireguard_download_bytes=%s\n' "$wg_download"
    printf 'wireguard_upload_bytes=%s\n' "$wg_upload"
    printf 'openvpn_download_bytes=%s\n' "$ovpn_download"
    printf 'openvpn_upload_bytes=%s\n' "$ovpn_upload"
    printf 'last_activity_epoch=%s\n' "$last_activity"
    printf 'last_protocol=%s\n' "$last_protocol"
    printf 'last_resource=%s\n' "$last_resource"
    printf 'tracking_started_epoch=%s\n' "$tracking_started"
    printf 'updated_epoch=%s\n' "$updated"
  } > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

ensure_state() {
  local id="$1" now file
  file="$(state_file "$id")"
  [[ -f "$file" ]] && return 0
  now="$(date +%s)"
  write_state "$id" 0 0 0 0 0 0 0 "" "" "$now" "$now"
}

binding_for() {
  case "$1" in
    wireguard) identity_read "$2" wireguard_client ;;
    openvpn) identity_read "$2" openvpn_client ;;
    ssh) identity_read "$2" ssh_user ;;
    *) return 1 ;;
  esac
}

find_identity_by_binding() {
  local protocol="$1" resource="$2" file id bound
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    bound="$(binding_for "$protocol" "$id")"
    if [[ -n "$bound" && "$bound" == "$resource" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

validate_counter_binding() {
  local identity="$1" protocol="$2" resource="$3" bound
  identity_valid_id "$identity" || return 64
  identity_exists "$identity" || return 66
  valid_protocol "$protocol" || return 64
  valid_resource "$resource" || return 64
  identity_has_protocol "$identity" "$protocol" || return 67
  bound="$(binding_for "$protocol" "$identity")"
  [[ -n "$bound" && "$bound" == "$resource" ]] || return 67
}

add_usage_locked() {
  local id="$1" protocol="$2" resource="$3" upload_delta="$4" download_delta="$5" activity_epoch="$6"
  local download upload wg_download wg_upload ovpn_download ovpn_upload
  local last_activity last_protocol last_resource tracking now

  ensure_state "$id"
  download="$(state_number "$id" download_bytes)"
  upload="$(state_number "$id" upload_bytes)"
  wg_download="$(state_number "$id" wireguard_download_bytes)"
  wg_upload="$(state_number "$id" wireguard_upload_bytes)"
  ovpn_download="$(state_number "$id" openvpn_download_bytes)"
  ovpn_upload="$(state_number "$id" openvpn_upload_bytes)"
  last_activity="$(state_number "$id" last_activity_epoch)"
  last_protocol="$(state_read "$id" last_protocol)"
  last_resource="$(state_read "$id" last_resource)"
  tracking="$(state_number "$id" tracking_started_epoch)"
  now="$(date +%s)"

  download=$((download + download_delta))
  upload=$((upload + upload_delta))
  case "$protocol" in
    wireguard)
      wg_download=$((wg_download + download_delta))
      wg_upload=$((wg_upload + upload_delta))
      ;;
    openvpn)
      ovpn_download=$((ovpn_download + download_delta))
      ovpn_upload=$((ovpn_upload + upload_delta))
      ;;
  esac

  if (( activity_epoch >= last_activity )); then
    last_activity="$activity_epoch"
    last_protocol="$protocol"
    last_resource="$resource"
  fi
  (( tracking > 0 )) || tracking="$now"
  write_state "$id" "$download" "$upload" "$wg_download" "$wg_upload" "$ovpn_download" "$ovpn_upload" \
    "$last_activity" "$last_protocol" "$last_resource" "$tracking" "$now"
}

touch_activity_locked() {
  local id="$1" protocol="$2" resource="$3" activity_epoch="$4"
  local download upload wg_download wg_upload ovpn_download ovpn_upload
  local last_activity last_protocol last_resource tracking now

  identity_valid_id "$id" || return 0
  identity_exists "$id" || return 0
  valid_counter "$activity_epoch" || return 0
  ensure_state "$id"
  last_activity="$(state_number "$id" last_activity_epoch)"
  (( activity_epoch > last_activity )) || return 0

  download="$(state_number "$id" download_bytes)"
  upload="$(state_number "$id" upload_bytes)"
  wg_download="$(state_number "$id" wireguard_download_bytes)"
  wg_upload="$(state_number "$id" wireguard_upload_bytes)"
  ovpn_download="$(state_number "$id" openvpn_download_bytes)"
  ovpn_upload="$(state_number "$id" openvpn_upload_bytes)"
  last_protocol="$protocol"
  last_resource="$resource"
  tracking="$(state_number "$id" tracking_started_epoch)"
  now="$(date +%s)"
  (( tracking > 0 )) || tracking="$now"
  write_state "$id" "$download" "$upload" "$wg_download" "$wg_upload" "$ovpn_download" "$ovpn_upload" \
    "$activity_epoch" "$last_protocol" "$last_resource" "$tracking" "$now"
}

write_source_snapshot() {
  local file="$1" identity="$2" protocol="$3" resource="$4" received="$5" sent="$6" now="$7" tmp
  tmp="$(mktemp)"
  {
    printf 'version=1\n'
    printf 'identity_id=%s\n' "$identity"
    printf 'protocol=%s\n' "$protocol"
    printf 'resource=%s\n' "$resource"
    printf 'received_bytes=%s\n' "$received"
    printf 'sent_bytes=%s\n' "$sent"
    printf 'last_seen_epoch=%s\n' "$now"
  } > "$tmp"
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

ingest_counter_locked() {
  local identity="$1" protocol="$2" resource="$3" source_key="$4" received="$5" sent="$6"
  local file prev_received prev_sent upload_delta=0 download_delta=0 now baseline=0

  validate_counter_binding "$identity" "$protocol" "$resource" || return $?
  valid_source_key "$source_key" || return 64
  valid_counter "$received" || return 64
  valid_counter "$sent" || return 64
  ensure_state "$identity"
  file="$(source_file "$identity" "$protocol" "$source_key")"
  now="$(date +%s)"

  if [[ -f "$file" ]] && \
     [[ "$(source_read "$file" identity_id)" == "$identity" ]] && \
     [[ "$(source_read "$file" protocol)" == "$protocol" ]] && \
     [[ "$(source_read "$file" resource)" == "$resource" ]]; then
    prev_received="$(source_read "$file" received_bytes)"
    prev_sent="$(source_read "$file" sent_bytes)"
    valid_counter "$prev_received" || prev_received=0
    valid_counter "$prev_sent" || prev_sent=0
    if (( received >= prev_received )); then
      upload_delta=$((received - prev_received))
    else
      upload_delta="$received"
    fi
    if (( sent >= prev_sent )); then
      download_delta=$((sent - prev_sent))
    else
      download_delta="$sent"
    fi
  else
    baseline=1
  fi

  write_source_snapshot "$file" "$identity" "$protocol" "$resource" "$received" "$sent" "$now"
  if (( baseline == 0 && (upload_delta > 0 || download_delta > 0) )); then
    add_usage_locked "$identity" "$protocol" "$resource" "$upload_delta" "$download_delta" "$now"
  fi
}

collect_wireguard_locked() {
  local transfers file id client meta pub received sent
  command_exists wg || return 0
  wg show wg0 >/dev/null 2>&1 || return 0
  transfers="$(wg show wg0 transfer 2>/dev/null || true)"
  [[ -n "$transfers" ]] || return 0

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    identity_has_protocol "$id" wireguard || continue
    client="$(identity_read "$id" wireguard_client)"
    [[ -n "$client" ]] || continue
    meta="$WG_CLIENT_DIR/$client.meta"
    [[ -f "$meta" ]] || continue
    pub="$(awk -F= '$1=="public_key"{print $2; exit}' "$meta" 2>/dev/null || true)"
    [[ -n "$pub" ]] || continue
    read -r received sent < <(printf '%s\n' "$transfers" | awk -v p="$pub" '$1==p {print $2, $3; exit}')
    valid_counter "${received:-}" || continue
    valid_counter "${sent:-}" || continue
    ingest_counter_locked "$id" wireguard "$client" "peer:$pub" "$received" "$sent" || true
  done
}

openvpn_counter_rows() {
  [[ -f "$OVPN_STATUS" ]] || return 0
  awk -F, '
    $1=="CLIENT_LIST" && $2!="Common Name" {
      since=$9
      if (since=="" || since !~ /^[0-9]+$/) since=$8
      printf "%s\t%s\t%s\t%s\t%s\n", $2, $3, $6, $7, since
      next
    }
    $0=="ROUTING TABLE" {legacy=0}
    $0=="Common Name,Real Address,Bytes Received,Bytes Sent,Connected Since" {legacy=1; next}
    legacy && NF>=5 {
      printf "%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5
    }
  ' "$OVPN_STATUS" 2>/dev/null
}

collect_openvpn_locked() {
  local client remote received sent since identity source_key
  while IFS=$'\t' read -r client remote received sent since; do
    valid_resource "$client" || continue
    valid_counter "$received" || continue
    valid_counter "$sent" || continue
    identity="$(find_identity_by_binding openvpn "$client" 2>/dev/null || true)"
    [[ -n "$identity" ]] || continue
    source_key="$client|$remote|$since"
    ingest_counter_locked "$identity" openvpn "$client" "$source_key" "$received" "$sent" || true
  done < <(openvpn_counter_rows)
}

collect_session_activity_locked() {
  local line identity session protocol resource heartbeat field
  local -a fields=()

  [[ -x "$SESSION_ENGINE" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r -a fields <<< "$line"
    identity="${fields[0]:-}"
    session="${fields[1]:-}"
    [[ -n "$identity" && -n "$session" ]] || continue

    protocol=""
    resource=""
    heartbeat=""
    for field in "${fields[@]:2}"; do
      case "$field" in
        protocol=*) protocol="${field#protocol=}" ;;
        resource=*) resource="${field#resource=}" ;;
        heartbeat=*) heartbeat="${field#heartbeat=}" ;;
      esac
    done

    case "$protocol" in ssh|wireguard|openvpn) ;; *) continue ;; esac
    valid_resource "$resource" || continue
    valid_counter "$heartbeat" || continue
    touch_activity_locked "$identity" "$protocol" "$resource" "$heartbeat"
  done < <("$SESSION_ENGINE" --list 2>/dev/null || true)
}

ensure_identity_states_locked() {
  local file id
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    ensure_state "$id"
  done
}

cleanup_sources_locked() {
  find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.snapshot' -mtime +30 -delete 2>/dev/null || true
}

collect_locked() {
  usage_init
  ensure_identity_states_locked
  collect_wireguard_locked
  collect_openvpn_locked
  collect_session_activity_locked
  cleanup_sources_locked
}

refresh_lease_cache() {
  if [[ -x "$SESSION_ENGINE" ]]; then
    LEASE_CACHE="$("$SESSION_ENGINE" --list 2>/dev/null || true)"
  else
    LEASE_CACHE=""
  fi
}

lease_summary() {
  local id="$1"
  printf '%s\n' "$LEASE_CACHE" | awk -F'\t' -v wanted="$id" '
    $1==wanted {
      c++
      for (i=3; i<=NF; i++) {
        if ($i=="protocol=ssh") ssh=1
        else if ($i=="protocol=wireguard") wg=1
        else if ($i=="protocol=openvpn") ovpn=1
      }
    }
    END {
      p=""
      if (ssh) p="ssh"
      if (wg) p=(p==""?"wireguard":p ",wireguard")
      if (ovpn) p=(p==""?"openvpn":p ",openvpn")
      printf "%d\t%s\n", c+0, p
    }
  '
}

traffic_complete() {
  local id="$1" ssh_user
  ssh_user="$(identity_read "$id" ssh_user)"
  if identity_has_protocol "$id" ssh && [[ -n "$ssh_user" ]]; then
    printf '0\n'
  else
    printf '1\n'
  fi
}

show_machine_locked() {
  local id="$1" sessions active max download upload total last_activity last_protocol last_resource updated complete
  identity_valid_id "$id" || return 64
  identity_exists "$id" || return 66
  ensure_state "$id"
  refresh_lease_cache
  read -r sessions active < <(lease_summary "$id")
  max="$(identity_read "$id" max_sessions)"
  download="$(state_number "$id" download_bytes)"
  upload="$(state_number "$id" upload_bytes)"
  total=$((download + upload))
  last_activity="$(state_number "$id" last_activity_epoch)"
  last_protocol="$(state_read "$id" last_protocol)"
  last_resource="$(state_read "$id" last_resource)"
  updated="$(state_number "$id" updated_epoch)"
  complete="$(traffic_complete "$id")"

  printf 'id=%s\n' "$id"
  printf 'state=%s\n' "$(identity_effective_state "$id")"
  printf 'sessions=%s\n' "$sessions"
  printf 'max_sessions=%s\n' "$max"
  printf 'active_protocols=%s\n' "$active"
  printf 'download_bytes=%s\n' "$download"
  printf 'upload_bytes=%s\n' "$upload"
  printf 'total_bytes=%s\n' "$total"
  printf 'wireguard_download_bytes=%s\n' "$(state_number "$id" wireguard_download_bytes)"
  printf 'wireguard_upload_bytes=%s\n' "$(state_number "$id" wireguard_upload_bytes)"
  printf 'openvpn_download_bytes=%s\n' "$(state_number "$id" openvpn_download_bytes)"
  printf 'openvpn_upload_bytes=%s\n' "$(state_number "$id" openvpn_upload_bytes)"
  printf 'traffic_complete=%s\n' "$complete"
  printf 'metered_protocols=wireguard,openvpn\n'
  printf 'ssh_bytes_supported=0\n'
  printf 'last_activity_epoch=%s\n' "$last_activity"
  printf 'last_protocol=%s\n' "$last_protocol"
  printf 'last_resource=%s\n' "$last_resource"
  printf 'tracking_started_epoch=%s\n' "$(state_number "$id" tracking_started_epoch)"
  printf 'updated_epoch=%s\n' "$updated"
}

list_machine_locked() {
  local file id sessions active download upload total last_activity complete
  refresh_lease_cache
  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    id="${file##*/}"
    id="${id%.conf}"
    ensure_state "$id"
    read -r sessions active < <(lease_summary "$id")
    download="$(state_number "$id" download_bytes)"
    upload="$(state_number "$id" upload_bytes)"
    total=$((download + upload))
    last_activity="$(state_number "$id" last_activity_epoch)"
    complete="$(traffic_complete "$id")"
    printf '%s\t%s\tsessions=%s/%s\tactive=%s\tdownload=%s\tupload=%s\ttotal=%s\tcomplete=%s\tlast=%s\n' \
      "$id" "$(identity_effective_state "$id")" "$sessions" "$(identity_read "$id" max_sessions)" "${active:--}" \
      "$download" "$upload" "$total" "$complete" "$last_activity"
  done
}

format_bytes() {
  local value="${1:-0}"
  valid_counter "$value" || value=0
  numfmt --to=iec-i --suffix=B "$value" 2>/dev/null || printf '%s B\n' "$value"
}

format_epoch() {
  local value="${1:-0}"
  if valid_counter "$value" && (( value > 0 )); then
    date -d "@$value" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s\n' "$value"
  else
    printf 'nunca\n'
  fi
}

table_locked() {
  local file id sessions active download upload total last_activity complete found=0
  refresh_lease_cache
  printf '%-18s %-10s %-10s %-22s %12s %12s %12s %-8s %-19s\n' \
    "IDENTIDADE" "ESTADO" "SESSÕES" "ATIVO" "DOWNLOAD" "UPLOAD" "TOTAL" "MEDIÇÃO" "ÚLTIMA ATIVIDADE"

  for file in "$IDENTITY_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    found=1
    id="${file##*/}"
    id="${id%.conf}"
    ensure_state "$id"
    read -r sessions active < <(lease_summary "$id")
    download="$(state_number "$id" download_bytes)"
    upload="$(state_number "$id" upload_bytes)"
    total=$((download + upload))
    last_activity="$(state_number "$id" last_activity_epoch)"
    complete="$(traffic_complete "$id")"
    if [[ "$complete" == 1 ]]; then
      complete="completa"
    else
      complete="parcial"
    fi
    printf '%-18s %-10s %-10s %-22s %12s %12s %12s %-8s %-19s\n' \
      "$id" "$(identity_effective_state "$id")" "$sessions/$(identity_read "$id" max_sessions)" "${active:--}" \
      "$(format_bytes "$download")" "$(format_bytes "$upload")" "$(format_bytes "$total")" "$complete" "$(format_epoch "$last_activity")"
  done
  (( found == 1 )) || info "Nenhuma identidade criada"
}

show_human_locked() {
  local id="$1" sessions active download upload total complete last_activity last_protocol last_resource
  identity_valid_id "$id" || { err "ID inválido"; return 64; }
  identity_exists "$id" || { err "Identidade não existe: $id"; return 66; }
  ensure_state "$id"
  refresh_lease_cache
  read -r sessions active < <(lease_summary "$id")
  download="$(state_number "$id" download_bytes)"
  upload="$(state_number "$id" upload_bytes)"
  total=$((download + upload))
  complete="$(traffic_complete "$id")"
  last_activity="$(state_number "$id" last_activity_epoch)"
  last_protocol="$(state_read "$id" last_protocol)"
  last_resource="$(state_read "$id" last_resource)"

  printf 'Identidade:          %s\n' "$id"
  printf 'Estado:              %s\n' "$(identity_effective_state "$id")"
  printf 'Sessões:             %s/%s\n' "$sessions" "$(identity_read "$id" max_sessions)"
  printf 'Protocolos ativos:   %s\n' "${active:--}"
  printf 'Download medido:     %s\n' "$(format_bytes "$download")"
  printf 'Upload medido:       %s\n' "$(format_bytes "$upload")"
  printf 'Total medido:        %s\n' "$(format_bytes "$total")"
  printf 'WireGuard download:  %s\n' "$(format_bytes "$(state_number "$id" wireguard_download_bytes)")"
  printf 'WireGuard upload:    %s\n' "$(format_bytes "$(state_number "$id" wireguard_upload_bytes)")"
  printf 'OpenVPN download:    %s\n' "$(format_bytes "$(state_number "$id" openvpn_download_bytes)")"
  printf 'OpenVPN upload:      %s\n' "$(format_bytes "$(state_number "$id" openvpn_upload_bytes)")"
  printf 'Última atividade:    %s\n' "$(format_epoch "$last_activity")"
  printf 'Último protocolo:    %s\n' "${last_protocol:--}"
  printf 'Último recurso:      %s\n' "${last_resource:--}"
  if [[ "$complete" == 1 ]]; then
    printf 'Cobertura de bytes:  completa para os protocolos vinculados medidos\n'
  else
    printf 'Cobertura de bytes:  parcial (SSH registra sessão/atividade, não bytes)\n'
  fi
}

install_units() {
  usage_init
  cat > "$USAGE_SERVICE" <<EOF
[Unit]
Description=MANAGER identity traffic and activity collector
After=network-online.target manager-session-cleanup.service manager-protocol-leases.service

[Service]
Type=oneshot
ExecStart=$MANAGER_HOME/modules/identity_usage.sh --collect
Nice=10
EOF

  cat > "$USAGE_TIMER" <<'EOF'
[Unit]
Description=MANAGER periodic identity traffic accounting

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=3s
Persistent=true
Unit=manager-identity-usage.service

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "$USAGE_SERVICE" "$USAGE_TIMER"
  systemctl daemon-reload
  systemctl enable --now manager-identity-usage.timer >/dev/null 2>&1 || true
  collect_locked
}

detach_units() {
  systemctl disable --now manager-identity-usage.timer >/dev/null 2>&1 || true
  rm -f "$USAGE_SERVICE" "$USAGE_TIMER"
  systemctl daemon-reload || true
}

interactive_menu() {
  local opt id
  while true; do
    header
    say "${C_WHITE}USO POR IDENTIDADE${C_RESET}\n"
    say " 1) Resumo de todas as identidades"
    say " 2) Detalhes de uma identidade"
    say " 3) Coletar agora"
    say " 0) Voltar"
    say ""
    read -r -p "Opção: " opt
    case "$opt" in
      1) header; ( flock -x 9; collect_locked; table_locked ) 9>"$USAGE_LOCK"; pause ;;
      2)
        read -r -p "Identidade: " id
        header
        ( flock -x 9; collect_locked; show_human_locked "$id" ) 9>"$USAGE_LOCK" || true
        pause
        ;;
      3) ( flock -x 9; collect_locked ) 9>"$USAGE_LOCK"; ok "Coleta concluída"; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

usage_init
case "${1:-}" in
  --init) printf '%s\n' "$USAGE_ROOT" ;;
  --install) ( flock -x 9; install_units ) 9>"$USAGE_LOCK" ;;
  --detach) ( flock -x 9; detach_units ) 9>"$USAGE_LOCK" ;;
  --collect) ( flock -x 9; collect_locked ) 9>"$USAGE_LOCK" ;;
  --list) ( flock -x 9; collect_locked; list_machine_locked ) 9>"$USAGE_LOCK" ;;
  --table) ( flock -x 9; collect_locked; table_locked ) 9>"$USAGE_LOCK" ;;
  --show)
    [[ -n "${2:-}" ]] || exit 64
    ( flock -x 9; collect_locked; show_machine_locked "$2" ) 9>"$USAGE_LOCK"
    ;;
  --show-human)
    [[ -n "${2:-}" ]] || exit 64
    ( flock -x 9; collect_locked; show_human_locked "$2" ) 9>"$USAGE_LOCK"
    ;;
  --ingest-counter)
    [[ -n "${2:-}" && -n "${3:-}" && -n "${4:-}" && -n "${5:-}" && -n "${6:-}" && -n "${7:-}" ]] || exit 64
    ( flock -x 9; ingest_counter_locked "$2" "$3" "$4" "$5" "$6" "$7" ) 9>"$USAGE_LOCK"
    ;;
  "") interactive_menu ;;
  *)
    err "Uso: identity_usage.sh --list|--show ID|--collect|--ingest-counter ID PROTOCOLO RECURSO SOURCE RECEIVED SENT"
    exit 64
    ;;
esac
