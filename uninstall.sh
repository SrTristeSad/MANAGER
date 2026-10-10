#!/usr/bin/env bash
set -Eeuo pipefail

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERRO] Execute como root." >&2
  exit 1
fi

if $PURGE; then
  echo "ATENÇÃO: --purge remove configurações criadas pelo MANAGER."
  read -r -p "Digite PURGAR para continuar: " answer
  [[ "$answer" == PURGAR ]] || exit 1

  systemctl disable --now manager-adblock-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-adblock-update.timer /etc/systemd/system/manager-adblock-update.service
  rm -f /etc/dnsmasq.d/90-manager-adblock.conf

  if [[ -d /etc/manager/wireguard && -f /etc/wireguard/wg0.conf ]]; then
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/server.key /etc/wireguard/server.pub
  fi

  rm -f /etc/fail2ban/jail.d/99-manager-sshd.local
  rm -f /etc/ssh/sshd_config.d/99-manager.conf
  rm -f /etc/security/limits.d/99-manager-ssh.conf
  rm -f /etc/sysctl.d/99-manager-wireguard.conf /etc/sysctl.d/99-manager-performance.conf
  rm -rf /etc/manager

  systemctl daemon-reload || true
  if command -v sshd >/dev/null 2>&1 && sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  command -v fail2ban-client >/dev/null 2>&1 && systemctl restart fail2ban 2>/dev/null || true
  command -v dnsmasq >/dev/null 2>&1 && systemctl restart dnsmasq 2>/dev/null || true
fi

rm -f /usr/local/bin/manager /usr/local/bin/menu /usr/local/sbin/manager /usr/local/sbin/manager-rollback
rm -rf /opt/manager /opt/manager.rollback

echo "[OK] Código do MANAGER removido."
if ! $PURGE; then
  echo "As configurações em /etc/manager e serviços configurados foram preservados."
  echo "Use uninstall.sh --purge somente se quiser remover também as configurações do MANAGER."
else
  echo "Configurações do MANAGER removidas. Pacotes do sistema foram preservados para evitar quebrar outros serviços."
fi
