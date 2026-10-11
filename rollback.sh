#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="/opt/manager"
ROLLBACK_DIR="/opt/manager.rollback"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERRO] Execute como root." >&2
  exit 1
fi

if [[ ! -d "$ROLLBACK_DIR" ]]; then
  echo "[ERRO] Nenhuma versão anterior encontrada em $ROLLBACK_DIR" >&2
  exit 1
fi

for script in "$ROLLBACK_DIR/manager" "$ROLLBACK_DIR/lib/common.sh" "$ROLLBACK_DIR"/modules/*.sh; do
  [[ -f "$script" ]] || continue
  bash -n "$script"
done

current="unknown"
previous="unknown"
[[ -f "$INSTALL_DIR/VERSION" ]] && current="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION")"
[[ -f "$ROLLBACK_DIR/VERSION" ]] && previous="$(tr -d '[:space:]' < "$ROLLBACK_DIR/VERSION")"

echo "Versão atual:    $current"
echo "Versão rollback: $previous"
read -r -p "Restaurar o código anterior? [s/N]: " answer
[[ "$answer" =~ ^([sS]|[sS][iI][mM]|[yY]|[yY][eE][sS])$ ]] || exit 0

# Unidades/hooks externos ao /opt precisam ser retirados pelo código que os
# criou antes da troca. Estados persistentes permanecem em /etc/manager e /var/lib.
if [[ -x "$INSTALL_DIR/modules/identity_usage.sh" ]]; then
  "$INSTALL_DIR/modules/identity_usage.sh" --detach >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/products.sh" ]]; then
  "$INSTALL_DIR/modules/products.sh" --detach >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/protocol_leases.sh" ]]; then
  "$INSTALL_DIR/modules/protocol_leases.sh" --detach >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/policy_engine.sh" ]]; then
  "$INSTALL_DIR/modules/policy_engine.sh" --detach >/dev/null 2>&1 || true
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$INSTALL_DIR/." "$TMP/" 2>/dev/null || true
rm -rf "$INSTALL_DIR"
cp -a "$ROLLBACK_DIR" "$INSTALL_DIR"
rm -rf "$ROLLBACK_DIR"
mkdir -p "$ROLLBACK_DIR"
cp -a "$TMP/." "$ROLLBACK_DIR/" 2>/dev/null || true

ln -sfn "$INSTALL_DIR/manager" /usr/local/sbin/manager
ln -sfn /usr/local/sbin/manager /usr/local/bin/manager
ln -sfn /usr/local/sbin/manager /usr/local/bin/menu
ln -sfn "$INSTALL_DIR/rollback.sh" /usr/local/sbin/manager-rollback
ln -sfn "$INSTALL_DIR/uninstall.sh" /usr/local/sbin/manager-uninstall

# Reaplica apenas os componentes disponíveis na versão que acabou de voltar.
# Isso permite rollback para uma versão anterior sem deixar units/hooks
# apontando para módulos ausentes.
if [[ -x "$INSTALL_DIR/modules/products.sh" ]]; then
  "$INSTALL_DIR/modules/products.sh" --install >/dev/null 2>&1 || true
else
  systemctl disable --now manager-product-policy.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-product-policy.timer \
    /etc/systemd/system/manager-product-policy.service
  systemctl daemon-reload || true
fi
if [[ -x "$INSTALL_DIR/modules/session_engine.sh" ]]; then
  "$INSTALL_DIR/modules/session_engine.sh" --install >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/policy_engine.sh" ]]; then
  "$INSTALL_DIR/modules/policy_engine.sh" --install >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/protocol_leases.sh" ]]; then
  "$INSTALL_DIR/modules/protocol_leases.sh" --install >/dev/null 2>&1 || true
fi
if [[ -x "$INSTALL_DIR/modules/identity_usage.sh" ]]; then
  "$INSTALL_DIR/modules/identity_usage.sh" --install >/dev/null 2>&1 || true
fi

echo "[OK] Código restaurado para $previous. A versão $current ficou disponível como novo rollback."
