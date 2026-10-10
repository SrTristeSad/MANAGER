#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

EXPORT_DIR="/var/backups/manager/users"
LIMITS_FILE="/etc/security/limits.d/99-manager-ssh.conf"
OWNERS_DIR="$MANAGER_ETC/access/owners"

is_regular_login_user() {
  local uid="$1" shell="$2"
  (( uid >= 1000 && uid < 65534 )) || return 1
  [[ ! "$shell" =~ (nologin|false)$ ]]
}

field_from_owner() {
  local user="$1" file="$OWNERS_DIR/$user"
  [[ -f "$file" ]] || return 0
  awk -F= '$1=="owner" {print $2; exit}' "$file" 2>/dev/null || true
}

limit_for_user() {
  awk -v u="$1" '$1==u && $3=="maxlogins" {print $4}' "$LIMITS_FILE" 2>/dev/null | tail -n1
}

create_export() {
  header
  say "${C_WHITE}EXPORTAR USUÁRIOS SSH${C_RESET}\n"
  mkdir -p "$EXPORT_DIR"
  chmod 0700 "$EXPORT_DIR"

  local work data manifest user uid shell shadow hash expire limit owner stamp archive count=0
  work="$(mktemp -d)"
  data="$work/users.db"
  manifest="$work/manifest"
  : > "$data"

  while IFS=: read -r user _ uid _ _ _ shell; do
    is_regular_login_user "$uid" "$shell" || continue
    shadow="$(getent shadow "$user" 2>/dev/null || true)"
    [[ -n "$shadow" ]] || { warn "Sem shadow para $user; ignorando"; continue; }
    hash="$(printf '%s\n' "$shadow" | awk -F: '{print $2}')"
    expire="$(printf '%s\n' "$shadow" | awk -F: '{print $8}')"
    limit="$(limit_for_user "$user")"
    owner="$(field_from_owner "$user")"
    [[ -n "$limit" ]] || limit=0

    if [[ "$user$hash$expire$shell$owner" == *'|'* ]]; then
      warn "Campo incompatível em $user; ignorando por segurança"
      continue
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$user" "$hash" "$expire" "$shell" "$limit" "$owner" >> "$data"
    count=$((count + 1))
  done < /etc/passwd

  {
    printf 'format=manager-users-v1\n'
    printf 'created=%s\n' "$(date -Is)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'users=%s\n' "$count"
    printf 'passwords=shadow-hashes-only\n'
  } > "$manifest"
  chmod 0600 "$data" "$manifest"

  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="$EXPORT_DIR/manager-users-$stamp.tar.gz"
  tar -C "$work" -czf "$archive" manifest users.db
  chmod 0600 "$archive"
  sha256sum "$archive" > "$archive.sha256"
  chmod 0600 "$archive.sha256"
  rm -rf "$work"

  ok "$count usuário(s) exportado(s)"
  say "Arquivo: $archive"
  warn "O arquivo contém hashes de senha e deve ser tratado como segredo. Ele nunca é publicado por HTTP pelo MANAGER."
  pause
}

list_exports() {
  header
  say "${C_WHITE}EXPORTAÇÕES DE USUÁRIOS${C_RESET}\n"
  mkdir -p "$EXPORT_DIR"
  chmod 0700 "$EXPORT_DIR"
  if ! compgen -G "$EXPORT_DIR/manager-users-*.tar.gz" >/dev/null; then
    info "Nenhuma exportação encontrada"
  else
    find "$EXPORT_DIR" -maxdepth 1 -type f -name 'manager-users-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %10s bytes  %f\n' | sort -r
  fi
  pause
}

resolve_export() {
  local input="$1" base
  base="$(basename -- "$input")"
  [[ "$base" == manager-users-*.tar.gz ]] || return 1
  printf '%s/%s\n' "$EXPORT_DIR" "$base"
}

validate_export() {
  local file="$1" entry
  tar -tzf "$file" >/dev/null || return 1
  if tar -tvzf "$file" | awk '$1 ~ /^[lh]/ {found=1} END {exit !found}'; then
    err "Exportação contém links; recusada"
    return 1
  fi
  while IFS= read -r entry; do
    case "$entry" in
      manifest|users.db) ;;
      *) err "Entrada inesperada na exportação: $entry"; return 1 ;;
    esac
  done < <(tar -tzf "$file")
  [[ -f "$file.sha256" ]] || { err "SHA-256 ausente"; return 1; }
  (cd "$EXPORT_DIR" && sha256sum -c "$(basename "$file").sha256" >/dev/null)
}

set_limit() {
  local user="$1" limit="$2" tmp
  [[ "$limit" =~ ^[0-9]+$ ]] || return 0
  mkdir -p "$(dirname "$LIMITS_FILE")"
  touch "$LIMITS_FILE"
  tmp="$(mktemp)"
  awk -v u="$user" '$1 != u {print}' "$LIMITS_FILE" > "$tmp"
  if (( limit > 0 && limit <= 50 )); then
    printf '%s hard maxlogins %s\n' "$user" "$limit" >> "$tmp"
  fi
  install -m 0644 "$tmp" "$LIMITS_FILE"
  rm -f "$tmp"
}

restore_export() {
  header
  say "${C_WHITE}RESTAURAR USUÁRIOS SSH${C_RESET}\n"
  local input file work format user hash expire shell limit owner restored=0 skipped=0 failed=0 expdate
  read -r -p "Arquivo em $EXPORT_DIR: " input
  file="$(resolve_export "$input")" || { err "Nome inválido"; pause; return; }
  [[ -f "$file" ]] || { err "Arquivo não encontrado"; pause; return; }
  validate_export "$file" || { err "Exportação inválida"; pause; return; }

  work="$(mktemp -d)"
  tar -C "$work" -xzf "$file"
  format="$(awk -F= '$1=="format" {print $2; exit}' "$work/manifest")"
  if [[ "$format" != manager-users-v1 ]]; then
    rm -rf "$work"
    err "Formato não suportado: $format"
    pause
    return
  fi

  warn "Contas já existentes não serão sobrescritas. O MANAGER recria cada usuário individualmente; /etc/passwd e /etc/shadow nunca são substituídos."
  confirm "Continuar a restauração?" || { rm -rf "$work"; return; }

  while IFS='|' read -r user hash expire shell limit owner; do
    [[ -n "$user" ]] || continue
    if ! is_valid_username "$user" || [[ "$user" == root ]]; then
      warn "Entrada inválida ignorada: $user"
      failed=$((failed + 1))
      continue
    fi
    if id "$user" >/dev/null 2>&1; then
      info "$user já existe; ignorado"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$shell" != /* || ! -x "$shell" || "$shell" =~ (nologin|false)$ ]]; then
      shell="/bin/bash"
    fi

    if ! useradd -m -s "$shell" "$user"; then
      err "Falha ao criar $user"
      failed=$((failed + 1))
      continue
    fi
    if [[ -n "$hash" ]]; then
      usermod -p "$hash" "$user" || true
    fi
    if [[ "$expire" =~ ^[0-9]+$ ]] && (( expire > 0 )); then
      expdate="$(date -d "@$((expire * 86400))" '+%F' 2>/dev/null || true)"
      [[ -z "$expdate" ]] || chage -E "$expdate" "$user"
    fi
    set_limit "$user" "$limit"

    if [[ -n "$owner" && -x "$MANAGER_HOME/modules/resellers.sh" ]]; then
      if ! "$MANAGER_HOME/modules/resellers.sh" --assign "$user" "$owner" >/dev/null 2>&1; then
        warn "$user restaurado, mas propriedade $owner não pôde ser aplicada"
      fi
    fi
    restored=$((restored + 1))
  done < "$work/users.db"

  rm -rf "$work"
  ok "Restauração concluída: $restored criada(s), $skipped existente(s), $failed falha(s)"
  pause
}

inspect_legacy() {
  header
  say "${C_WHITE}DETECÇÃO SSHPLUS LEGADO${C_RESET}\n"
  local found=0 count=0
  if [[ -f /root/usuarios.db ]]; then
    found=1
    count="$(awk 'NF {c++} END {print c+0}' /root/usuarios.db)"
    printf ' %-28s %s\n' '/root/usuarios.db:' "$count linha(s)"
  fi
  if [[ -d /etc/SSHPlus/senha ]]; then
    found=1
    count="$(find /etc/SSHPlus/senha -maxdepth 1 -type f 2>/dev/null | wc -l)"
    printf ' %-28s %s\n' '/etc/SSHPlus/senha:' "$count arquivo(s)"
  fi
  if [[ -f /root/backup.vps ]]; then
    found=1
    printf ' %-28s %s\n' '/root/backup.vps:' "encontrado"
  fi
  if (( found == 0 )); then
    info "Nenhuma estrutura SSHPlus conhecida foi encontrada"
  else
    warn "Esta versão somente detecta o legado. Ela não extrai /etc/shadow nem sobrescreve bancos do sistema a partir de backup.vps. A migração específica do SSHPlus será feita por conversão controlada."
  fi
  pause
}

while true; do
  header
  say "${C_WHITE}BACKUP E MIGRAÇÃO DE USUÁRIOS SSH${C_RESET}\n"
  say " 1) Exportar usuários"
  say " 2) Listar exportações"
  say " 3) Restaurar exportação MANAGER"
  say " 4) Detectar instalação/backup SSHPlus antigo"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) create_export ;;
    2) list_exports ;;
    3) restore_export ;;
    4) inspect_legacy ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
