#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
source "$MANAGER_HOME/lib/common.sh"
require_root

DIR="$MANAGER_ETC/telegram/miniapp"
CONF="$DIR/config.conf"
UNIT="/etc/systemd/system/manager-telegram-miniapp.service"
SERVER="$MANAGER_HOME/modules/telegram_miniapp_server.py"
CONTRACT="manager-telegram-miniapp-http-v1"
DEFAULT_PORT=18768

field() {
  awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1" 2>/dev/null || true
}

init_state() {
  install -d -m 0700 "$DIR"
  if [[ ! -e "$CONF" ]]; then
    printf 'version=1\nenabled=0\norigin=\nport=%s\n' "$DEFAULT_PORT" >"$CONF"
  fi
  [[ -f "$CONF" && ! -L "$CONF" ]] || { echo "Configuração inválida" >&2; return 70; }
  chmod 0600 "$CONF"
}

valid_origin() {
  [[ "$1" =~ ^https://[a-zA-Z0-9][a-zA-Z0-9.-]{1,250}$ ]] &&
  [[ "$1" != *..* ]] && [[ "$1" != https://localhost ]] &&
  [[ "$1" != https://127.0.0.1 ]] && [[ "$1" != *".-"* ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]{4,5}$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

write_conf() {
  local enabled="$1" origin="$2" port="$3" temp
  temp="$(mktemp "$DIR/.config.XXXXXXXX")"
  printf 'version=1\nenabled=%s\norigin=%s\nport=%s\n' "$enabled" "$origin" "$port" >"$temp"
  install -m 0600 "$temp" "$CONF"
  rm -f "$temp"
}

service_file() {
  cat >"$UNIT" <<EOF
[Unit]
Description=MANAGER Telegram Mini App (localhost only)
After=network.target manager-automation-v2.service
Requires=manager-automation-v2.service
ConditionPathExists=$SERVER

[Service]
Type=simple
ExecStart=$MANAGER_HOME/modules/telegram_miniapp.sh --serve
Restart=on-failure
RestartSec=3
UMask=0077
PrivateTmp=true
NoNewPrivileges=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
PrivateDevices=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$UNIT"
  systemctl daemon-reload >/dev/null
}

configure() {
  init_state
  local origin="${1:-}" port="${2:-$DEFAULT_PORT}" enabled
  valid_origin "$origin" || { echo "Exija um domínio HTTPS próprio, sem porta/caminho: https://mini.exemplo.com" >&2; return 64; }
  valid_port "$port" || { echo "Porta loopback inválida" >&2; return 64; }
  enabled="$(field "$CONF" enabled)"
  [[ "$enabled" == 1 ]] || enabled=0
  # Never attempt to expose the loopback app or reconfigure firewall/reverse proxy.
  write_conf "$enabled" "${origin,,}" "$port"
  if [[ "$enabled" == 1 ]]; then
    service_file
    systemctl restart manager-telegram-miniapp.service >/dev/null
  fi
  printf 'origin=%s\nloopback=127.0.0.1:%s\n' "${origin,,}" "$port"
}

status() {
  init_state
  local enabled active=0
  enabled="$(field "$CONF" enabled)"
  systemctl is-active --quiet manager-telegram-miniapp.service && active=1 || true
  printf 'contract=%s\norigin=%s\nport=%s\nenabled=%s\nactive=%s\n' \
    "$CONTRACT" "$(field "$CONF" origin)" "$(field "$CONF" port)" "$enabled" "$active"
  printf 'bind_address=127.0.0.1\ntransport=external-https-reverse-proxy\nmode=read-only\n'
  printf 'authorization=telegram-initdata-hmac-plus-automation-v2\n'
  printf 'public_port_opened=0\ninitdata_logged=0\n'
}

enable() {
  init_state
  local origin port
  origin="$(field "$CONF" origin)"
  port="$(field "$CONF" port)"
  valid_origin "$origin" && valid_port "$port" || { echo "Configure primeiro a origem HTTPS" >&2; return 64; }
  [[ -f "$SERVER" ]] && [[ -f "$MANAGER_HOME/web/telegram/index.html" ]] || return 70
  service_file
  write_conf 1 "$origin" "$port"
  systemctl enable --now manager-telegram-miniapp.service >/dev/null
  echo 'miniapp_enabled=1'
}

disable() {
  init_state
  write_conf 0 "$(field "$CONF" origin)" "$(field "$CONF" port)"
  systemctl disable --now manager-telegram-miniapp.service >/dev/null 2>&1 || true
  echo 'miniapp_enabled=0'
}

detach() {
  systemctl disable --now manager-telegram-miniapp.service >/dev/null 2>&1 || true
  [[ ! -f "$UNIT" ]] || rm -f "$UNIT"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

install_state() {
  init_state
  service_file
  if [[ "$(field "$CONF" enabled)" == 1 ]] && valid_origin "$(field "$CONF" origin)" && valid_port "$(field "$CONF" port)"; then
    systemctl enable --now manager-telegram-miniapp.service >/dev/null 2>&1 || true
  fi
}

serve() {
  init_state
  local origin port
  origin="$(field "$CONF" origin)"
  port="$(field "$CONF" port)"
  valid_origin "$origin" && valid_port "$port" || exit 64
  exec python3 -B "$SERVER" "$origin" "$port"
}

case "${1:-}" in
  --install) install_state ;;
  --status) status ;;
  --configure) configure "${2:-}" "${3:-$DEFAULT_PORT}" ;;
  --enable) enable ;;
  --disable) disable ;;
  --detach) detach ;;
  --purge) detach; rm -rf "$DIR" ;;
  --serve) serve ;;
  *) echo "Uso: manager telegram miniapp status|configure URL [PORT]|enable|disable" >&2; exit 64 ;;
esac
