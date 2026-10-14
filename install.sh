#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="${MANAGER_REPO_RAW:-https://raw.githubusercontent.com/SrTristeSad/MANAGER/main}"
INSTALL_DIR="/opt/manager"
ROLLBACK_DIR="/opt/manager.rollback"
ETC_DIR="/etc/manager"
BIN="/usr/local/sbin/manager"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERRO] Execute como root: sudo -i" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "[ERRO] Não foi possível identificar o sistema." >&2
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release
case "${ID:-}" in
  ubuntu)
    major="${VERSION_ID%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 22 )); then
      echo "[ERRO] Ubuntu ${VERSION_ID:-?} é antigo demais. Use Ubuntu 22.04 ou superior." >&2
      exit 1
    fi
    ;;
  debian)
    major="${VERSION_ID%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 12 )); then
      echo "[ERRO] Debian ${VERSION_ID:-?} é antigo demais. Use Debian 12 ou superior." >&2
      exit 1
    fi
    ;;
  *)
    echo "[ERRO] Sistema não suportado: ${PRETTY_NAME:-${ID:-desconhecido}}" >&2
    echo "       Use Debian 12+ ou Ubuntu 22.04+." >&2
    exit 1
    ;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[ERRO] systemd é necessário nesta versão do MANAGER." >&2
  exit 1
fi

case "$REPO_RAW" in
  https://*) ;;
  file://*)
    if [[ "${GITHUB_ACTIONS:-false}" != "true" && "${MANAGER_ALLOW_FILE_SOURCE:-0}" != "1" ]]; then
      echo "[ERRO] Fonte file:// só é permitida no CI ou com MANAGER_ALLOW_FILE_SOURCE=1." >&2
      exit 1
    fi
    ;;
  *)
    echo "[ERRO] Fonte de instalação não suportada: $REPO_RAW" >&2
    echo "       Use HTTPS. file:// é reservado para testes locais explícitos." >&2
    exit 1
    ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates iproute2 iputils-ping procps passwd login coreutils gawk sed grep tar util-linux dnsutils openssh-client libpam-modules python3 openssl wireguard-tools

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=(
  "manager"
  "rollback.sh"
  "uninstall.sh"
  "VERSION"
  "lib/common.sh"
  "lib/identity.sh"
  "lib/product_policy.sh"
  "modules/system.sh"
  "modules/ssh_users.sh"
  "modules/ssh_keys.sh"
  "modules/ssh_monitor.sh"
  "modules/user_transfer.sh"
  "modules/resellers.sh"
  "modules/reseller_accounts.sh"
  "modules/reseller_product_quotas.sh"
  "modules/connection_engine.sh"
  "modules/node_metadata.sh"
  "modules/node_usage.sh"
  "modules/hive_identity.sh"
  "modules/hive_key_rotation.sh"
  "modules/hive_network.sh"
  "modules/hive_wg_rotation.sh"
  "modules/hive_health.sh"
  "modules/hive_observability.sh"
  "modules/hive_scheduler.sh"
  "modules/hive_leases.sh"
  "modules/hive_allocations.sh"
  "modules/hive_accounting.sh"
  "modules/hive_remote.sh"
  "modules/hive_lifecycle.sh"
  "modules/products.sh"
  "modules/provision.sh"
  "modules/connection_actions.sh"
  "modules/automation_legacy.sh"
  "modules/automation_principals.sh"
  "modules/automation_credentials.sh"
  "modules/automation_v2.sh"
  "modules/telegram_identity.sh"
  "modules/telegram_auth.sh"
  "modules/telegram_gateway.sh"
  "modules/telegram_bot.sh"
  "modules/policy_engine.sh"
  "modules/session_engine.sh"
  "modules/protocol_leases.sh"
  "modules/ipv6_guard.sh"
  "modules/identity_usage.sh"
  "modules/proxy_hosts.sh"
  "modules/proxies.sh"
  "modules/banner.sh"
  "modules/speedtest.sh"
  "modules/adblock.sh"
  "modules/wireguard.sh"
  "modules/openvpn.sh"
  "modules/firewall.sh"
  "modules/fail2ban.sh"
  "modules/security.sh"
  "modules/tls.sh"
  "modules/diagnostics.sh"
  "modules/health.sh"
  "modules/maintenance.sh"
  "modules/backup.sh"
  "modules/traffic.sh"
  "modules/performance.sh"
  "modules/logs.sh"
  "modules/profiles.sh"
)

curl_fetch() {
  local url="$1" out="$2"
  case "$url" in
    https://*)
      curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 90 "$url" -o "$out"
      ;;
    file://*)
      if [[ "${GITHUB_ACTIONS:-false}" != "true" && "${MANAGER_ALLOW_FILE_SOURCE:-0}" != "1" ]]; then
        echo "[ERRO] Tentativa de usar file:// sem autorização explícita." >&2
        return 1
      fi
      curl -fL --retry 3 --retry-delay 1 --connect-timeout 10 --max-time 90 "$url" -o "$out"
      ;;
    *)
      echo "[ERRO] URL de download recusada: $url" >&2
      return 1
      ;;
  esac
}

for file in "${FILES[@]}"; do
  mkdir -p "$TMP/$(dirname "$file")"
  echo "[i] Baixando $file"
  curl_fetch "$REPO_RAW/$file" "$TMP/$file"
  [[ -s "$TMP/$file" ]] || { echo "[ERRO] Arquivo vazio: $file" >&2; exit 1; }
done

for script in manager rollback.sh uninstall.sh lib/*.sh modules/*.sh; do
  [[ -f "$TMP/$script" ]] || continue
  bash -n "$TMP/$script"
done

NEW_VERSION="$(tr -d '[:space:]' < "$TMP/VERSION")"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]] || {
  echo "[ERRO] VERSION inválida: $NEW_VERSION" >&2
  exit 1
}

STAGE="$TMP/stage"
mkdir -p "$STAGE/lib" "$STAGE/modules" "$ETC_DIR"
chmod 0755 "$ETC_DIR"
install -m 0644 "$TMP/VERSION" "$STAGE/VERSION"
for lib in "$TMP"/lib/*.sh; do install -m 0644 "$lib" "$STAGE/lib/$(basename "$lib")"; done
install -m 0755 "$TMP/manager" "$STAGE/manager"
install -m 0755 "$TMP/rollback.sh" "$STAGE/rollback.sh"
install -m 0755 "$TMP/uninstall.sh" "$STAGE/uninstall.sh"
for script in "$TMP"/modules/*.sh; do
  install -m 0755 "$script" "$STAGE/modules/$(basename "$script")"
done

if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$ROLLBACK_DIR"
  cp -a "$INSTALL_DIR" "$ROLLBACK_DIR"
fi

mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/modules"
find "$INSTALL_DIR/lib" -maxdepth 1 -type f -name '*.sh' -delete 2>/dev/null || true
find "$INSTALL_DIR/modules" -maxdepth 1 -type f -name '*.sh' -delete 2>/dev/null || true
install -m 0644 "$STAGE/VERSION" "$INSTALL_DIR/VERSION"
for lib in "$STAGE"/lib/*.sh; do install -m 0644 "$lib" "$INSTALL_DIR/lib/$(basename "$lib")"; done
install -m 0755 "$STAGE/manager" "$INSTALL_DIR/manager"
install -m 0755 "$STAGE/rollback.sh" "$INSTALL_DIR/rollback.sh"
install -m 0755 "$STAGE/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
for script in "$STAGE"/modules/*.sh; do
  install -m 0755 "$script" "$INSTALL_DIR/modules/$(basename "$script")"
done

ln -sfn "$INSTALL_DIR/manager" "$BIN"
ln -sfn "$BIN" /usr/local/bin/manager
ln -sfn "$BIN" /usr/local/bin/menu
ln -sfn "$INSTALL_DIR/rollback.sh" /usr/local/sbin/manager-rollback
ln -sfn "$INSTALL_DIR/uninstall.sh" /usr/local/sbin/manager-uninstall
ln -sfn "$INSTALL_DIR/modules/automation_v2.sh" /usr/local/sbin/managerctl
ln -sfn "$INSTALL_DIR/modules/automation_v2.sh" /usr/local/bin/managerctl
ln -sfn "$INSTALL_DIR/modules/automation_v2.sh" /usr/local/sbin/managerd

printf '%s\n' "$NEW_VERSION" > "$ETC_DIR/installed-version"
chmod 0644 "$ETC_DIR/installed-version"

"$INSTALL_DIR/modules/connection_engine.sh" --init >/dev/null
"$INSTALL_DIR/modules/node_metadata.sh" --init >/dev/null
"$INSTALL_DIR/modules/hive_identity.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A identidade criptográfica do nó da Colmeia não pôde ser inicializada." >&2
}
"$INSTALL_DIR/modules/hive_key_rotation.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado de rotação de chaves da Colmeia não pôde ser lido. Use: manager hive key status" >&2
}
"$INSTALL_DIR/modules/hive_network.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A rede privada da Colmeia não pôde ser inicializada/reconciliada. Use: manager hive network status" >&2
}
"$INSTALL_DIR/modules/hive_wg_rotation.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado de rotação WireGuard da Colmeia não pôde ser lido. Use: manager hive network rotate status" >&2
}
"$INSTALL_DIR/modules/hive_health.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O heartbeat/saúde da Colmeia não pôde ser reanexado. Use: manager hive health status" >&2
}
"$INSTALL_DIR/modules/hive_observability.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A observabilidade da Colmeia não pôde inicializar seu histórico. Use: manager hive observe status" >&2
}
"$INSTALL_DIR/modules/hive_scheduler.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O scheduler da Colmeia não pôde inicializar seu estado. Use: manager hive node status" >&2
}
"$INSTALL_DIR/modules/hive_leases.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A autoridade global de leases não pôde ser reanexada. Use: manager hive lease status" >&2
}
"$INSTALL_DIR/modules/hive_allocations.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado de allocation 0.8.5 não pôde ser inicializado. Use: manager hive allocation status" >&2
}
"$INSTALL_DIR/modules/hive_accounting.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O accounting global 0.8.6 não pôde ser reanexado. Use: manager hive accounting status" >&2
}
"$INSTALL_DIR/modules/hive_remote.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O registro de roteamento remoto da Colmeia não pôde ser inicializado. Use: manager hive remote controller status" >&2
}
"$INSTALL_DIR/modules/resellers.sh" --init >/dev/null
"$INSTALL_DIR/modules/automation_principals.sh" --init >/dev/null
"$INSTALL_DIR/modules/automation_credentials.sh" --init >/dev/null
"$INSTALL_DIR/modules/products.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O motor de produtos/ACL/franquias foi instalado parcialmente. Identidades sem produto continuam usando a política base." >&2
}
"$INSTALL_DIR/modules/session_engine.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O Session/Lease Engine foi instalado, mas o timer de limpeza não pôde ser iniciado." >&2
}
session_runtime="$("$INSTALL_DIR/modules/session_engine.sh" --init)"
if [[ ! -d "$session_runtime/active" ]]; then
  echo "[AVISO] O diretório runtime de leases não pôde ser inicializado em $session_runtime." >&2
fi
"$INSTALL_DIR/modules/policy_engine.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O motor de políticas foi instalado, mas a reconciliação inicial encontrou uma inconsistência." >&2
}
"$INSTALL_DIR/modules/protocol_leases.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O bridge de leases por protocolo foi instalado parcialmente. Revise PAM/systemd antes de depender do limite de sessões." >&2
}
"$INSTALL_DIR/modules/ipv6_guard.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O IPv6 Guard foi instalado parcialmente. IPv4 continua protegido; revise ip6tables/systemd antes de oferecer VPN dual-stack." >&2
}
"$INSTALL_DIR/modules/identity_usage.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O coletor de uso por identidade foi instalado parcialmente. Os protocolos continuam funcionando, mas os contadores podem não ser atualizados." >&2
}
"$INSTALL_DIR/modules/automation_legacy.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O estado do Legacy v1 foi preservado, mas um listener previamente habilitado não pôde ser reanexado. Use: manager automation legacy status" >&2
}
"$INSTALL_DIR/modules/automation_v2.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O Automation v2 local não pôde iniciar. Revise: systemctl status manager-automation-v2" >&2
}
"$INSTALL_DIR/modules/telegram_identity.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A identidade Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram identity status" >&2
}
"$INSTALL_DIR/modules/telegram_auth.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A autenticação Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram auth status" >&2
}
"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2
}
"$INSTALL_DIR/modules/telegram_bot.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] O ingresso Telegram Bot não pôde inicializar seu estado. Use: manager telegram bot status" >&2
}
"$INSTALL_DIR/modules/hive_lifecycle.sh" --install >/dev/null 2>&1 || {
  echo "[AVISO] A Colmeia iniciou, mas não pôde se vincular ao lifecycle de uninstall/rollback. Revise: /opt/manager/modules/hive_lifecycle.sh --status" >&2
}
if [[ -d "$ETC_DIR/proxy" ]]; then
  "$INSTALL_DIR/modules/proxies.sh" --reconcile >/dev/null 2>&1 || true
fi

echo ""
echo "=================================================="
echo " MANAGER $NEW_VERSION instalado com sucesso"
echo "=================================================="
echo ""
echo "Comandos:    manager | menu"
echo "Saúde:       manager --health"
echo "Expirados:   manager --expired"
echo "Sessões SSH: manager --ssh-sessions"
echo "Proxies:     manager --proxy-status"
echo "Identidades: manager --identities"
echo "Nó:          manager --node"
echo "Colmeia:     manager hive status"
echo "Rede Colmeia: manager hive network status"
echo "Saúde Colmeia: manager hive health status"
echo "Observabilidade: manager hive observe summary"
echo "Scheduler:   manager hive node status"
echo "Leases globais: manager hive lease status"
echo "Accounting global: manager hive accounting status"
echo "Produtos:    manager --products"
echo "Provisionar: manager --provision ID PLANO"
echo "Sessões ID:  manager --identity-sessions"
echo "Leases:      manager --leases"
echo "Uso ID:      manager --usage"
echo "IPv6:        manager --ipv6-status"
echo "Legacy:      manager automation legacy status"
echo "Automation:  managerctl describe"
echo "Rollback:    manager-rollback"
echo "Remover:     manager-uninstall"
[[ -d "$ROLLBACK_DIR" ]] && echo "Código anterior preservado em: $ROLLBACK_DIR"
echo ""
