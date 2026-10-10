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
apt-get install -y curl ca-certificates iproute2 iputils-ping procps passwd login coreutils gawk sed grep tar util-linux dnsutils openssh-client

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=(
  "manager"
  "rollback.sh"
  "uninstall.sh"
  "VERSION"
  "lib/common.sh"
  "modules/system.sh"
  "modules/ssh_users.sh"
  "modules/ssh_keys.sh"
  "modules/ssh_monitor.sh"
  "modules/user_transfer.sh"
  "modules/resellers.sh"
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

for script in manager rollback.sh uninstall.sh lib/common.sh modules/*.sh; do
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
install -m 0644 "$TMP/lib/common.sh" "$STAGE/lib/common.sh"
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
find "$INSTALL_DIR/modules" -maxdepth 1 -type f -name '*.sh' -delete 2>/dev/null || true
install -m 0644 "$STAGE/VERSION" "$INSTALL_DIR/VERSION"
install -m 0644 "$STAGE/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
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

printf '%s\n' "$NEW_VERSION" > "$ETC_DIR/installed-version"
chmod 0644 "$ETC_DIR/installed-version"

echo ""
echo "=================================================="
echo " MANAGER $NEW_VERSION instalado com sucesso"
echo "=================================================="
echo ""
echo "Comandos:   manager | menu"
echo "Saúde:      manager --health"
echo "Expirados:  manager --expired"
echo "Sessões SSH: manager --ssh-sessions"
echo "Rollback:   manager-rollback"
echo "Remover:    manager-uninstall"
[[ -d "$ROLLBACK_DIR" ]] && echo "Código anterior preservado em: $ROLLBACK_DIR"
echo ""
if [[ "${1:-}" != "--update" ]]; then
  echo "VPNs, DNS, firewall, Fail2ban, TLS, Speedtest, vnStat e demais módulos"
  echo "só instalam dependências quando você escolhe a função correspondente."
fi
