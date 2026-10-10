#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW="https://raw.githubusercontent.com/SrTristeSad/MANAGER/main"
INSTALL_DIR="/opt/manager"
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
  ubuntu|debian) ;;
  *)
    echo "[ERRO] Sistema não suportado nesta versão: ${PRETTY_NAME:-${ID:-desconhecido}}" >&2
    echo "       Use Debian ou Ubuntu com systemd/apt." >&2
    exit 1
    ;;
esac

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[ERRO] systemd é necessário nesta versão do MANAGER." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates iproute2 procps passwd login coreutils gawk sed grep

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILES=(
  "manager"
  "VERSION"
  "lib/common.sh"
  "modules/system.sh"
  "modules/ssh_users.sh"
  "modules/adblock.sh"
)

for file in "${FILES[@]}"; do
  mkdir -p "$TMP/$(dirname "$file")"
  echo "[i] Baixando $file"
  curl -fsSL --retry 3 "$REPO_RAW/$file" -o "$TMP/$file"
done

# Basic validation before replacing an existing installation.
for script in manager lib/common.sh modules/system.sh modules/ssh_users.sh modules/adblock.sh; do
  bash -n "$TMP/$script"
done

mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/modules" "$ETC_DIR"
install -m 0644 "$TMP/VERSION" "$INSTALL_DIR/VERSION"
install -m 0644 "$TMP/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
install -m 0755 "$TMP/manager" "$INSTALL_DIR/manager"
install -m 0755 "$TMP/modules/system.sh" "$INSTALL_DIR/modules/system.sh"
install -m 0755 "$TMP/modules/ssh_users.sh" "$INSTALL_DIR/modules/ssh_users.sh"
install -m 0755 "$TMP/modules/adblock.sh" "$INSTALL_DIR/modules/adblock.sh"

ln -sfn "$INSTALL_DIR/manager" "$BIN"
ln -sfn "$BIN" /usr/local/bin/manager
ln -sfn "$BIN" /usr/local/bin/menu

VERSION="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"
echo ""
echo "=============================================="
echo " MANAGER $VERSION instalado com sucesso"
echo "=============================================="
echo ""
echo "Comandos:"
echo "  manager"
echo "  menu"
echo ""
if [[ "${1:-}" != "--update" ]]; then
  echo "O bloqueio DNS é opcional e só é instalado pelo menu."
fi
