#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

open_step() {
  local title="$1" module="$2"
  header
  say "${C_WHITE}$title${C_RESET}\n"
  info "O MANAGER abrirá o módulo correspondente. Configure o recurso e escolha 0 para voltar ao assistente."
  if confirm "Abrir $title agora?"; then
    "$MANAGER_HOME/modules/$module" || true
  fi
}

secure_base() {
  open_step "1/3 - Segurança do SSH e updates" security.sh
  open_step "2/3 - Fail2ban" fail2ban.sh
  open_step "3/3 - Firewall" firewall.sh
}

profile_basic() {
  header
  say "${C_WHITE}PERFIL: SERVIDOR SEGURO${C_RESET}\n"
  say "Este perfil orienta: hardening SSH, atualizações de segurança, Fail2ban e UFW."
  warn "O firewall só deve ser ativado depois de conferir a porta SSH detectada."
  confirm "Iniciar assistente?" || return
  secure_base
  open_step "Diagnóstico final" diagnostics.sh
}

profile_wireguard() {
  header
  say "${C_WHITE}PERFIL: VPN WIREGUARD${C_RESET}\n"
  say "Base segura + WireGuard + DNS Ad Block opcional + diagnóstico."
  confirm "Iniciar assistente?" || return
  secure_base
  open_step "WireGuard" wireguard.sh
  open_step "DNS Ad Block" adblock.sh
  open_step "Diagnóstico final" diagnostics.sh
}

profile_openvpn() {
  header
  say "${C_WHITE}PERFIL: VPN OPENVPN${C_RESET}\n"
  say "Base segura + OpenVPN + DNS Ad Block opcional + diagnóstico."
  confirm "Iniciar assistente?" || return
  secure_base
  open_step "OpenVPN" openvpn.sh
  open_step "DNS Ad Block" adblock.sh
  open_step "Diagnóstico final" diagnostics.sh
}

profile_dns() {
  header
  say "${C_WHITE}PERFIL: DNS PRIVADO${C_RESET}\n"
  say "Configura o bloqueador DNS e depois abre o diagnóstico."
  confirm "Iniciar assistente?" || return
  open_step "DNS Ad Block" adblock.sh
  open_step "Diagnóstico final" diagnostics.sh
}

profile_full() {
  header
  say "${C_WHITE}PERFIL: COMPLETO${C_RESET}\n"
  warn "Completo não significa instalar tudo cegamente. Cada etapa continua pedindo confirmação."
  say "Você pode pular qualquer módulo sem alterar o restante."
  confirm "Iniciar assistente completo?" || return
  secure_base
  open_step "WireGuard" wireguard.sh
  open_step "OpenVPN" openvpn.sh
  open_step "DNS Ad Block" adblock.sh
  open_step "TLS / Let's Encrypt" tls.sh
  open_step "Monitoramento de tráfego" traffic.sh
  open_step "Desempenho / BBR" performance.sh
  open_step "Backup" backup.sh
  open_step "Diagnóstico final" diagnostics.sh
}

while true; do
  header
  say "${C_WHITE}ASSISTENTE / PERFIS DE CONFIGURAÇÃO${C_RESET}\n"
  say "Os perfis são guiados: nenhuma etapa crítica é aplicada sem sua confirmação."
  say ""
  say " 1) Servidor seguro"
  say " 2) VPN WireGuard"
  say " 3) VPN OpenVPN"
  say " 4) DNS privado / Ad Block"
  say " 5) Completo"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) profile_basic ;;
    2) profile_wireguard ;;
    3) profile_openvpn ;;
    4) profile_dns ;;
    5) profile_full ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
