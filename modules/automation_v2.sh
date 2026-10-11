#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/automation/v2"
PRINCIPALS_DIR="$STATE_DIR/principals"
CREDENTIALS_DIR="$STATE_DIR/credentials"
TLS_DIR="$STATE_DIR/tls"
REMOTE_CONF="$STATE_DIR/remote.conf"
REMOTE_CERT="$TLS_DIR/server.crt"
REMOTE_KEY="$TLS_DIR/server.key"
DATA_DIR="/var/lib/manager/automation-v2"
IDEMPOTENCY_DIR="$DATA_DIR/idempotency"
REPLAY_DIR="$DATA_DIR/replay"
AUDIT_DIR="/var/log/manager"
AUDIT_FILE="$AUDIT_DIR/automation-v2-audit.jsonl"
RUNTIME_DIR="/run/manager-automation-v2"
SOCKET_FILE="$RUNTIME_DIR/manager.sock"
SERVICE_FILE="/etc/systemd/system/manager-automation-v2.service"
REMOTE_SERVICE_FILE="/etc/systemd/system/manager-automation-v2-remote.service"
PRINCIPALS_MODULE="$MANAGER_HOME/modules/automation_principals.sh"
CREDENTIALS_MODULE="$MANAGER_HOME/modules/automation_credentials.sh"
BACKEND="$MANAGER_HOME/modules/automation_v2_backend.py"
CONTRACT="manager-automation-v2-local-v1"

case "$(basename "$0")" in
  managerctl) set -- --call "$@" ;;
  managerd) set -- --serve "$@" ;;
esac

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

ensure_dirs() {
  install -d -m 0700 "$STATE_DIR" "$PRINCIPALS_DIR" "$CREDENTIALS_DIR" "$TLS_DIR" \
    "$DATA_DIR" "$IDEMPOTENCY_DIR" "$REPLAY_DIR" "$AUDIT_DIR"
  touch "$AUDIT_FILE"
  chmod 0600 "$AUDIT_FILE"
  [[ -x "$PRINCIPALS_MODULE" ]] || { err "Registry de principals ausente: $PRINCIPALS_MODULE"; return 69; }
  [[ -x "$CREDENTIALS_MODULE" ]] || { err "Registry de credenciais ausente: $CREDENTIALS_MODULE"; return 69; }
  [[ -r "$BACKEND" ]] || { err "Backend Automation v2 ausente: $BACKEND"; return 69; }
  "$PRINCIPALS_MODULE" --init >/dev/null
  "$CREDENTIALS_MODULE" --init >/dev/null
}

ensure_dependencies() {
  local missing=0
  command -v python3 >/dev/null 2>&1 || missing=1
  command -v openssl >/dev/null 2>&1 || missing=1
  if (( missing == 1 )); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y python3 openssl
  fi
  command -v python3 >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1
}

valid_bind() {
  python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

cert_fingerprint() {
  [[ -f "$REMOTE_CERT" ]] || return 1
  openssl x509 -in "$REMOTE_CERT" -outform DER 2>/dev/null | sha256sum | awk '{print "SHA256:" $1}'
}

generate_remote_certificate() {
  local tmp key cert
  install -d -m 0700 "$TLS_DIR"
  tmp="$(mktemp -d "$STATE_DIR/.tls.XXXXXX")"
  key="$tmp/server.key"
  cert="$tmp/server.crt"
  if ! openssl genpkey -algorithm ED25519 -out "$key" >/dev/null 2>&1; then
    rm -rf "$tmp"
    err "Falha ao gerar chave TLS Ed25519."
    return 70
  fi
  if ! openssl req -new -x509 -key "$key" -out "$cert" -days 825 -subj '/CN=manager-automation-v2' >/dev/null 2>&1; then
    rm -rf "$tmp"
    err "Falha ao gerar certificado TLS."
    return 70
  fi
  install -m 0600 "$key" "$REMOTE_KEY"
  install -m 0600 "$cert" "$REMOTE_CERT"
  rm -rf "$tmp"
}

write_remote_conf() {
  local enabled="$1" bind="$2" port="$3" fp="$4" tmp
  tmp="$(mktemp "$STATE_DIR/.remote.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'enabled=%s\n' "$enabled"
    printf 'bind=%s\n' "$bind"
    printf 'port=%s\n' "$port"
    printf 'tls=TLSv1.3\n'
    printf 'pinning=sha256\n'
    printf 'server_fingerprint=%s\n' "$fp"
  } > "$tmp"
  install -m 0600 "$tmp" "$REMOTE_CONF"
  rm -f "$tmp"
}

write_services() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Automation v2 local Unix-socket daemon
After=network.target
ConditionPathExists=$MANAGER_HOME/modules/automation_v2.sh

[Service]
Type=simple
ExecStart=$MANAGER_HOME/modules/automation_v2.sh --serve
Restart=on-failure
RestartSec=2s
RuntimeDirectory=manager-automation-v2
RuntimeDirectoryMode=0700
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"

  cat > "$REMOTE_SERVICE_FILE" <<EOF
[Unit]
Description=MANAGER Automation v2 TLS remote gateway
After=network-online.target manager-automation-v2.service
Requires=manager-automation-v2.service
ConditionPathExists=$REMOTE_CONF
ConditionPathExists=$REMOTE_CERT
ConditionPathExists=$REMOTE_KEY

[Service]
Type=simple
ExecStart=$MANAGER_HOME/modules/automation_v2.sh --serve-remote
Restart=on-failure
RestartSec=2s
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
  chmod 0644 "$REMOTE_SERVICE_FILE"
  systemctl daemon-reload
}

wait_local_socket() {
  local socket_mode=""
  for _ in {1..50}; do
    if [[ -S "$SOCKET_FILE" ]]; then
      socket_mode="$(stat -c '%a' "$SOCKET_FILE" 2>/dev/null || true)"
      [[ "$socket_mode" == "600" ]] && return 0
    fi
    if ! systemctl is-active --quiet manager-automation-v2.service 2>/dev/null; then
      err "Automation v2 encerrou antes de disponibilizar o socket local."
      systemctl --no-pager --full status manager-automation-v2.service >&2 || true
      return 70
    fi
    sleep 0.1
  done
  err "Automation v2 não disponibilizou $SOCKET_FILE com modo 0600."
  return 70
}

install_v2() {
  local enabled="0"
  ensure_dependencies || { err "Python 3 e OpenSSL são necessários para Automation v2."; return 69; }
  ensure_dirs
  python3 -m py_compile "$BACKEND"
  write_services
  systemctl enable --now manager-automation-v2.service >/dev/null
  wait_local_socket || return $?
  if [[ -f "$REMOTE_CONF" ]]; then
    enabled="$(read_field "$REMOTE_CONF" enabled)"
  fi
  if [[ "$enabled" == "1" ]]; then
    [[ -f "$REMOTE_CERT" && -f "$REMOTE_KEY" ]] || generate_remote_certificate
    chmod 0600 "$REMOTE_CERT" "$REMOTE_KEY"
    systemctl enable --now manager-automation-v2-remote.service >/dev/null
  else
    systemctl disable --now manager-automation-v2-remote.service >/dev/null 2>&1 || true
  fi
}

detach_v2() {
  systemctl disable --now manager-automation-v2-remote.service >/dev/null 2>&1 || true
  systemctl disable --now manager-automation-v2.service >/dev/null 2>&1 || true
  rm -f "$REMOTE_SERVICE_FILE" "$SERVICE_FILE"
  rm -rf "$RUNTIME_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
}

purge_v2() {
  detach_v2
  rm -rf "$STATE_DIR" "$DATA_DIR"
  rm -f "$AUDIT_FILE"
}

remote_enable() {
  local bind="${1:-}" port="${2:-9443}" fp
  ensure_dependencies || return 69
  ensure_dirs
  [[ -n "$bind" ]] || { err "Uso: manager automation v2 remote enable BIND_IP [PORT]"; return 64; }
  valid_bind "$bind" || { err "BIND_IP deve ser um IPv4/IPv6 literal válido."; return 64; }
  valid_port "$port" || { err "PORT deve estar entre 1024 e 65535."; return 64; }
  [[ -f "$REMOTE_CERT" && -f "$REMOTE_KEY" ]] || generate_remote_certificate
  chmod 0600 "$REMOTE_CERT" "$REMOTE_KEY"
  fp="$(cert_fingerprint)" || return 70
  write_remote_conf 1 "$bind" "$port" "$fp"
  write_services
  systemctl enable --now manager-automation-v2.service >/dev/null
  wait_local_socket || return $?
  systemctl enable --now manager-automation-v2-remote.service >/dev/null
  printf 'remote_enabled=1\nbind=%s\nport=%s\nserver_fingerprint=%s\n' "$bind" "$port" "$fp"
  warn "Nenhuma regra de firewall foi aberta automaticamente. Restrinja a porta aos clientes/redes necessários."
}

remote_disable() {
  local bind="127.0.0.1" port="9443" fp="-"
  ensure_dirs
  if [[ -f "$REMOTE_CONF" ]]; then
    bind="$(read_field "$REMOTE_CONF" bind)"; bind="${bind:-127.0.0.1}"
    port="$(read_field "$REMOTE_CONF" port)"; port="${port:-9443}"
  fi
  [[ -f "$REMOTE_CERT" ]] && fp="$(cert_fingerprint || echo '-')"
  write_remote_conf 0 "$bind" "$port" "$fp"
  systemctl disable --now manager-automation-v2-remote.service >/dev/null 2>&1 || true
  printf 'remote_enabled=0\n'
}

remote_rotate_certificate() {
  local enabled="0" bind="127.0.0.1" port="9443" fp
  ensure_dependencies || return 69
  ensure_dirs
  if [[ -f "$REMOTE_CONF" ]]; then
    enabled="$(read_field "$REMOTE_CONF" enabled)"; enabled="${enabled:-0}"
    bind="$(read_field "$REMOTE_CONF" bind)"; bind="${bind:-127.0.0.1}"
    port="$(read_field "$REMOTE_CONF" port)"; port="${port:-9443}"
  fi
  generate_remote_certificate
  fp="$(cert_fingerprint)"
  write_remote_conf "$enabled" "$bind" "$port" "$fp"
  if [[ "$enabled" == "1" ]]; then
    write_services
    systemctl restart manager-automation-v2-remote.service
  fi
  printf 'certificate_rotated=1\nserver_fingerprint=%s\n' "$fp"
}

remote_status() {
  local enabled="0" bind="-" port="-" fp="-" service="inactive"
  if [[ -f "$REMOTE_CONF" ]]; then
    enabled="$(read_field "$REMOTE_CONF" enabled)"; enabled="${enabled:-0}"
    bind="$(read_field "$REMOTE_CONF" bind)"; bind="${bind:--}"
    port="$(read_field "$REMOTE_CONF" port)"; port="${port:--}"
    fp="$(read_field "$REMOTE_CONF" server_fingerprint)"; fp="${fp:--}"
  fi
  systemctl is-active --quiet manager-automation-v2-remote.service 2>/dev/null && service="active"
  printf 'remote_transport=1\nremote_enabled=%s\nremote_service=%s\nremote_bind=%s\nremote_port=%s\nremote_tls=TLSv1.3\nserver_fingerprint=%s\n' \
    "$enabled" "$service" "$bind" "$port" "$fp"
}

show_status() {
  local service_state="inactive" socket_state="missing" socket_mode="-"
  systemctl is-active --quiet manager-automation-v2.service 2>/dev/null && service_state="active"
  if [[ -S "$SOCKET_FILE" ]]; then
    socket_state="ready"
    socket_mode="$(stat -c '%a' "$SOCKET_FILE" 2>/dev/null || echo '?')"
  fi
  printf 'contract=%s\n' "$CONTRACT"
  printf 'version=1\ntransport=unix,tls1.3\n'
  printf 'socket=%s\nsocket_mode=%s\nservice=%s\nsocket_state=%s\n' \
    "$SOCKET_FILE" "$socket_mode" "$service_state" "$socket_state"
  remote_status
  printf 'arbitrary_shell=0\n'
  printf 'rbac=1\nprincipal_assertion=local-root-peercred-or-ed25519\n'
  printf 'cryptographic_auth=1\ncredential_algorithm=ed25519\nauth_scheme=ed25519-v2\nnonlocal_signature_required=1\n'
  printf 'enrollment=local-admin\nkey_rotation=1\nkey_revocation=1\n'
  printf 'timestamp_signed=1\ntimestamp_window_seconds=120\nnonce_signed=1\nanti_replay=1\n'
  printf 'rate_limit=1\nprincipal_action_rate_limit=1\nremote_source_burst_limit=1\n'
  printf 'tls_server_pinning=sha256\nremote_local_root=0\n'
  printf 'idempotency=1\naudit=1\nsecret_replay=0\n'
}

serve_local() {
  ensure_dependencies || exit 69
  ensure_dirs
  exec python3 "$BACKEND" serve-local
}

serve_remote() {
  ensure_dependencies || exit 69
  ensure_dirs
  exec python3 "$BACKEND" serve-remote
}

call_v2() {
  ensure_dependencies || exit 69
  ensure_dirs
  exec python3 "$BACKEND" call "$@"
}

case "${1:-}" in
  --install) install_v2 ;;
  --detach) detach_v2 ;;
  --purge) purge_v2 ;;
  --status) show_status ;;
  --serve) serve_local ;;
  --serve-remote) serve_remote ;;
  --remote-enable) remote_enable "${2:-}" "${3:-9443}" ;;
  --remote-disable) remote_disable ;;
  --remote-status) remote_status ;;
  --remote-rotate-certificate) remote_rotate_certificate ;;
  --call)
    shift
    call_v2 "$@"
    ;;
  "") show_status ;;
  *)
    err "Uso: automation_v2.sh {--install|--detach|--purge|--status|--serve|--serve-remote|--remote-enable IP [PORT]|--remote-disable|--remote-status|--remote-rotate-certificate|--call ...}"
    exit 64
    ;;
esac
