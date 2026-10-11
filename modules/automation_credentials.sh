#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

STATE_DIR="$MANAGER_ETC/automation/v2"
PRINCIPALS_DIR="$STATE_DIR/principals"
CREDENTIALS_DIR="$STATE_DIR/credentials"
LOCAL_ROOT_ID="local-root"

valid_principal_id() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$ ]]; }
valid_key_id() { [[ "${1:-}" =~ ^ed25519-[a-f0-9]{16}$ ]]; }
principal_file() { printf '%s/%s.conf\n' "$PRINCIPALS_DIR" "$1"; }
principal_credentials_dir() { printf '%s/%s\n' "$CREDENTIALS_DIR" "$1"; }
credential_meta_file() { printf '%s/%s/%s.conf\n' "$CREDENTIALS_DIR" "$1" "$2"; }
credential_pub_file() { printf '%s/%s/%s.pub\n' "$CREDENTIALS_DIR" "$1" "$2"; }

read_field() {
  local file="$1" key="$2"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file" 2>/dev/null || true
}

ensure_openssl() {
  command -v openssl >/dev/null 2>&1 || {
    err "OpenSSL é necessário para credenciais Ed25519."
    return 69
  }
}

init_state() {
  install -d -m 0700 "$STATE_DIR" "$PRINCIPALS_DIR" "$CREDENTIALS_DIR"
  ensure_openssl
}

require_principal() {
  local id="$1" file
  valid_principal_id "$id" || { err "principal_id inválido"; return 64; }
  [[ "$id" != "$LOCAL_ROOT_ID" ]] || {
    err "$LOCAL_ROOT_ID usa autenticação local por SO_PEERCRED e não recebe credencial criptográfica."
    return 67
  }
  file="$(principal_file "$id")"
  [[ -f "$file" ]] || { err "Principal não existe: $id"; return 66; }
}

public_fingerprint() {
  local pub="$1" value
  value="$(openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '\n=')" || return 1
  [[ -n "$value" ]] || return 1
  printf 'SHA256:%s\n' "$value"
}

public_key_hex() {
  local pub="$1"
  openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}'
}

write_meta() {
  local principal_id="$1" key_id="$2" fingerprint="$3" enabled="$4" created="$5" revoked="$6" dir tmp
  dir="$(principal_credentials_dir "$principal_id")"
  install -d -m 0700 "$dir"
  tmp="$(mktemp "$dir/.meta.XXXXXX")"
  {
    printf 'version=1\n'
    printf 'principal_id=%s\n' "$principal_id"
    printf 'key_id=%s\n' "$key_id"
    printf 'algorithm=ed25519\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'enabled=%s\n' "$enabled"
    printf 'created_epoch=%s\n' "$created"
    printf 'revoked_epoch=%s\n' "$revoked"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$(credential_meta_file "$principal_id" "$key_id")"
}

revoke_key_internal() {
  local principal_id="$1" key_id="$2" now="${3:-$(date +%s)}" meta fingerprint created
  meta="$(credential_meta_file "$principal_id" "$key_id")"
  [[ -f "$meta" ]] || return 66
  fingerprint="$(read_field "$meta" fingerprint)"
  created="$(read_field "$meta" created_epoch)"
  [[ "$created" =~ ^[0-9]+$ ]] || created="$now"
  write_meta "$principal_id" "$key_id" "$fingerprint" 0 "$created" "$now"
}

create_bundle() {
  local principal_id="$1" key_id="$2" fingerprint="$3" private_key="$4" output="$5"
  [[ "$output" == /* ]] || { err "O arquivo da credencial deve usar caminho absoluto."; return 64; }
  [[ ! -e "$output" && ! -L "$output" ]] || { err "Arquivo de credencial já existe: $output"; return 65; }
  [[ -d "$(dirname "$output")" ]] || { err "Diretório de destino não existe: $(dirname "$output")"; return 66; }

  python3 - "$principal_id" "$key_id" "$fingerprint" "$private_key" "$output" <<'PY'
import json
import os
import sys

principal_id, key_id, fingerprint, private_path, output = sys.argv[1:]
with open(private_path, "r", encoding="utf-8") as fh:
    private_pem = fh.read()
payload = {
    "version": 1,
    "principal_id": principal_id,
    "key_id": key_id,
    "algorithm": "ed25519",
    "fingerprint": fingerprint,
    "private_key_pem": private_pem,
}
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
fd = os.open(output, flags, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
finally:
    try:
        os.chmod(output, 0o600)
    except FileNotFoundError:
        pass
PY
}

enroll_key() {
  local principal_id="${1:-}" output="${2:-}" rotate="${3:-0}" tmp private pub hex key_id fingerprint now dir meta
  init_state
  require_principal "$principal_id" || return $?
  [[ -n "$output" ]] || { err "Informe o arquivo de saída da credencial."; return 64; }
  [[ "$rotate" == 0 || "$rotate" == 1 ]] || return 64

  tmp="$(mktemp -d "$STATE_DIR/.enroll.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  private="$tmp/private.pem"
  pub="$tmp/public.pem"
  umask 077
  openssl genpkey -algorithm ED25519 -out "$private" >/dev/null 2>&1 || { err "Falha ao gerar chave Ed25519"; return 70; }
  openssl pkey -in "$private" -pubout -out "$pub" >/dev/null 2>&1 || { err "Falha ao extrair chave pública"; return 70; }
  chmod 0600 "$private" "$pub"

  hex="$(public_key_hex "$pub")"
  [[ "$hex" =~ ^[a-f0-9]{64}$ ]] || { err "Falha ao calcular key_id"; return 70; }
  key_id="ed25519-${hex:0:16}"
  fingerprint="$(public_fingerprint "$pub")" || { err "Falha ao calcular fingerprint"; return 70; }
  valid_key_id "$key_id" || return 70

  dir="$(principal_credentials_dir "$principal_id")"
  install -d -m 0700 "$dir"
  meta="$(credential_meta_file "$principal_id" "$key_id")"
  [[ ! -e "$meta" && ! -e "$(credential_pub_file "$principal_id" "$key_id")" ]] || {
    err "Colisão de key_id inesperada: $key_id"
    return 65
  }

  # A credencial privada é criada primeiro. Se o registro público falhar, nenhuma
  # chave nova fica ativa no daemon e o arquivo pode ser descartado com segurança.
  create_bundle "$principal_id" "$key_id" "$fingerprint" "$private" "$output" || return $?

  install -m 0600 "$pub" "$(credential_pub_file "$principal_id" "$key_id")"
  now="$(date +%s)"
  write_meta "$principal_id" "$key_id" "$fingerprint" 1 "$now" 0

  if [[ "$rotate" == 1 ]]; then
    local old old_id
    for old in "$dir"/*.conf; do
      [[ -f "$old" ]] || continue
      old_id="$(read_field "$old" key_id)"
      [[ "$old_id" == "$key_id" ]] && continue
      [[ "$(read_field "$old" enabled)" == 1 ]] || continue
      revoke_key_internal "$principal_id" "$old_id" "$now" || true
    done
  fi

  printf 'principal_id=%s\n' "$principal_id"
  printf 'key_id=%s\n' "$key_id"
  printf 'algorithm=ed25519\n'
  printf 'fingerprint=%s\n' "$fingerprint"
  printf 'credential_file=%s\n' "$output"
  printf 'private_key_stored_server=0\n'
  [[ "$rotate" == 1 ]] && printf 'rotation=completed\n'
}

revoke_key() {
  local principal_id="${1:-}" key_id="${2:-}" meta
  init_state
  require_principal "$principal_id" || return $?
  valid_key_id "$key_id" || { err "key_id inválido"; return 64; }
  meta="$(credential_meta_file "$principal_id" "$key_id")"
  [[ -f "$meta" ]] || { err "Credencial não existe: $key_id"; return 66; }
  if [[ "$(read_field "$meta" enabled)" == 0 ]]; then
    printf 'principal_id=%s\nkey_id=%s\nenabled=0\nalready_revoked=1\n' "$principal_id" "$key_id"
    return 0
  fi
  revoke_key_internal "$principal_id" "$key_id" "$(date +%s)"
  printf 'principal_id=%s\nkey_id=%s\nenabled=0\n' "$principal_id" "$key_id"
}

show_key() {
  local principal_id="${1:-}" key_id="${2:-}" meta
  init_state
  valid_principal_id "$principal_id" || return 64
  valid_key_id "$key_id" || return 64
  meta="$(credential_meta_file "$principal_id" "$key_id")"
  [[ -f "$meta" ]] || return 66
  cat "$meta"
}

list_keys() {
  local principal_id="${1:-}" dir meta found=0
  init_state
  valid_principal_id "$principal_id" || return 64
  dir="$(principal_credentials_dir "$principal_id")"
  printf '%-28s %-28s %-54s %-8s %-12s %-12s\n' "PRINCIPAL" "KEY_ID" "FINGERPRINT" "ENABLED" "CREATED" "REVOKED"
  [[ -d "$dir" ]] || return 1
  for meta in "$dir"/*.conf; do
    [[ -f "$meta" ]] || continue
    found=1
    printf '%-28s %-28s %-54s %-8s %-12s %-12s\n' \
      "$(read_field "$meta" principal_id)" \
      "$(read_field "$meta" key_id)" \
      "$(read_field "$meta" fingerprint)" \
      "$(read_field "$meta" enabled)" \
      "$(read_field "$meta" created_epoch)" \
      "$(read_field "$meta" revoked_epoch)"
  done
  (( found == 1 )) || return 1
}

interactive_enroll() {
  local id output rotate="$1"
  header
  read -r -p "Principal ID: " id
  read -r -p "Arquivo absoluto para salvar a credencial privada (novo arquivo): " output
  if enroll_key "$id" "$output" "$rotate"; then
    ok "Credencial criada. Guarde o arquivo privado fora do servidor quando possível."
  fi
  pause
}

interactive_revoke() {
  local id key_id
  header
  read -r -p "Principal ID: " id
  read -r -p "Key ID: " key_id
  if revoke_key "$id" "$key_id"; then ok "Credencial revogada"; fi
  pause
}

case "${1:-}" in
  --init) init_state; printf '%s\n' "$CREDENTIALS_DIR"; exit 0 ;;
  --enroll) enroll_key "${2:-}" "${3:-}" 0; exit $? ;;
  --rotate) enroll_key "${2:-}" "${3:-}" 1; exit $? ;;
  --revoke) revoke_key "${2:-}" "${3:-}"; exit $? ;;
  --show) show_key "${2:-}" "${3:-}"; exit $? ;;
  --list) list_keys "${2:-}"; exit $? ;;
esac

init_state
while true; do
  header
  say "${C_WHITE}AUTOMATION V2 — CREDENCIAIS ED25519${C_RESET}\n"
  say " 1) Listar credenciais de um principal"
  say " 2) Enrollment (nova credencial)"
  say " 3) Rotacionar (nova credencial + revogar anteriores)"
  say " 4) Revogar credencial"
  say " 5) Mostrar metadados de credencial"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) header; read -r -p "Principal ID: " id; list_keys "$id" || warn "Nenhuma credencial"; pause ;;
    2) interactive_enroll 0 ;;
    3) interactive_enroll 1 ;;
    4) interactive_revoke ;;
    5) header; read -r -p "Principal ID: " id; read -r -p "Key ID: " key_id; show_key "$id" "$key_id" || err "Credencial não encontrada"; pause ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
