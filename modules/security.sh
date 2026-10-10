#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

SSH_DROPIN="/etc/ssh/sshd_config.d/99-manager.conf"
AUTO_UPDATES="/etc/apt/apt.conf.d/20auto-upgrades"

ssh_unit() {
  if systemctl show -p LoadState --value ssh.service 2>/dev/null | grep -qx loaded; then
    echo ssh
  else
    echo sshd
  fi
}

dropins_supported() {
  grep -Eiq '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null
}

apply_ssh_hardening() {
  header
  say "${C_WHITE}HARDENING DO OPENSSH${C_RESET}\n"
  if ! dropins_supported; then
    err "Este sshd_config não inclui sshd_config.d/*.conf. O MANAGER se recusa a editar o arquivo principal automaticamente."
    pause
    return
  fi
  say "O perfil NÃO desativa senha, NÃO muda a porta e NÃO bloqueia login root por senha."
  say "Isso evita cortar o seu acesso remoto. Ele apenas reduz superfície e abuso."
  confirm "Aplicar perfil seguro?" || return
  backup_file "$SSH_DROPIN"
  mkdir -p /etc/ssh/sshd_config.d
  cat > "$SSH_DROPIN" <<'EOF'
# Managed by MANAGER
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
  say "\nArquivo do MANAGER:"
  if [[ -f "$SSH_DROPIN" ]]; then
    cat "$SSH_DROPIN"
  else
    warn "Hardening do MANAGER não aplicado"
  fi
  pause
}

remove_ssh_hardening() {
  header
  [[ -f "$SSH_DROPIN" ]] || { warn "Nada para remover"; pause; return; }
  confirm "Remover o hardening do MANAGER?" || return
  backup_file "$SSH_DROPIN"
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
  backup_file "$AUTO_UPDATES"
  cat > "$AUTO_UPDATES" <<'EOF'
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
  local ssh_hardening f2b ufw_state updates reboot
  if [[ -f "$SSH_DROPIN" ]]; then ssh_hardening="ativo"; else ssh_hardening="não aplicado"; fi
  f2b="$(systemctl is-active fail2ban 2>/dev/null || true)"
  [[ -n "$f2b" ]] || f2b="não instalado"
  if command_exists ufw; then ufw_state="$(ufw status 2>/dev/null | head -n1)"; else ufw_state="não instalado"; fi
  if [[ -f "$AUTO_UPDATES" ]]; then updates="configurado"; else updates="não configurado"; fi
  if [[ -f /var/run/reboot-required ]]; then reboot="SIM"; else reboot="não"; fi

  printf '%-28s %s\n' "SSH hardening:" "$ssh_hardening"
  printf '%-28s %s\n' "Fail2ban:" "$f2b"
  printf '%-28s %s\n' "UFW:" "$ufw_state"
  printf '%-28s %s\n' "Unattended upgrades:" "$updates"
  printf '%-28s %s\n' "Reboot necessário:" "$reboot"
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
