#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

apt_available() { command_exists apt-get; }

show_status() {
  header
  say "${C_WHITE}MANUTENÇÃO DO SISTEMA${C_RESET}\n"
  printf '%-24s %s\n' "SO:" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-desconhecido}")"
  printf '%-24s %s\n' "Kernel:" "$(uname -r)"
  printf '%-24s %s\n' "Uptime:" "$(uptime -p 2>/dev/null || echo '-')"
  printf '%-24s %s\n' "Reboot pendente:" "$([[ -f /var/run/reboot-required ]] && echo sim || echo não)"
  printf '%-24s %s\n' "Hora:" "$(date -Is)"
  printf '%-24s %s\n' "Timezone:" "$(timedatectl show -p Timezone --value 2>/dev/null || echo '-')"
  printf '%-24s %s\n' "Sincronização NTP:" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo '-')"
  if apt_available; then
    printf '%-24s %s\n' "Atualizações no cache:" "$(apt list --upgradable 2>/dev/null | tail -n +2 | grep -c . || true)"
  fi
  say ""
  df -hP / | sed -n '1,2p'
  pause
}

refresh_packages() {
  header
  apt_available || { err "APT não disponível nesta distribuição"; pause; return; }
  say "${C_WHITE}ATUALIZAR ÍNDICES APT${C_RESET}\n"
  apt-get update
  ok "Índices atualizados"
  pause
}

upgrade_packages() {
  header
  apt_available || { err "APT não disponível nesta distribuição"; pause; return; }
  say "${C_WHITE}ATUALIZAR PACOTES${C_RESET}\n"
  apt-get update
  say "Pacotes atualizáveis:"
  apt list --upgradable 2>/dev/null | sed -n '1,80p'
  say ""
  confirm "Aplicar upgrade normal (sem dist-upgrade)?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get upgrade -y
  if [[ -f /var/run/reboot-required ]]; then warn "O sistema solicita reinicialização."; fi
  ok "Upgrade concluído"
  pause
}

security_updates() {
  header
  apt_available || { err "APT não disponível nesta distribuição"; pause; return; }
  say "${C_WHITE}ATUALIZAÇÕES AUTOMÁTICAS DE SEGURANÇA${C_RESET}\n"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y unattended-upgrades
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  chmod 0644 /etc/apt/apt.conf.d/20auto-upgrades
  if command_exists unattended-upgrade; then
    unattended-upgrade --dry-run --debug >/tmp/manager-unattended-dryrun.log 2>&1 || true
  fi
  ok "Atualizações automáticas de segurança habilitadas"
  info "Dry-run: /tmp/manager-unattended-dryrun.log"
  pause
}

cleanup_packages() {
  header
  apt_available || { err "APT não disponível nesta distribuição"; pause; return; }
  say "${C_WHITE}LIMPEZA SEGURA DO APT${C_RESET}\n"
  say "Espaço antes: $(df -hP / | awk 'NR==2 {print $4 " livre"}')"
  apt-get -s autoremove | sed -n '1,80p' || true
  say ""
  confirm "Executar autoremove e limpar cache de pacotes?" || return
  apt-get autoremove --purge -y
  apt-get autoclean -y
  apt-get clean
  ok "Limpeza concluída. Espaço: $(df -hP / | awk 'NR==2 {print $4 " livre"}')"
  pause
}

journal_cleanup() {
  header
  say "${C_WHITE}LIMPAR JOURNAL ANTIGO${C_RESET}\n"
  journalctl --disk-usage 2>/dev/null || true
  say ""
  confirm "Manter somente os últimos 14 dias de journal?" || return
  journalctl --vacuum-time=14d
  journalctl --disk-usage 2>/dev/null || true
  pause
}

ntp_enable() {
  header
  say "${C_WHITE}HORA / NTP${C_RESET}\n"
  if ! command_exists timedatectl; then err "timedatectl não disponível"; pause; return; fi
  timedatectl status || true
  say ""
  confirm "Ativar sincronização automática NTP?" || return
  timedatectl set-ntp true
  ok "NTP solicitado ao systemd"
  pause
}

reboot_server() {
  header
  warn "Isto encerrará todas as conexões da VPS."
  [[ -f /var/run/reboot-required ]] || info "O sistema não indica reboot obrigatório neste momento."
  confirm "REINICIAR o servidor agora?" || return
  sync
  systemctl reboot
}

while true; do
  header
  say "${C_WHITE}MANUTENÇÃO${C_RESET}\n"
  say " 1) Resumo / reboot pendente"
  say " 2) Atualizar índices APT"
  say " 3) Atualizar pacotes"
  say " 4) Ativar updates automáticos de segurança"
  say " 5) Limpar pacotes/cache"
  say " 6) Limpar journal antigo"
  say " 7) Ativar sincronização NTP"
  say " 8) Reiniciar servidor"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_status ;;
    2) refresh_packages ;;
    3) upgrade_packages ;;
    4) security_updates ;;
    5) cleanup_packages ;;
    6) journal_cleanup ;;
    7) ntp_enable ;;
    8) reboot_server ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
