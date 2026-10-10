#!/usr/bin/env bash
set -Eeuo pipefail

MANAGER_HOME="${MANAGER_HOME:-/opt/manager}"
MANAGER_ETC="${MANAGER_ETC:-/etc/manager}"
# shellcheck source=/dev/null
source "$MANAGER_HOME/lib/common.sh"
require_root

CERTBOT_HOME="/opt/certbot"
CERTBOT_BIN="/usr/local/bin/certbot"
STATE_DIR="$MANAGER_ETC/tls"
SERVICE="/etc/systemd/system/manager-certbot-renew.service"
TIMER="/etc/systemd/system/manager-certbot-renew.timer"

valid_domain() {
  local d="${1,,}"
  [[ ${#d} -le 253 ]] || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

install_certbot() {
  header
  say "${C_WHITE}INSTALAR CERTBOT${C_RESET}\n"
  if [[ -x "$CERTBOT_HOME/bin/certbot" ]]; then
    ok "Certbot já está instalado em $CERTBOT_HOME"
    pause
    return
  fi
  confirm "Instalar Certbot em um virtualenv isolado?" || return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y python3 python3-venv ca-certificates
  python3 -m venv "$CERTBOT_HOME"
  "$CERTBOT_HOME/bin/pip" install --upgrade pip
  "$CERTBOT_HOME/bin/pip" install certbot
  ln -sfn "$CERTBOT_HOME/bin/certbot" "$CERTBOT_BIN"
  mkdir -p "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
  install_timer
  ok "Certbot instalado"
  pause
}

install_timer() {
  cat > "$SERVICE" <<EOF
[Unit]
Description=Renew Let's Encrypt certificates managed with Certbot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$CERTBOT_BIN renew -q
EOF

  cat > "$TIMER" <<'EOF'
[Unit]
Description=Twice-daily Certbot renewal check

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now manager-certbot-renew.timer >/dev/null 2>&1
}

ensure_certbot() {
  if [[ ! -x "$CERTBOT_BIN" ]]; then
    err "Certbot ainda não está instalado pelo MANAGER."
    pause
    return 1
  fi
}

check_domain() {
  local domain="$1" public_ip resolved
  public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -n "$public_ip" && -n "$resolved" && "$public_ip" != "$resolved" ]]; then
    warn "$domain resolve para $resolved, mas o IP público detectado é $public_ip."
    warn "A validação pode falhar se não houver proxy/NAT configurado corretamente."
    confirm "Continuar mesmo assim?" || return 1
  elif [[ -z "$resolved" ]]; then
    warn "Não consegui resolver $domain em IPv4."
    confirm "Continuar mesmo assim?" || return 1
  fi
}

open_http_if_ufw() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    if ! ufw status | grep -Eq '(^|[[:space:]])80/tcp[[:space:]]+ALLOW'; then
      warn "UFW está ativo e o ACME HTTP-01 precisa receber conexões na porta 80."
      if confirm "Liberar 80/tcp para emissão e renovações?"; then
        ufw allow 80/tcp comment 'MANAGER ACME' >/dev/null
      else
        return 1
      fi
    fi
  fi
}

read_identity() {
  local domain email
  read -r -p "Domínio (ex.: vpn.example.com): " domain
  domain="${domain,,}"
  valid_domain "$domain" || { err "Domínio inválido"; return 1; }
  read -r -p "E-mail para Let's Encrypt: " email
  valid_email "$email" || { err "E-mail inválido"; return 1; }
  printf '%s\n%s\n' "$domain" "$email"
}

issue_standalone() {
  header
  ensure_certbot || return
  say "${C_WHITE}CERTIFICADO - STANDALONE${C_RESET}\n"
  if ss -Hln 'sport = :80' 2>/dev/null | grep -q .; then
    err "A porta 80 já está ocupada. O MANAGER não vai parar seu servidor web automaticamente."
    info "Use o modo Webroot ou libere a porta 80 manualmente."
    pause
    return
  fi
  local identity domain email
  identity="$(read_identity)" || { pause; return; }
  domain="$(sed -n '1p' <<< "$identity")"
  email="$(sed -n '2p' <<< "$identity")"
  check_domain "$domain" || { pause; return; }
  open_http_if_ufw || { pause; return; }
  warn "A porta TCP 80 também precisa estar liberada no firewall do provedor/cloud."
  confirm "Solicitar certificado para $domain?" || return
  if "$CERTBOT_BIN" certonly --standalone --preferred-challenges http \
      --non-interactive --agree-tos --no-eff-email -m "$email" -d "$domain"; then
    install_timer
    ok "Certificado emitido"
    show_paths "$domain"
  else
    err "Falha na emissão. Verifique DNS e acesso externo à porta 80."
  fi
  pause
}

issue_webroot() {
  header
  ensure_certbot || return
  say "${C_WHITE}CERTIFICADO - WEBROOT${C_RESET}\n"
  local identity domain email webroot
  identity="$(read_identity)" || { pause; return; }
  domain="$(sed -n '1p' <<< "$identity")"
  email="$(sed -n '2p' <<< "$identity")"
  read -r -p "Diretório webroot público: " webroot
  [[ -d "$webroot" ]] || { err "Diretório não existe"; pause; return; }
  check_domain "$domain" || { pause; return; }
  open_http_if_ufw || { pause; return; }
  warn "Seu servidor HTTP precisa servir $webroot em http://$domain/.well-known/acme-challenge/."
  confirm "Solicitar certificado?" || return
  if "$CERTBOT_BIN" certonly --webroot -w "$webroot" \
      --non-interactive --agree-tos --no-eff-email -m "$email" -d "$domain"; then
    install_timer
    ok "Certificado emitido"
    show_paths "$domain"
  else
    err "Falha na emissão. Verifique webroot, DNS e porta 80."
  fi
  pause
}

show_paths() {
  local domain="$1"
  say "\nArquivos esperados:"
  say "  Certificado: /etc/letsencrypt/live/$domain/fullchain.pem"
  say "  Chave:       /etc/letsencrypt/live/$domain/privkey.pem"
}

list_certs() {
  header
  ensure_certbot || return
  say "${C_WHITE}CERTIFICADOS${C_RESET}\n"
  "$CERTBOT_BIN" certificates || true
  pause
}

test_renewal() {
  header
  ensure_certbot || return
  say "${C_WHITE}TESTE DE RENOVAÇÃO${C_RESET}\n"
  "$CERTBOT_BIN" renew --dry-run
  pause
}

renew_now() {
  header
  ensure_certbot || return
  "$CERTBOT_BIN" renew
  pause
}

delete_cert() {
  header
  ensure_certbot || return
  local name
  "$CERTBOT_BIN" certificates || true
  read -r -p "Certificate Name para remover: " name
  [[ -n "$name" ]] || { err "Nome vazio"; pause; return; }
  warn "Isso remove o certificado do Certbot; serviços que o usam podem parar."
  confirm "Remover $name?" || return
  "$CERTBOT_BIN" delete --cert-name "$name"
  pause
}

while true; do
  header
  say "${C_WHITE}TLS / LET'S ENCRYPT${C_RESET}\n"
  say " 1) Instalar Certbot"
  say " 2) Emitir certificado (standalone)"
  say " 3) Emitir certificado (webroot)"
  say " 4) Listar certificados"
  say " 5) Testar renovação"
  say " 6) Renovar agora"
  say " 7) Remover certificado"
  say " 0) Voltar"
  say ""
  read -r -p "Opção: " opt
  case "$opt" in
    1) install_certbot ;;
    2) issue_standalone ;;
    3) issue_webroot ;;
    4) list_certs ;;
    5) test_renewal ;;
    6) renew_now ;;
    7) delete_cert ;;
    0) exit 0 ;;
    *) warn "Opção inválida"; sleep 1 ;;
  esac
done
