#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/banner"
BANNER_FILE="$STATE_DIR/banner.txt"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="$DROPIN_DIR/70-manager-banner.conf"

ssh_unit() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    printf 'ssh'
  else
    printf 'sshd'
  fi
}

validate_and_reload() {
  local unit
  if ! sshd -t; then
    err "A configuração SSH não passou em sshd -t."
    return 1
  fi
  unit="$(ssh_unit)"
  systemctl reload "$unit"
}

show_banner() {
  header
  say "${C_WHITE}BANNER SSH${C_RESET}\n"
  if [[ -s "$BANNER_FILE" ]]; then
    cat "$BANNER_FILE"
  else
    info "Nenhum banner do MANAGER foi definido."
  fi
  say ""
  if [[ -f "$DROPIN_FILE" ]]; then
    ok "Banner habilitado no OpenSSH"
  else
    info "Banner desabilitado no OpenSSH"
  fi
  pause
}

edit_banner() {
  header
  say "${C_WHITE}EDITAR BANNER SSH${C_RESET}\n"
  say "Digite o texto. Finalize com uma linha contendo apenas um ponto (.)."
  say ""

  local tmp line
  tmp="$(mktemp)"
  while IFS= read -r line; do
    [[ "$line" == "." ]] && break
    printf '%s\n' "$line" >> "$tmp"
  done

  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    err "Banner vazio; nenhuma alteração feita."
    pause
    return
  fi

  mkdir -p "$STATE_DIR"
  chmod 0755 "$STATE_DIR"
  install -m 0644 "$tmp" "$BANNER_FILE"
  rm -f "$tmp"
  ok "Banner salvo em $BANNER_FILE"
  pause
}

enable_banner() {
  header
  say "${C_WHITE}HABILITAR BANNER SSH${C_RESET}\n"
  [[ -s "$BANNER_FILE" ]] || {
    err "Defina o texto do banner primeiro."
    pause
    return
  }
  command_exists sshd || { err "sshd não encontrado"; pause; return; }

  mkdir -p "$DROPIN_DIR"
  backup_file "$DROPIN_FILE"
  printf 'Banner %s\n' "$BANNER_FILE" > "$DROPIN_FILE"
  chmod 0644 "$DROPIN_FILE"

  if validate_and_reload; then
    ok "Banner habilitado"
  else
    rm -f "$DROPIN_FILE"
    sshd -t >/dev/null 2>&1 && systemctl reload "$(ssh_unit)" || true
    err "Alteração revertida"
  fi
  pause
}

disable_banner() {
  header
  say "${C_WHITE}DESABILITAR BANNER SSH${C_RESET}\n"
  [[ -f "$DROPIN_FILE" ]] || { info "Banner já está desabilitado"; pause; return; }
  backup_file "$DROPIN_FILE"
  rm -f "$DROPIN_FILE"
  if validate_and_reload; then
    ok "Banner desabilitado. O texto foi preservado em $BANNER_FILE"
  else
    err "A configuração SSH restante está inválida; revise o OpenSSH."
  fi
  pause
}

while true; do
  header
  say "${C_WHITE}BANNER SSH${C_RESET}\n"
  say " 1) Ver banner e estado"
  say " 2) Editar banner"
  say " 3) Habilitar no OpenSSH"
  say " 4) Desabilitar no OpenSSH"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) show_banner ;;
    2) edit_banner ;;
    3) enable_banner ;;
    4) disable_banner ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
