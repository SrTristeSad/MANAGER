#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

DROPIN_DIR="/etc/systemd/system/manager-automation-v2.service.d"
DROPIN_FILE="$DROPIN_DIR/90-manager-hive-network.conf"
HELPER="/usr/local/libexec/manager-hive-lifecycle"
DROPIN_MARKER="# MANAGER-HIVE-LIFECYCLE v1"
HELPER_MARKER="# MANAGER-HIVE-LIFECYCLE-HELPER v1"

first_line() {
  local file="$1" line=""
  [[ -f "$file" && ! -L "$file" ]] || return 1
  IFS= read -r line < "$file" || true
  printf '%s' "$line"
}

helper_owned() {
  local line1="" line2=""
  [[ -f "$HELPER" && ! -L "$HELPER" ]] || return 1
  IFS= read -r line1 < "$HELPER" || true
  line2="$(sed -n '2p' "$HELPER" 2>/dev/null || true)"
  [[ "$line1" == '#!/usr/bin/env bash' && "$line2" == "$HELPER_MARKER" ]]
}

refuse_external() {
  local file="$1" marker="$2"
  [[ -e "$file" || -L "$file" ]] || return 0
  [[ -f "$file" && ! -L "$file" ]] || {
    err "Recusando substituir caminho externo/não regular: $file"
    return 65
  }
  [[ "$(first_line "$file")" == "$marker" ]] || {
    err "Recusando substituir arquivo que não pertence ao MANAGER: $file"
    return 65
  }
}

write_helper() {
  if [[ -e "$HELPER" || -L "$HELPER" ]]; then
    helper_owned || {
      err "Recusando substituir helper que não pertence ao MANAGER: $HELPER"
      return 65
    }
  fi
  install -d -m 0755 /usr/local/libexec
  local tmp
  tmp="$(mktemp /usr/local/libexec/.manager-hive-lifecycle.XXXXXX)"
  cat > "$tmp" <<'EOF'
#!/usr/bin/env bash
# MANAGER-HIVE-LIFECYCLE-HELPER v1
set -u

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
HIVE_MODULE="$MANAGER_HOME/modules/hive_network.sh"
DROPIN_FILE="/etc/systemd/system/manager-automation-v2.service.d/90-manager-hive-network.conf"
SELF="/usr/local/libexec/manager-hive-lifecycle"
WG_CONF="/etc/wireguard/mgh0.conf"
WG_OWNER="/etc/manager/hive/network/mgh0.owner"
WG_MARKER="# MANAGER-HIVE-NETWORK v1"

owned_runtime() {
  local first="" owner="" iface=""
  [[ -f "$WG_CONF" && ! -L "$WG_CONF" ]] || return 1
  IFS= read -r first < "$WG_CONF" || true
  [[ "$first" == "$WG_MARKER" ]] || return 1
  if [[ -f "$WG_OWNER" && ! -L "$WG_OWNER" ]]; then
    owner="$(awk -F= '$1=="owner"{print $2; exit}' "$WG_OWNER" 2>/dev/null || true)"
    iface="$(awk -F= '$1=="interface"{print $2; exit}' "$WG_OWNER" 2>/dev/null || true)"
    [[ "$owner" == manager && "$iface" == mgh0 ]] || return 1
  fi
  return 0
}

fallback_detach() {
  systemctl disable --now wg-quick@mgh0.service >/dev/null 2>&1 || true
  if owned_runtime; then
    rm -f "$WG_CONF" "$WG_OWNER"
  fi
}

case "${1:-}" in
  start)
    if [[ -x "$HIVE_MODULE" ]]; then
      "$HIVE_MODULE" --install >/dev/null 2>&1 || true
    fi
    ;;
  stop)
    if [[ -x "$HIVE_MODULE" ]]; then
      "$HIVE_MODULE" --detach >/dev/null 2>&1 || fallback_detach
    else
      fallback_detach
    fi

    # uninstall.sh e rollback.sh usam "systemctl disable --now" no Automation v2.
    # Quando a unidade deixa de estar habilitada, este hook se auto-remove para
    # não sobreviver como dependência órfã numa versão antiga/sem Hive Network.
    if ! systemctl is-enabled --quiet manager-automation-v2.service >/dev/null 2>&1; then
      rm -f "$DROPIN_FILE" "$SELF"
      rmdir /etc/systemd/system/manager-automation-v2.service.d 2>/dev/null || true
    fi
    ;;
  *)
    exit 64
    ;;
esac
EOF
  install -m 0755 "$tmp" "$HELPER"
  rm -f "$tmp"
}

write_dropin() {
  refuse_external "$DROPIN_FILE" "$DROPIN_MARKER" || return $?
  helper_owned || {
    err "Helper de lifecycle da Colmeia não passou na validação de ownership."
    return 65
  }
  install -d -m 0755 "$DROPIN_DIR"
  local tmp
  tmp="$(mktemp "$DROPIN_DIR/.90-manager-hive-network.XXXXXX")"
  cat > "$tmp" <<EOF
$DROPIN_MARKER
[Service]
ExecStartPost=-$HELPER start
ExecStopPost=-$HELPER stop
EOF
  install -m 0644 "$tmp" "$DROPIN_FILE"
  rm -f "$tmp"
}

install_lifecycle() {
  write_helper
  write_dropin
  systemctl daemon-reload
}

detach_lifecycle() {
  if [[ -e "$DROPIN_FILE" || -L "$DROPIN_FILE" ]]; then
    [[ -f "$DROPIN_FILE" && ! -L "$DROPIN_FILE" && "$(first_line "$DROPIN_FILE")" == "$DROPIN_MARKER" ]] || {
      err "Drop-in externo encontrado; recusando remover: $DROPIN_FILE"
      return 65
    }
    rm -f "$DROPIN_FILE"
  fi
  if [[ -e "$HELPER" || -L "$HELPER" ]]; then
    helper_owned || {
      err "Helper externo encontrado; recusando remover: $HELPER"
      return 65
    }
    rm -f "$HELPER"
  fi
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

status_lifecycle() {
  local dropin="0" helper="0"
  if [[ -f "$DROPIN_FILE" && ! -L "$DROPIN_FILE" && "$(first_line "$DROPIN_FILE")" == "$DROPIN_MARKER" ]]; then
    dropin="1"
  fi
  if helper_owned; then
    helper="1"
  fi
  printf 'contract=manager-hive-lifecycle-v1\ndropin=%s\nhelper=%s\nautomation_service=manager-automation-v2.service\n' "$dropin" "$helper"
}

case "${1:-}" in
  --install) install_lifecycle ;;
  --detach|--purge) detach_lifecycle ;;
  --status|"") status_lifecycle ;;
  *)
    err "Uso: hive_lifecycle.sh {--install|--detach|--purge|--status}"
    exit 64
    ;;
esac
