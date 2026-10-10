#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

SSH_DROPIN="/etc/ssh/sshd_config.d/99-manager.conf"

ssh_unit() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then echo ssh; else echo sshd; fi
}

apply_ssh_hardening() {
  header
  say "${C_WHITE}HARDENING DO OPENSSH${C_RESET}\n"
  say "O perfil mantém autenticação por senha e TCP forwarding para compatibilidade com o MANAGER."
  say "Ele reduz tentativas, timeout de login e bloqueia recursos desnecessários."
  confirm "Aplicar perfil seguro?" || return
  mkdir -p /etc/ssh/sshd_config.d
  if [[ -f "$SSH_DROPIN" ]]; then
    cp -a "$SSH_DROPIN" "$SSH_DROPIN.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  cat > "$SSH_DROPIN" <<'EOF'
# Managed by MANAGER
PermitRootLogin prohibit-password
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
TCPKeepAlive yes
EOF
  chmod 0644 "$SSH_DROPIN"
  if ! sshd -t; then
    rm -f "$SSH_DROPIN"
    err "sshd rejeitou a configuração; alteração revertida"
    pause
    return
  fi
  systemctl reload "$(ssh_unit)"
  ok "Hardening aplicado sem reiniciar sua sessão atual"
  pause
}

show_effective_ssh() {
  header
  say "${C_WHITE}OPENSSH EFETIVO${C_RESET}\n"
  sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries|logingracetime|clientaliveinterval|clientalivecountmax|x11forwarding|allowagentforwarding|allowtcpforwarding) ' || true
  say "\nArquivos do MANAGER:"
  [[ -f "$SSH_DROPIN" ]] && cat "$SSH_DROPIN" || warn "Hardening do MANAGER não aplicado"
  pause
}

remove_ssh_hardening() {
  header
  [[ -f "$SSH_DROPIN" ]] || { warn "Nada para remover"; pause; return; }
  confirm "Remover o hardening do MANAGER?" || return
  rm -f "$SSH_DROPIN"
  if sshd -t; then
    systemctl reload "$(ssh_unit)"
    ok "Perfil removido"
  else
    err "A configuração SSH base já possui erro; não foi possível recarregar"
  fi
  pause
}

enable_updates() {
  header
  say "${C_WHITE}ATUALIZAÇÕES AUTOMÁTICAS DE SEGURANÇA${C_RESET}\n"
  confirm "Instalar e ativar unattended-upgrades?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y unattended-upgrades apt-listchanges
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  ok "Atualizações automáticas habilitadas"
  pause
}

security_summary() {
  header
  say "${C_WHITE}RESUMO DE SEGURANÇA${C_RESET}\n"
  printf '%-28s %s\n' "SSH hardening:" "$([[ -f "$SSH_DROPIN" ]] && echo ativo || echo não aplicado)"
  printf '%-28s %s\n' "Fail2ban:" "$(systemctl is-active fail2ban 2>/dev/null || true)"
  printf '%-28s %s\n' "UFW:" "$(command_exists ufw && ufw status | head -n1 || echo não instalado)"
  printf '%-28s %s\n' "Unattended upgrades:" "$([[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && echo configurado || echo não configurado)"
  printf '%-28s %s\n' "Reboot necessário:" "$([[ -f /var/run/reboot-required ]] && echo SIM || echo não)"
  say "\nÚltimos logins:"
  last -n 8 -a 2>/dev/null || true
  pause
}

while true; do
  header
  say "${C_WHITE}SEGURANÇA${C_RESET}\n"
  say " 1) Aplicar hardening seguro do SSH"
  say " 2) Ver configuração SSH efetiva"
  say " 3) Remover hardening do MANAGER"
  say " 4) Ativar atualizações automáticas de segurança"
  say " 5) Resumo de segurança"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) apply_ssh_hardening ;;
    2) show_effective_ssh ;;
    3) remove_ssh_hardening ;;
    4) enable_updates ;;
    5) security_summary ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
