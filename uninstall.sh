#!/usr/bin/env bash
set -Eeuo pipefail

PURGE=false
[[ "${1:-}" == "--purge" ]] && PURGE=true

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[ERRO] Execute como root." >&2
  exit 1
fi

CONNECTION_SNAPSHOT=""
if ! $PURGE && [[ -d /etc/manager/connection ]]; then
  CONNECTION_SNAPSHOT="$(mktemp -d)"
  [[ -d /etc/manager/connection/identities ]] && cp -a /etc/manager/connection/identities "$CONNECTION_SNAPSHOT/"
  [[ -d /etc/manager/connection/session-epochs ]] && cp -a /etc/manager/connection/session-epochs "$CONNECTION_SNAPSHOT/"
fi

restore_connection_state() {
  [[ -n "$CONNECTION_SNAPSHOT" && -d "$CONNECTION_SNAPSHOT" ]] || return 0
  install -d -m 0700 /etc/manager/connection
  if [[ -d "$CONNECTION_SNAPSHOT/identities" ]]; then
    rm -rf /etc/manager/connection/identities
    cp -a "$CONNECTION_SNAPSHOT/identities" /etc/manager/connection/
  fi
  if [[ -d "$CONNECTION_SNAPSHOT/session-epochs" ]]; then
    rm -rf /etc/manager/connection/session-epochs
    cp -a "$CONNECTION_SNAPSHOT/session-epochs" /etc/manager/connection/
  fi
  rm -rf "$CONNECTION_SNAPSHOT"
  CONNECTION_SNAPSHOT=""
}

remove_protocol_pam_fallback() {
  local pam=/etc/pam.d/sshd tmp
  [[ -f "$pam" ]] || return 0
  grep -Fqx '# MANAGER-PROTOCOL-LEASE-BEGIN' "$pam" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk '
    $0=="# MANAGER-PROTOCOL-LEASE-BEGIN" {skip=1; next}
    $0=="# MANAGER-PROTOCOL-LEASE-END" {skip=0; next}
    !skip {print}
  ' "$pam" > "$tmp"
  install -m 0644 "$tmp" "$pam"
  rm -f "$tmp"
}

# Accounting global 0.8.6 usa timer apenas no nó. Estado agregado, snapshots e
# políticas de franquia sobrevivem ao uninstall normal; --purge remove tudo.
if [[ -x /opt/manager/modules/hive_accounting.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_accounting.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_accounting.sh --detach >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now manager-hive-accounting-sync.timer >/dev/null 2>&1 || true
  systemctl stop manager-hive-accounting-sync.service >/dev/null 2>&1 || true
  for unit in /etc/systemd/system/manager-hive-accounting-sync.service /etc/systemd/system/manager-hive-accounting-sync.timer; do
    if [[ -f "$unit" ]] && grep -Fqx '# MANAGER-HIVE-GLOBAL-ACCOUNTING v1' "$unit" 2>/dev/null; then rm -f "$unit"; fi
  done
  if $PURGE; then
    rm -rf /etc/manager/hive/accounting /etc/manager/hive/controller/accounting /var/lib/manager/hive-accounting
    rm -f /var/log/manager/hive-accounting-audit.jsonl
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Allocation 0.8.5 não possui daemon. Tickets/epochs sobrevivem ao uninstall normal
# e são removidos apenas no purge, junto da autoridade global que os sustenta.
if [[ -x /opt/manager/modules/hive_allocations.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_allocations.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_allocations.sh --detach >/dev/null 2>&1 || true
  fi
elif $PURGE; then
  rm -rf /etc/manager/hive/allocations /var/lib/manager/hive-allocations
  rm -f /var/log/manager/hive-allocation-audit.jsonl
fi

# A autoridade global de leases sai antes dos bridges de protocolo. Configuração,
# limites e leases persistentes sobrevivem ao uninstall normal; --purge remove tudo.
if [[ -x /opt/manager/modules/hive_leases.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_leases.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_leases.sh --detach >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now manager-hive-lease-controller.service >/dev/null 2>&1 || true
  if [[ -f /etc/systemd/system/manager-hive-lease-controller.service ]] && grep -Fqx '# MANAGER-HIVE-GLOBAL-LEASE v1' /etc/systemd/system/manager-hive-lease-controller.service 2>/dev/null; then
    rm -f /etc/systemd/system/manager-hive-lease-controller.service
  fi
  if $PURGE; then
    rm -rf /etc/manager/hive/controller/leases /etc/manager/hive/leases /var/lib/manager/hive-leases
    rm -f /var/log/manager/hive-lease-audit.jsonl
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Scheduler da Colmeia não possui daemon próprio. No uninstall normal seu estado
# de placement/sticky é preservado; --purge remove estado e auditoria explicitamente.
if [[ -x /opt/manager/modules/hive_scheduler.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_scheduler.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_scheduler.sh --detach >/dev/null 2>&1 || true
  fi
else
  if $PURGE; then
    rm -rf /etc/manager/hive/controller/scheduler /var/lib/manager/hive-scheduler
    rm -f /var/log/manager/hive-scheduler-audit.jsonl
  fi
fi

# Roteamento remoto 0.8.8 não possui daemon próprio. Rotas assinadas e política
# do controlador sobrevivem ao uninstall normal e são removidas apenas no purge.
if [[ -x /opt/manager/modules/hive_remote.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/hive_remote.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/hive_remote.sh --detach >/dev/null 2>&1 || true
  fi
elif $PURGE; then
  rm -rf /etc/manager/hive/controller/remote
  rm -f /etc/manager/automation/v2/hive-controller.conf /var/log/manager/hive-remote-audit.jsonl
fi

# Automation v2 possui o socket Unix local e pode possuir o gateway TLS remoto.
# Ambos precisam sair antes de /opt/manager ser removido. Estado, credenciais
# públicas, idempotência, anti-replay e configuração TLS permanecem no uninstall
# normal e somem apenas com --purge.
if [[ -x /opt/manager/modules/automation_v2.sh ]]; then
  if $PURGE; then
    /opt/manager/modules/automation_v2.sh --purge >/dev/null 2>&1 || true
  else
    /opt/manager/modules/automation_v2.sh --detach >/dev/null 2>&1 || true
  fi
else
  systemctl disable --now manager-automation-v2-remote.service manager-automation-v2.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-automation-v2-remote.service \
    /etc/systemd/system/manager-automation-v2.service
  rm -rf /run/manager-automation-v2
  if $PURGE; then
    rm -rf /etc/manager/automation/v2 /var/lib/manager/automation-v2
    rm -f /var/log/manager/automation-v2-audit.jsonl
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

# Legacy v1 usa um listener SSH dedicado. Ele sempre sai antes do código para
# que uninstall/rollback nunca deixem uma porta aberta apontando para comando ausente.
if [[ -x /opt/manager/modules/automation_legacy.sh ]]; then
  /opt/manager/modules/automation_legacy.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-automation-legacy.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-automation-legacy.service \
    /etc/ssh/sshd_config.d/64-manager-automation-legacy.conf
  if id manager-legacy >/dev/null 2>&1; then
    passwd -l manager-legacy >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if command -v sshd >/dev/null 2>&1; then
    install -d -m 0755 /run/sshd
    if sshd -t; then
      systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true
    fi
  fi
fi

# O histórico consolidado de uso é persistente. A unidade precisa sair antes
# do código; os dados permanecem em /var/lib sem --purge.
if [[ -x /opt/manager/modules/identity_usage.sh ]]; then
  /opt/manager/modules/identity_usage.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-identity-usage.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-identity-usage.timer \
    /etc/systemd/system/manager-identity-usage.service
  systemctl daemon-reload || true
fi

# Produtos, vínculos, ACL e baselines de franquia ficam dentro do estado
# persistente do Connection Engine. Apenas o reconciliador systemd sai aqui.
if [[ -x /opt/manager/modules/products.sh ]]; then
  /opt/manager/modules/products.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-product-policy.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-product-policy.timer \
    /etc/systemd/system/manager-product-policy.service
  systemctl daemon-reload || true
fi

# O guard apenas espelha as decisões de identidade/lease no plano IPv6. Ele
# precisa remover suas regras específicas antes que Session/Policy Engine saiam.
if [[ -x /opt/manager/modules/ipv6_guard.sh ]]; then
  /opt/manager/modules/ipv6_guard.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-ipv6-guard.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-ipv6-guard.timer \
    /etc/systemd/system/manager-ipv6-guard.service
  rm -rf /run/manager-ipv6-guard
  systemctl daemon-reload || true
fi

# O bridge precisa sair antes do Session Engine, pois usa leases existentes para
# liberar mapas, regras específicas e hooks de protocolo sem deixar lockout.
if [[ -x /opt/manager/modules/protocol_leases.sh ]]; then
  /opt/manager/modules/protocol_leases.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-protocol-leases.timer manager-openvpn-lease-queue.path >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-protocol-leases.timer \
    /etc/systemd/system/manager-protocol-leases.service \
    /etc/systemd/system/manager-openvpn-lease-queue.service \
    /etc/systemd/system/manager-openvpn-lease-queue.path \
    /usr/local/libexec/manager-ssh-lease-hook \
    /usr/local/libexec/manager-openvpn-lease-hook
  remove_protocol_pam_fallback
  rm -rf /run/manager-protocol-leases
  systemctl daemon-reload || true
fi

# Leases ativas são runtime e não sobrevivem sem o código do MANAGER.
# Os epochs persistentes ficam em /etc/manager quando não há --purge.
if [[ -x /opt/manager/modules/session_engine.sh ]]; then
  /opt/manager/modules/session_engine.sh --detach >/dev/null 2>&1 || true
else
  systemctl disable --now manager-session-cleanup.timer manager-session-reconcile.path >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/manager-session-cleanup.timer \
    /etc/systemd/system/manager-session-cleanup.service \
    /etc/systemd/system/manager-session-reconcile.path
  rm -rf /run/manager-session-leases
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

if ! $PURGE; then
  restore_connection_state
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
  previous_forward6=""
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
  if [[ -f /etc/manager/network/previous-ipv6-forwarding ]]; then
    previous_forward6="$(tr -d '[:space:]' < /etc/manager/network/previous-ipv6-forwarding)"
  fi

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

  if id manager-legacy >/dev/null 2>&1; then
    pkill -KILL -u manager-legacy >/dev/null 2>&1 || true
    userdel -r manager-legacy >/dev/null 2>&1 || userdel manager-legacy >/dev/null 2>&1 || true
  fi
  rm -rf /var/lib/manager-legacy

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
  rm -f /etc/ssh/sshd_config.d/64-manager-automation-legacy.conf
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
  if [[ "$previous_forward6" == 0 || "$previous_forward6" == 1 ]]; then
    sysctl -w "net.ipv6.conf.all.forwarding=$previous_forward6" >/dev/null 2>&1 || true
  fi

  rm -rf /etc/manager
  rm -rf /var/log/manager
  rm -rf /var/lib/manager/identity-usage
  rm -rf /var/lib/manager/automation-v2
  rm -rf /var/lib/manager/hive-scheduler
  rm -rf /run/manager-ipv6-guard /run/manager-automation-v2
  rmdir /var/lib/manager 2>/dev/null || true
  systemctl daemon-reload || true

  if command -v sshd >/dev/null 2>&1; then
    [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd
    if sshd -t; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
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

rm -f /usr/local/bin/manager /usr/local/bin/menu /usr/local/bin/managerctl \
  /usr/local/sbin/manager /usr/local/sbin/manager-rollback /usr/local/sbin/manager-uninstall \
  /usr/local/sbin/managerctl /usr/local/sbin/managerd
rm -rf /opt/manager /opt/manager.rollback

echo "[OK] Código do MANAGER removido."
if ! $PURGE; then
  echo "As configurações em /etc/manager e serviços configurados foram preservados."
  echo "Produtos, vínculos, ACL e estado de franquia foram preservados no Connection Engine."
  echo "O estado de placement/sticky do scheduler da Colmeia foi preservado; não há daemon do scheduler para permanecer ativo."
  echo "A configuração do Automation Legacy foi preservada, mas seu listener foi fechado e a conta de integração ficou bloqueada."
  echo "O estado/idempotência/anti-replay da Automation v2 e sua configuração TLS foram preservados, mas daemon, socket e gateway remoto foram removidos."
  echo "O histórico consolidado de uso em /var/lib/manager/identity-usage foi preservado."
  echo "Leases runtime e regras runtime do IPv6 Guard foram descartadas; estado persistente permanece para reinstalação."
  echo "Hooks PAM/OpenVPN e o bridge de protocolos foram desanexados antes da remoção do código."
  echo "O enforcement de identidades foi desanexado junto com o código e volta a ser aplicado numa reinstalação."
  echo "Execute manager-uninstall --purge somente se quiser remover também as configurações e o histórico do MANAGER."
else
  echo "Configurações, automação, produtos, ACL, franquias, histórico de uso e unidades próprias do MANAGER removidos. Forwarding IPv4/IPv6 anterior foi restaurado quando conhecido."
fi