#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

PROXY_DIR="$MANAGER_ETC/proxy"
HOSTS_FILE="$PROXY_DIR/hosts.txt"
SQUID_STATE="$PROXY_DIR/squid.state"
SQUID_CONF="$PROXY_DIR/squid.conf"
TCP_DIR="$PROXY_DIR/tcp"
WS_DIR="$PROXY_DIR/websocket"
TLS_DIR="$PROXY_DIR/tls"
SYSTEMD_DIR="/etc/systemd/system"

init_proxy_state() {
  mkdir -p "$PROXY_DIR" "$TCP_DIR" "$WS_DIR" "$TLS_DIR"
  chmod 0700 "$PROXY_DIR" "$TCP_DIR" "$WS_DIR" "$TLS_DIR"
  touch "$HOSTS_FILE"
  chmod 0600 "$HOSTS_FILE"
}

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

write_kv_file() {
  local file="$1"
  shift
  local tmp pair
  tmp="$(mktemp)"
  for pair in "$@"; do
    printf '%s\n' "$pair" >> "$tmp"
  done
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

port_is_listening() {
  local port="$1"
  ss -Hlnpt "sport = :$port" 2>/dev/null | grep -q .
}

validate_local_target() {
  local port="$1"
  is_valid_port "$port" || return 1
  if ! port_is_listening "$port"; then
    warn "A porta local $port não está em escuta agora. O túnel será criado, mas só funcionará quando o serviço de destino estiver ativo."
  fi
}

warn_firewall() {
  local port="$1"
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "UFW está ativo. Se este serviço precisar acesso externo, libere conscientemente TCP/$port no módulo Firewall."
  fi
}

ensure_new_listen_port() {
  local port="$1" state_file="$2"
  is_valid_port "$port" || { err "Porta inválida"; return 1; }
  [[ ! -e "$state_file" ]] || { err "Já existe um serviço MANAGER registrado na porta $port"; return 1; }
  if port_is_listening "$port"; then
    err "A porta TCP $port já está em uso"
    return 1
  fi
}

install_pkg() {
  local pkg="$1"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$pkg"
}

unit_hardening() {
  cat <<'EOF'
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
EOF
}

write_tcp_unit() {
  local listen="$1" target="$2" unit="$SYSTEMD_DIR/manager-tcp-proxy-$listen.service"
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER TCP proxy $listen -> 127.0.0.1:$target
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/socat TCP-LISTEN:$listen,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:$target
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
$(unit_hardening)

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

write_ws_unit() {
  local listen="$1" target="$2" bin unit
  bin="$(command -v websockify || true)"
  [[ -n "$bin" ]] || return 1
  unit="$SYSTEMD_DIR/manager-ws-proxy-$listen.service"
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER WebSocket tunnel $listen -> 127.0.0.1:$target
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=$bin --heartbeat=30 0.0.0.0:$listen 127.0.0.1:$target
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
$(unit_hardening)

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

write_tls_unit() {
  local listen="$1" target="$2" pem="$3" bin conf unit
  bin="$(command -v stunnel4 || command -v stunnel || true)"
  [[ -n "$bin" ]] || return 1
  conf="$TLS_DIR/$listen.stunnel.conf"
  unit="$SYSTEMD_DIR/manager-tls-proxy-$listen.service"
  cat > "$conf" <<EOF
foreground = yes
pid =
setuid = nobody
setgid = nogroup
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[manager]
accept = 0.0.0.0:$listen
connect = 127.0.0.1:$target
cert = $pem
EOF
  chmod 0600 "$conf"
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER TLS tunnel $listen -> 127.0.0.1:$target
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin $conf
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictNamespaces=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE SETUID SETGID

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

generate_tls_pem() {
  local pem="$1" key cert cn
  command_exists openssl || install_pkg openssl
  key="$(mktemp)"
  cert="$(mktemp)"
  cn="$(hostname -f 2>/dev/null || hostname)"
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=$cn" -keyout "$key" -out "$cert" >/dev/null 2>&1
  cat "$key" "$cert" > "$pem"
  chmod 0600 "$pem"
  rm -f "$key" "$cert"
}

squid_restrict_value() {
  local value
  value="$(read_field "$SQUID_STATE" restrict_hosts)"
  [[ "$value" == 1 ]] && printf '1\n' || printf '0\n'
}

write_squid_config() {
  local port restrict
  [[ -f "$SQUID_STATE" ]] || return 1
  port="$(read_field "$SQUID_STATE" port)"
  restrict="$(squid_restrict_value)"
  is_valid_port "$port" || return 1
  init_proxy_state

  {
    printf 'http_port %s\n' "$port"
    printf 'pid_filename /run/manager-squid.pid\n'
    printf 'visible_hostname MANAGER\n'
    printf 'via off\n'
    printf 'forwarded_for delete\n'
    printf 'cache deny all\n'
    printf 'access_log none\n'
    printf 'cache_log /dev/null\n'
    printf 'acl manager_clients src 127.0.0.1/32\n'
    printf 'acl manager_clients src 10.0.0.0/8\n'
    printf 'acl manager_clients src 172.16.0.0/12\n'
    printf 'acl manager_clients src 192.168.0.0/16\n'
    printf 'acl manager_safe_ports port 80\n'
    printf 'acl manager_safe_ports port 443\n'
    printf 'http_access deny !manager_safe_ports\n'
    if [[ "$restrict" == 1 ]]; then
      printf 'acl manager_hosts dstdomain "%s"\n' "$HOSTS_FILE"
      printf 'http_access allow manager_clients manager_hosts\n'
    else
      printf 'http_access allow manager_clients\n'
    fi
    printf 'http_access deny all\n'
  } > "$SQUID_CONF"
  chmod 0600 "$SQUID_CONF"
}

write_squid_unit() {
  local bin unit="$SYSTEMD_DIR/manager-squid.service"
  bin="$(command -v squid || true)"
  [[ -n "$bin" ]] || return 1
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER private Squid proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin -N -f $SQUID_CONF
ExecReload=$bin -k reconfigure -f $SQUID_CONF
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

validate_squid_config() {
  command_exists squid || return 1
  squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1
}

reload_squid_machine() {
  [[ -f "$SQUID_STATE" ]] || return 0
  command_exists squid || return 0
  write_squid_config || return 1
  validate_squid_config || return 1
  write_squid_unit || return 1
  systemctl daemon-reload
  if systemctl is-active --quiet manager-squid.service; then
    systemctl reload manager-squid.service 2>/dev/null || systemctl restart manager-squid.service
  fi
}

setup_squid() {
  header
  say "${C_WHITE}SQUID PRIVADO DO MANAGER${C_RESET}\n"
  init_proxy_state
  local port restrict answer
  read -r -p "Porta TCP [3128]: " port
  port="${port:-3128}"
  ensure_new_listen_port "$port" "$SQUID_STATE" || { pause; return; }
  read -r -p "Restringir também aos hosts cadastrados? [s/N]: " answer
  if [[ "$answer" =~ ^([sS]|[yY])$ ]]; then restrict=1; else restrict=0; fi

  command_exists squid || install_pkg squid
  write_kv_file "$SQUID_STATE" "port=$port" "restrict_hosts=$restrict"
  write_squid_config
  if ! validate_squid_config; then
    rm -f "$SQUID_STATE" "$SQUID_CONF"
    err "O Squid recusou a configuração; nada foi ativado."
    pause
    return
  fi
  write_squid_unit
  systemctl daemon-reload
  systemctl enable --now manager-squid.service
  ok "Squid privado ativo na porta $port"
  info "Por padrão somente localhost e redes privadas RFC1918 podem usar este proxy."
  [[ "$restrict" == 1 ]] && info "A lista de hosts também está sendo aplicada."
  warn_firewall "$port"
  pause
}

setup_tcp() {
  header
  say "${C_WHITE}PROXY TCP${C_RESET}\n"
  init_proxy_state
  local listen target state
  read -r -p "Porta pública de escuta: " listen
  state="$TCP_DIR/$listen.conf"
  ensure_new_listen_port "$listen" "$state" || { pause; return; }
  read -r -p "Porta local de destino (ex.: 22): " target
  validate_local_target "$target" || { err "Porta de destino inválida"; pause; return; }
  command_exists socat || install_pkg socat
  write_kv_file "$state" "listen_port=$listen" "target_port=$target"
  write_tcp_unit "$listen" "$target"
  systemctl daemon-reload
  systemctl enable --now "manager-tcp-proxy-$listen.service"
  ok "TCP $listen -> 127.0.0.1:$target ativo"
  warn_firewall "$listen"
  pause
}

setup_websocket() {
  header
  say "${C_WHITE}TÚNEL WEBSOCKET${C_RESET}\n"
  init_proxy_state
  local listen target state
  read -r -p "Porta pública WebSocket: " listen
  state="$WS_DIR/$listen.conf"
  ensure_new_listen_port "$listen" "$state" || { pause; return; }
  read -r -p "Porta TCP local de destino: " target
  validate_local_target "$target" || { err "Porta de destino inválida"; pause; return; }
  if ! command_exists websockify; then
    if ! apt-cache show websockify >/dev/null 2>&1; then
      err "O pacote websockify não está disponível nos repositórios desta distribuição."
      pause
      return
    fi
    install_pkg websockify
  fi
  write_kv_file "$state" "listen_port=$listen" "target_port=$target"
  write_ws_unit "$listen" "$target"
  systemctl daemon-reload
  systemctl enable --now "manager-ws-proxy-$listen.service"
  ok "WebSocket $listen -> 127.0.0.1:$target ativo"
  warn_firewall "$listen"
  pause
}

setup_tls() {
  header
  say "${C_WHITE}TÚNEL TLS${C_RESET}\n"
  init_proxy_state
  local listen target state pem
  read -r -p "Porta pública TLS: " listen
  state="$TLS_DIR/$listen.state"
  ensure_new_listen_port "$listen" "$state" || { pause; return; }
  read -r -p "Porta TCP local de destino: " target
  validate_local_target "$target" || { err "Porta de destino inválida"; pause; return; }
  if ! command_exists stunnel4 && ! command_exists stunnel; then
    install_pkg stunnel4
  fi
  pem="$TLS_DIR/$listen.pem"
  generate_tls_pem "$pem"
  write_kv_file "$state" "listen_port=$listen" "target_port=$target" "pem=$pem"
  write_tls_unit "$listen" "$target" "$pem"
  systemctl daemon-reload
  systemctl enable --now "manager-tls-proxy-$listen.service"
  ok "TLS $listen -> 127.0.0.1:$target ativo"
  warn "Foi gerado certificado autoassinado. Para produção pública, substitua por certificado confiável em uma etapa futura/TLS do MANAGER."
  warn_firewall "$listen"
  pause
}

print_state_dir() {
  local label="$1" dir="$2" file listen target unit state
  for file in "$dir"/*.conf "$dir"/*.state; do
    [[ -f "$file" ]] || continue
    listen="$(read_field "$file" listen_port)"
    target="$(read_field "$file" target_port)"
    case "$label" in
      TCP) unit="manager-tcp-proxy-$listen.service" ;;
      WS) unit="manager-ws-proxy-$listen.service" ;;
      TLS) unit="manager-tls-proxy-$listen.service" ;;
      *) continue ;;
    esac
    if systemctl is-active --quiet "$unit" 2>/dev/null; then state="ativo"; else state="inativo"; fi
    printf '%-8s %-8s %-8s %-10s\n' "$label" "$listen" "$target" "$state"
  done
}

status_machine() {
  init_proxy_state
  local port restrict state
  if [[ -f "$SQUID_STATE" ]]; then
    port="$(read_field "$SQUID_STATE" port)"
    restrict="$(squid_restrict_value)"
    if systemctl is-active --quiet manager-squid.service 2>/dev/null; then state="ativo"; else state="inativo"; fi
    printf 'SQUID port=%s restrict_hosts=%s state=%s\n' "$port" "$restrict" "$state"
  fi
  while IFS= read -r line; do [[ -n "$line" ]] && printf '%s\n' "$line"; done < <(status_lines)
}

status_lines() {
  print_state_dir TCP "$TCP_DIR"
  print_state_dir WS "$WS_DIR"
  print_state_dir TLS "$TLS_DIR"
}

show_status() {
  header
  say "${C_WHITE}PROXIES E TÚNEIS${C_RESET}\n"
  init_proxy_state
  local port restrict state
  printf '%-8s %-8s %-8s %-10s\n' "TIPO" "PORTA" "DESTINO" "ESTADO"
  printf '%-8s %-8s %-8s %-10s\n' "--------" "--------" "--------" "----------"
  if [[ -f "$SQUID_STATE" ]]; then
    port="$(read_field "$SQUID_STATE" port)"
    restrict="$(squid_restrict_value)"
    if systemctl is-active --quiet manager-squid.service 2>/dev/null; then state="ativo"; else state="inativo"; fi
    printf '%-8s %-8s %-8s %-10s\n' "SQUID" "$port" "hosts:$restrict" "$state"
  fi
  status_lines
  pause
}

remove_service() {
  header
  local kind listen state unit extra
  read -r -p "Tipo [tcp/ws/tls/squid]: " kind
  kind="${kind,,}"
  case "$kind" in
    squid)
      [[ -f "$SQUID_STATE" ]] || { info "Squid MANAGER não configurado"; pause; return; }
      confirm "Desativar e remover somente a configuração Squid do MANAGER?" || { pause; return; }
      systemctl disable --now manager-squid.service >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/manager-squid.service" "$SQUID_STATE" "$SQUID_CONF"
      systemctl daemon-reload
      ok "Squid MANAGER removido; o pacote do sistema foi preservado"
      ;;
    tcp|ws|tls)
      read -r -p "Porta de escuta: " listen
      is_valid_port "$listen" || { err "Porta inválida"; pause; return; }
      case "$kind" in
        tcp) state="$TCP_DIR/$listen.conf"; unit="manager-tcp-proxy-$listen.service" ;;
        ws) state="$WS_DIR/$listen.conf"; unit="manager-ws-proxy-$listen.service" ;;
        tls) state="$TLS_DIR/$listen.state"; unit="manager-tls-proxy-$listen.service"; extra="$TLS_DIR/$listen.pem $TLS_DIR/$listen.stunnel.conf" ;;
      esac
      [[ -f "$state" ]] || { err "Serviço não registrado"; pause; return; }
      confirm "Remover $kind na porta $listen?" || { pause; return; }
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      rm -f "$SYSTEMD_DIR/$unit" "$state"
      if [[ -n "${extra:-}" ]]; then
        rm -f $extra
      fi
      systemctl daemon-reload
      ok "Serviço removido"
      ;;
    *) err "Tipo inválido" ;;
  esac
  pause
}

reconcile_machine() {
  init_proxy_state
  local file listen target pem
  if [[ -f "$SQUID_STATE" ]] && command_exists squid; then
    write_squid_config && validate_squid_config && write_squid_unit || true
  fi
  if command_exists socat; then
    for file in "$TCP_DIR"/*.conf; do
      [[ -f "$file" ]] || continue
      listen="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"
      is_valid_port "$listen" && is_valid_port "$target" && write_tcp_unit "$listen" "$target"
    done
  fi
  if command_exists websockify; then
    for file in "$WS_DIR"/*.conf; do
      [[ -f "$file" ]] || continue
      listen="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"
      is_valid_port "$listen" && is_valid_port "$target" && write_ws_unit "$listen" "$target"
    done
  fi
  if command_exists stunnel4 || command_exists stunnel; then
    for file in "$TLS_DIR"/*.state; do
      [[ -f "$file" ]] || continue
      listen="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"; pem="$(read_field "$file" pem)"
      is_valid_port "$listen" && is_valid_port "$target" && [[ "$pem" == "$TLS_DIR/"*.pem && -f "$pem" ]] && write_tls_unit "$listen" "$target" "$pem"
    done
  fi
  systemctl daemon-reload
}

init_proxy_state
case "${1:-}" in
  --init) exit 0 ;;
  --status) status_machine; exit 0 ;;
  --reload-squid) reload_squid_machine; exit $? ;;
  --reconcile) reconcile_machine; exit 0 ;;
  "") ;;
  *) err "Ação inválida: $1"; exit 64 ;;
esac

while true; do
  header
  say "${C_WHITE}PROXIES E TÚNEIS${C_RESET}\n"
  say " 1) Status"
  say " 2) Configurar Squid privado"
  say " 3) Criar proxy TCP para serviço local"
  say " 4) Criar túnel WebSocket para serviço local"
  say " 5) Criar túnel TLS para serviço local"
  say " 6) Remover serviço gerenciado"
  say " 7) Reconciliar unidades systemd"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_status ;;
    2) setup_squid ;;
    3) setup_tcp ;;
    4) setup_websocket ;;
    5) setup_tls ;;
    6) remove_service ;;
    7) reconcile_machine; ok "Unidades reconciliadas"; pause ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
