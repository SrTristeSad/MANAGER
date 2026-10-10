#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

BACKUP_DIR="/var/backups/manager"
mkdir -p "$BACKUP_DIR"
chmod 0700 "$BACKUP_DIR"

collect_paths() {
  local p
  for p in \
    /etc/manager \
    /etc/wireguard/wg0.conf \
    /etc/wireguard/server.key \
    /etc/wireguard/server.pub \
    /etc/openvpn/server/manager.conf \
    /etc/openvpn/server/manager-ca.crt \
    /etc/openvpn/server/manager-server.crt \
    /etc/openvpn/server/manager-server.key \
    /etc/openvpn/server/manager-crl.pem \
    /etc/openvpn/server/manager-tls-crypt.key \
    /etc/systemd/system/openvpn-server@manager.service.d \
    /etc/dnsmasq.d/90-manager-adblock.conf \
    /etc/dnsmasq.d/91-manager-adblock-stats.conf \
    /etc/systemd/system/manager-adblock-update.timer \
    /etc/systemd/system/manager-adblock-update.service \
    /etc/systemd/system/manager-certbot-renew.timer \
    /etc/systemd/system/manager-certbot-renew.service \
    /etc/security/limits.d/99-manager-ssh.conf \
    /etc/fail2ban/jail.d/99-manager-sshd.local \
    /etc/ssh/sshd_config.d/99-manager.conf \
    /etc/apt/apt.conf.d/20auto-upgrades \
    /etc/sysctl.d/99-manager-wireguard.conf \
    /etc/sysctl.d/99-manager-openvpn.conf \
    /etc/sysctl.d/99-manager-performance.conf; do
    [[ -e "$p" ]] && printf '%s\n' "${p#/}"
  done
}

create_backup() {
  header
  say "${C_WHITE}CRIAR BACKUP${C_RESET}\n"
  local stamp archive list manifest
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="$BACKUP_DIR/manager-$stamp.tar.gz"
  list="$(mktemp)"
  manifest="$(mktemp)"
  trap 'rm -f "$list" "$manifest"' RETURN

  collect_paths > "$list"
  if [[ ! -s "$list" ]]; then
    warn "Ainda não há configurações gerenciadas para salvar."
    pause
    return
  fi

  {
    echo "created=$(date -Is)"
    echo "hostname=$(hostname)"
    echo "kernel=$(uname -r)"
    if [[ -r /etc/os-release ]]; then
      grep -E '^(ID|VERSION_ID|PRETTY_NAME)=' /etc/os-release || true
    fi
  } > "$manifest"

  tar -C / -czf "$archive" -T "$list"
  chmod 0600 "$archive"
  sha256sum "$archive" > "$archive.sha256"
  chmod 0600 "$archive.sha256"
  cp "$manifest" "$archive.manifest"
  chmod 0600 "$archive.manifest"
  ok "Backup criado: $archive"
  warn "O backup pode conter chaves privadas de VPN. Trate o arquivo como segredo."
  pause
}

list_backups() {
  header
  say "${C_WHITE}BACKUPS LOCAIS${C_RESET}\n"
  if ! compgen -G "$BACKUP_DIR/manager-*.tar.gz" >/dev/null; then
    warn "Nenhum backup encontrado."
  else
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'manager-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %10s bytes  %f\n' | sort -r
  fi
  pause
}

verify_backup() {
  header
  local file
  read -r -p "Arquivo .tar.gz em $BACKUP_DIR: " file
  [[ "$file" = /* ]] || file="$BACKUP_DIR/$file"
  [[ -f "$file" ]] || { err "Arquivo não encontrado"; pause; return; }
  tar -tzf "$file" >/dev/null || { err "Arquivo corrompido"; pause; return; }
  if [[ -f "$file.sha256" ]]; then
    (cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256") || { err "SHA-256 inválido"; pause; return; }
  fi
  ok "Backup íntegro"
  pause
}

restore_backup() {
  header
  say "${C_WHITE}RESTAURAR BACKUP${C_RESET}\n"
  local file safety
  read -r -p "Arquivo .tar.gz em $BACKUP_DIR: " file
  [[ "$file" = /* ]] || file="$BACKUP_DIR/$file"
  [[ -f "$file" ]] || { err "Arquivo não encontrado"; pause; return; }
  tar -tzf "$file" >/dev/null || { err "Backup inválido"; pause; return; }
  warn "A restauração substitui apenas arquivos listados como gerenciados pelo MANAGER."
  confirm "Restaurar este backup?" || return

  safety="$BACKUP_DIR/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
  local current
  current="$(mktemp)"
  collect_paths > "$current"
  if [[ -s "$current" ]]; then
    tar -C / -czf "$safety" -T "$current"
    chmod 0600 "$safety"
    info "Snapshot de segurança: $safety"
  fi
  rm -f "$current"

  tar -C / -xzf "$file" --no-same-owner
  systemctl daemon-reload || true
  [[ -f /etc/dnsmasq.d/90-manager-adblock.conf ]] && systemctl restart dnsmasq 2>/dev/null || true
  [[ -f /etc/fail2ban/jail.d/99-manager-sshd.local ]] && systemctl restart fail2ban 2>/dev/null || true
  [[ -f /etc/wireguard/wg0.conf ]] && systemctl restart wg-quick@wg0 2>/dev/null || true
  [[ -f /etc/openvpn/server/manager.conf ]] && systemctl restart openvpn-server@manager 2>/dev/null || true
  [[ -f /etc/systemd/system/manager-certbot-renew.timer ]] && systemctl enable --now manager-certbot-renew.timer >/dev/null 2>&1 || true
  if command -v sshd >/dev/null 2>&1 && sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  ok "Backup restaurado"
  pause
}

while true; do
  header
  say "${C_WHITE}BACKUP E ROLLBACK${C_RESET}\n"
  say " 1) Criar backup"
  say " 2) Listar backups"
  say " 3) Verificar integridade"
  say " 4) Restaurar backup"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) create_backup ;;
    2) list_backups ;;
    3) verify_backup ;;
    4) restore_backup ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
