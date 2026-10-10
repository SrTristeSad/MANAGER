#!/usr/bin/env bash
set -Eeuo pipefail

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERRO] Execute como root." >&2
  exit 1
fi

# O enforcement depende do código instalado. Antes de remover /opt/manager,
# retire hooks/runtime de forma controlada; o estado das identidades permanece
# em /etc/manager quando não há --purge e volta a ser aplicado numa reinstalação.
if [[ -x /opt/manager/modules/policy_engine.sh ]]; then
  /opt/manager/modules/policy_engine.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-policy-reconcile.timer manager-policy-reconcile.path >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-policy-reconcile.timer \
    /etc/systemd/system/manager-policy-reconcile.service \
    /etc/systemd/system/manager-policy-reconcile.path \
    /etc/ssh/sshd_config.d/65-manager-identity-policy.conf \
    /etc/security/limits.d/98-manager-identity.conf
fi

if $PURGE; then
  echo "ATENÇÃO: --purge remove configurações criadas pelo MANAGER."
  echo "Certificados Let's Encrypt, pacotes instalados e regras UFW são preservados para evitar perda de acesso/serviços."
  read -r -p "Digite PURGAR para continuar: " answer
  [[ "$answer" == PURGAR ]] || exit 1

  dnsmasq_owner=""
  certbot_owner=""
  previous_cc=""
  previous_qdisc=""
  previous_forward=""
  if [[ -f /etc/manager/adblock/dnsmasq.owner ]]; then
    dnsmasq_owner="$(cat /etc/manager/adblock/dnsmasq.owner)"
  fi
  if [[ -f /etc/manager/tls/certbot.owner ]]; then
    certbot_owner="$(cat /etc/manager/tls/certbot.owner)"
  fi
  if [[ -f /etc/manager/performance/previous-congestion-control ]]; then
    previous_cc="$(tr -d '[:space:]' < /etc/manager/performance/previous-congestion-control)"
  fi
  if [[ -f /etc/manager/performance/previous-qdisc ]]; then
    previous_qdisc="$(tr -d '[:space:]' < /etc/manager/performance/previous-qdisc)"
  fi
  if [[ -f /etc/manager/network/previous-ip-forward ]]; then
    previous_forward="$(tr -d '[:space:]' < /etc/manager/network/previous-ip-forward)"
  fi

  # Contas teste são explicitamente criadas/geridas pelo MANAGER e podem ser removidas no purge.
  if [[ -d /etc/manager/ssh-tests ]]; then
    for meta in /etc/manager/ssh-tests/*; do
      [[ -f "$meta" ]] || continue
      test_user="${meta##*/}"
      if [[ "$test_user" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && id "$test_user" >/dev/null 2>&1; then
        pkill -KILL -u "$test_user" 2>/dev/null || true
        userdel -r "$test_user" 2>/dev/null || userdel "$test_user" 2>/dev/null || true
      fi
    done
  fi

  systemctl disable --now manager-test-users.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-test-users.timer /etc/systemd/system/manager-test-users.service

  systemctl disable --now manager-adblock-update.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-adblock-update.timer /etc/systemd/system/manager-adblock-update.service
  rm -f /etc/dnsmasq.d/90-manager-adblock.conf /etc/dnsmasq.d/91-manager-adblock-stats.conf

  if [[ -d /etc/manager/wireguard && -f /etc/wireguard/wg0.conf ]]; then
    systemctl disable --now wg-quick@wg0 >/dev/null 2>&1 || true
    rm -f /etc/wireguard/wg0.conf /etc/wireguard/server.key /etc/wireguard/server.pub
  fi

  if [[ -d /etc/manager/openvpn && -f /etc/openvpn/server/manager.conf ]]; then
    systemctl disable --now openvpn-server@manager >/dev/null 2>&1 || true
    rm -f /etc/openvpn/server/manager.conf \
      /etc/openvpn/server/manager-ca.crt \
      /etc/openvpn/server/manager-server.crt \
      /etc/openvpn/server/manager-server.key \
      /etc/openvpn/server/manager-crl.pem \
      /etc/openvpn/server/manager-tls-crypt.key
    rm -rf /etc/systemd/system/openvpn-server@manager.service.d
  fi

  # Proxies/túneis possuem unidades próprias regeneráveis a partir de /etc/manager/proxy.
  systemctl disable --now manager-squid.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-squid.service
  for unit_file in \
    /etc/systemd/system/manager-tcp-proxy-*.service \
    /etc/systemd/system/manager-ws-proxy-*.service \
    /etc/systemd/system/manager-tls-proxy-*.service; do
    [[ -f "$unit_file" ]] || continue
    unit_name="${unit_file##*/}"
    systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
    rm -f "$unit_file"
  done

  systemctl disable --now manager-certbot-renew.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-certbot-renew.timer /etc/systemd/system/manager-certbot-renew.service
  if [[ "$certbot_owner" == "manager" ]]; then
    rm -f /usr/local/bin/certbot
    rm -rf /opt/certbot
  fi

  rm -f /etc/fail2ban/jail.d/99-manager-sshd.local
  rm -f /etc/ssh/sshd_config.d/99-manager.conf
  rm -f /etc/ssh/sshd_config.d/70-manager-banner.conf
  rm -f /etc/ssh/sshd_config.d/65-manager-identity-policy.conf
  rm -f /etc/security/limits.d/99-manager-ssh.conf /etc/security/limits.d/98-manager-identity.conf
  rm -f /etc/sysctl.d/99-manager-wireguard.conf \
    /etc/sysctl.d/99-manager-openvpn.conf \
    /etc/sysctl.d/99-manager-performance.conf

  if [[ "$previous_qdisc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    sysctl -w "net.core.default_qdisc=$previous_qdisc" >/dev/null 2>&1 || true
  fi
  if [[ "$previous_cc" =~ ^[A-Za-z0-9_-]+$ ]]; then
    sysctl -w "net.ipv4.tcp_congestion_control=$previous_cc" >/dev/null 2>&1 || true
  fi
  if [[ "$previous_forward" == 0 || "$previous_forward" == 1 ]]; then
    sysctl -w "net.ipv4.ip_forward=$previous_forward" >/dev/null 2>&1 || true
  fi

  rm -rf /etc/manager
  rm -rf /var/log/manager
  systemctl daemon-reload || true

  if command -v sshd >/dev/null 2>&1 && sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    systemctl restart fail2ban 2>/dev/null || true
  fi
  if command -v dnsmasq >/dev/null 2>&1; then
    if [[ "$dnsmasq_owner" == "preexisting" ]]; then
      systemctl restart dnsmasq 2>/dev/null || true
    else
      systemctl disable --now dnsmasq >/dev/null 2>&1 || true
    fi
  fi
fi

rm -f /usr/local/bin/manager /usr/local/bin/menu \
  /usr/local/sbin/manager /usr/local/sbin/manager-rollback /usr/local/sbin/manager-uninstall
rm -rf /opt/manager /opt/manager.rollback

echo "[OK] Código do MANAGER removido."
if ! $PURGE; then
  echo "As configurações em /etc/manager e serviços configurados foram preservados."
  echo "O enforcement de identidades foi desanexado junto com o código e volta a ser aplicado numa reinstalação."
  echo "Execute manager-uninstall --purge somente se quiser remover também as configurações do MANAGER."
else
  echo "Configurações e unidades próprias do MANAGER removidas. Pacotes do sistema, certificados Let's Encrypt, backups e regras UFW foram preservados."
fi
