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

init_state() {
  mkdir -p "$PROXY_DIR" "$TCP_DIR" "$WS_DIR" "$TLS_DIR"
  chmod 0700 "$PROXY_DIR" "$TCP_DIR" "$WS_DIR" "$TLS_DIR"
  touch "$HOSTS_FILE"
  chmod 0600 "$HOSTS_FILE"
}

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

write_state() {
  local file="$1"
  shift
  local tmp pair
  tmp="$(mktemp)"
  for pair in "$@"; do printf '%s\n' "$pair" >> "$tmp"; done
  install -m 0600 "$tmp" "$file"
  rm -f "$tmp"
}

port_listening() {
  local port="$1"
  ss -Hlnpt "sport = :$port" 2>/dev/null | grep -q .
}

validate_target() {
  local port="$1"
  is_valid_port "$port" || return 1
  if ! port_listening "$port"; then
    warn "A porta local $port não está em escuta agora; o túnel só funcionará quando o destino estiver ativo."
  fi
}

ensure_free_port() {
  local port="$1" state="$2"
  is_valid_port "$port" || { err "Porta inválida"; return 1; }
  [[ ! -e "$state" ]] || { err "Já existe serviço MANAGER registrado na porta $port"; return 1; }
  port_listening "$port" && { err "A porta TCP $port já está em uso"; return 1; }
  return 0
}

install_pkg() {
  local pkg="$1"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$pkg"
}

warn_firewall() {
  local port="$1"
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "UFW ativo: libere TCP/$port pelo módulo Firewall somente se este serviço precisar acesso externo."
  fi
}

write_tcp_unit() {
  local listen="$1" target="$2" unit
  unit="$SYSTEMD_DIR/manager-tcp-proxy-$listen.service"
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER TCP proxy $listen -> 127.0.0.1:$target
After=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/socat TCP-LISTEN:$listen,bind=0.0.0.0,reuseaddr,fork TCP:127.0.0.1:$target
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=$bin --heartbeat=30 0.0.0.0:$listen 127.0.0.1:$target
Restart=on-failure
RestartSec=2
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

generate_pem() {
  local pem="$1" key cert cn
  command_exists openssl || install_pkg openssl
  key="$(mktemp)"; cert="$(mktemp)"
  cn="$(hostname -f 2>/dev/null || hostname)"
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=$cn" -keyout "$key" -out "$cert" >/dev/null 2>&1
  cat "$key" "$cert" > "$pem"
  chmod 0600 "$pem"
  rm -f "$key" "$cert"
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
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_SETUID CAP_SETGID

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit"
}

write_squid_conf() {
  local port restrict
  [[ -f "$SQUID_STATE" ]] || return 1
  port="$(read_field "$SQUID_STATE" port)"
  restrict="$(read_field "$SQUID_STATE" restrict_hosts)"
  is_valid_port "$port" || return 1
  [[ "$restrict" == 1 ]] || restrict=0
  {
    printf 'http_port %s\n' "$port"
    printf 'pid_filename /run/manager-squid.pid\n'
    printf 'visible_hostname MANAGER\nvia off\nforwarded_for delete\n'
    printf 'cache deny all\naccess_log none\ncache_log /dev/null\n'
    printf 'acl manager_clients src 127.0.0.1/32\n'
    printf 'acl manager_clients src 10.0.0.0/8\n'
    printf 'acl manager_clients src 172.16.0.0/12\n'
    printf 'acl manager_clients src 192.168.0.0/16\n'
    printf 'acl manager_safe_ports port 80\nacl manager_safe_ports port 443\n'
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
  local bin unit
  bin="$(command -v squid || true)"
  [[ -n "$bin" ]] || return 1
  unit="$SYSTEMD_DIR/manager-squid.service"
  cat > "$unit" <<EOF
[Unit]
Description=MANAGER private Squid proxy
After=network-online.target

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

reload_squid() {
  [[ -f "$SQUID_STATE" ]] || return 0
  command_exists squid || return 0
  write_squid_conf || return 1
  squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1 || return 1
  write_squid_unit || return 1
  systemctl daemon-reload
  if systemctl is-active --quiet manager-squid.service; then
    systemctl reload manager-squid.service 2>/dev/null || systemctl restart manager-squid.service
  fi
}

setup_squid() {
  header
  local port answer restrict=0
  read -r -p "Porta do Squid privado [3128]: " port
  port="${port:-3128}"
  ensure_free_port "$port" "$SQUID_STATE" || { pause; return; }
  read -r -p "Restringir também aos hosts cadastrados? [s/N]: " answer
  [[ "$answer" =~ ^([sS]|[yY])$ ]] && restrict=1
  command_exists squid || install_pkg squid
  write_state "$SQUID_STATE" "port=$port" "restrict_hosts=$restrict"
  write_squid_conf
  if ! squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1; then
    rm -f "$SQUID_STATE" "$SQUID_CONF"
    err "Configuração Squid recusada; ativação revertida"
    pause
    return
  fi
  write_squid_unit
  systemctl daemon-reload
  systemctl enable --now manager-squid.service
  ok "Squid ativo na porta $port"
  info "Acesso permitido somente de localhost e redes privadas RFC1918."
  [[ "$restrict" == 1 ]] && info "Restrição adicional por hosts ativada."
  warn_firewall "$port"
  pause
}

setup_stream() {
  local kind="$1" label="$2" dir="$3" package="$4"
  header
  local listen target state pem=""
  read -r -p "Porta pública de escuta: " listen
  state="$dir/$listen.conf"
  [[ "$kind" == tls ]] && state="$dir/$listen.state"
  ensure_free_port "$listen" "$state" || { pause; return; }
  read -r -p "Porta TCP local de destino (127.0.0.1): " target
  validate_target "$target" || { err "Destino inválido"; pause; return; }

  case "$kind" in
    tcp)
      command_exists socat || install_pkg "$package"
      write_state "$state" "listen_port=$listen" "target_port=$target"
      write_tcp_unit "$listen" "$target"
      ;;
    ws)
      if ! command_exists websockify; then
        apt-cache show "$package" >/dev/null 2>&1 || { err "Pacote $package indisponível"; pause; return; }
        install_pkg "$package"
      fi
      write_state "$state" "listen_port=$listen" "target_port=$target"
      write_ws_unit "$listen" "$target"
      ;;
    tls)
      if ! command_exists stunnel4 && ! command_exists stunnel; then install_pkg "$package"; fi
      pem="$TLS_DIR/$listen.pem"
      generate_pem "$pem"
      write_state "$state" "listen_port=$listen" "target_port=$target" "pem=$pem"
      write_tls_unit "$listen" "$target" "$pem"
      ;;
  esac

  systemctl daemon-reload
  systemctl enable --now "manager-$kind-proxy-$listen.service"
  ok "$label $listen -> 127.0.0.1:$target ativo"
  [[ "$kind" == tls ]] && warn "Certificado autoassinado gerado; produção pública deve usar certificado confiável."
  warn_firewall "$listen"
  pause
}

unit_for() {
  local kind="$1" port="$2"
  case "$kind" in
    tcp) printf 'manager-tcp-proxy-%s.service\n' "$port" ;;
    ws) printf 'manager-ws-proxy-%s.service\n' "$port" ;;
    tls) printf 'manager-tls-proxy-%s.service\n' "$port" ;;
  esac
}

print_dir() {
  local kind="$1" label="$2" dir="$3" file port target unit state
  for file in "$dir"/*.conf "$dir"/*.state; do
    [[ -f "$file" ]] || continue
    [[ "$file" == *.stunnel.conf ]] && continue
    port="$(read_field "$file" listen_port)"
    target="$(read_field "$file" target_port)"
    unit="$(unit_for "$kind" "$port")"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then state=ativo; else state=inativo; fi
    printf '%-8s %-8s %-12s %-10s\n' "$label" "$port" "127.0.0.1:$target" "$state"
  done
}

status_output() {
  local port restrict state
  if [[ -f "$SQUID_STATE" ]]; then
    port="$(read_field "$SQUID_STATE" port)"
    restrict="$(read_field "$SQUID_STATE" restrict_hosts)"
    if systemctl is-active --quiet manager-squid.service 2>/dev/null; then state=ativo; else state=inativo; fi
    printf '%-8s %-8s %-12s %-10s\n' SQUID "$port" "hosts:${restrict:-0}" "$state"
  fi
  print_dir tcp TCP "$TCP_DIR"
  print_dir ws WS "$WS_DIR"
  print_dir tls TLS "$TLS_DIR"
}

show_status() {
  header
  printf '%-8s %-8s %-12s %-10s\n' TIPO PORTA DESTINO ESTADO
  printf '%-8s %-8s %-12s %-10s\n' '--------' '--------' '------------' '----------'
  status_output
  pause
}

remove_managed() {
  header
  local kind port state unit
  read -r -p "Tipo [squid/tcp/ws/tls]: " kind
  kind="${kind,,}"
  if [[ "$kind" == squid ]]; then
    [[ -f "$SQUID_STATE" ]] || { info "Squid MANAGER não configurado"; pause; return; }
    confirm "Remover somente a configuração Squid do MANAGER?" || { pause; return; }
    systemctl disable --now manager-squid.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/manager-squid.service" "$SQUID_STATE" "$SQUID_CONF"
    systemctl daemon-reload
    ok "Configuração removida; pacote Squid preservado"
    pause
    return
  fi

  [[ "$kind" =~ ^(tcp|ws|tls)$ ]] || { err "Tipo inválido"; pause; return; }
  read -r -p "Porta: " port
  is_valid_port "$port" || { err "Porta inválida"; pause; return; }
  case "$kind" in
    tcp) state="$TCP_DIR/$port.conf" ;;
    ws) state="$WS_DIR/$port.conf" ;;
    tls) state="$TLS_DIR/$port.state" ;;
  esac
  [[ -f "$state" ]] || { err "Serviço não registrado"; pause; return; }
  unit="$(unit_for "$kind" "$port")"
  confirm "Remover $kind na porta $port?" || { pause; return; }
  systemctl disable --now "$unit" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/$unit" "$state"
  if [[ "$kind" == tls ]]; then
    rm -f "$TLS_DIR/$port.pem" "$TLS_DIR/$port.stunnel.conf"
  fi
  systemctl daemon-reload
  ok "Serviço removido"
  pause
}

reconcile() {
  local file port target pem
  if [[ -f "$SQUID_STATE" ]] && command_exists squid; then
    if write_squid_conf && squid -k parse -f "$SQUID_CONF" >/dev/null 2>&1; then
      write_squid_unit
    fi
  fi
  if command_exists socat; then
    for file in "$TCP_DIR"/*.conf; do
      [[ -f "$file" ]] || continue
      port="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"
      is_valid_port "$port" && is_valid_port "$target" && write_tcp_unit "$port" "$target"
    done
  fi
  if command_exists websockify; then
    for file in "$WS_DIR"/*.conf; do
      [[ -f "$file" ]] || continue
      port="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"
      is_valid_port "$port" && is_valid_port "$target" && write_ws_unit "$port" "$target"
    done
  fi
  if command_exists stunnel4 || command_exists stunnel; then
    for file in "$TLS_DIR"/*.state; do
      [[ -f "$file" ]] || continue
      port="$(read_field "$file" listen_port)"; target="$(read_field "$file" target_port)"; pem="$(read_field "$file" pem)"
      if is_valid_port "$port" && is_valid_port "$target" && [[ "$pem" == "$TLS_DIR/"*.pem && -f "$pem" ]]; then
        write_tls_unit "$port" "$target" "$pem"
      fi
    done
  fi
  systemctl daemon-reload
}

init_state
case "${1:-}" in
  --init) exit 0 ;;
  --status) status_output; exit 0 ;;
  --reload-squid) reload_squid; exit $? ;;
  --reconcile) reconcile; exit 0 ;;
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
    3) setup_stream tcp "TCP" "$TCP_DIR" socat ;;
    4) setup_stream ws "WebSocket" "$WS_DIR" websockify ;;
    5) setup_stream tls "TLS" "$TLS_DIR" stunnel4 ;;
    6) remove_managed ;;
    7) reconcile; ok "Unidades reconciliadas"; pause ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
