from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"pattern not found in {path}: {old[:120]!r}")
    if text.count(old) != 1:
        raise SystemExit(f"pattern not unique in {path}: {text.count(old)}")
    p.write_text(text.replace(old, new, 1))

# install.sh
replace_once(
    "install.sh",
    '  "modules/telegram_auth.sh"\n  "modules/policy_engine.sh"',
    '  "modules/telegram_auth.sh"\n  "modules/telegram_gateway.sh"\n  "modules/policy_engine.sh"',
)
replace_once(
    "install.sh",
    '"$INSTALL_DIR/modules/telegram_auth.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] A autenticação Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram auth status" >&2\n}\n"$INSTALL_DIR/modules/hive_lifecycle.sh" --install',
    '"$INSTALL_DIR/modules/telegram_auth.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] A autenticação Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram auth status" >&2\n}\n"$INSTALL_DIR/modules/telegram_gateway.sh" --install >/dev/null 2>&1 || {\n  echo "[AVISO] O gateway Telegram 0.9.0 não pôde inicializar seu estado. Use: manager telegram gateway status" >&2\n}\n"$INSTALL_DIR/modules/hive_lifecycle.sh" --install',
)

# manager help and routing
replace_once(
    "manager",
    '  manager telegram auth resolve /CAMINHO/INITDATA | resolve-stdin\n                                  valida initData HMAC/freshness antes do RBAC (0.9.0)\n  manager --diagnostics',
    '  manager telegram auth resolve /CAMINHO/INITDATA | resolve-stdin\n                                  valida initData HMAC/freshness antes do RBAC (0.9.0)\n  manager telegram gateway status\n  manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json\n  manager telegram gateway call-stdin /CAMINHO/REQUEST.json\n                                  executa ações tipadas via Automation v2 sem shell arbitrário (0.9.0)\n  manager --diagnostics',
)
replace_once(
    "manager",
    '      *) err "Uso: manager telegram {identity|auth} ..."; exit 64 ;;',
    '      gateway)\n        case "${3:-status}" in\n          status) exec "$MANAGER_HOME/modules/telegram_gateway.sh" --status ;;\n          call) [[ -n "${4:-}" && -n "${5:-}" ]] || { err "Uso: manager telegram gateway call /CAMINHO/INITDATA /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call "$4" "$5" ;;\n          call-stdin) [[ -n "${4:-}" ]] || { err "Uso: manager telegram gateway call-stdin /CAMINHO/REQUEST.json"; exit 64; }; exec "$MANAGER_HOME/modules/telegram_gateway.sh" --call-stdin "$4" ;;\n          *) err "Uso: manager telegram gateway {status|call|call-stdin} ..."; exit 64 ;;\n        esac\n        ;;\n      *) err "Uso: manager telegram {identity|auth|gateway} ..."; exit 64 ;;',
)
replace_once(
    "manager",
    '  say " ${C_CYAN}43${C_RESET}) Telegram / identidade, autenticação e RBAC"',
    '  say " ${C_CYAN}43${C_RESET}) Telegram / identidade, autenticação, gateway e RBAC"',
)
replace_once(
    "manager",
    '      say "${C_WHITE}TELEGRAM — IDENTIDADE / AUTENTICAÇÃO / RBAC${C_RESET}\\n"\n      "$MANAGER_HOME/modules/telegram_identity.sh" --status || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_auth.sh" --status 2>/dev/null || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_identity.sh" --list 2>/dev/null || true',
    '      say "${C_WHITE}TELEGRAM — IDENTIDADE / AUTENTICAÇÃO / GATEWAY / RBAC${C_RESET}\\n"\n      "$MANAGER_HOME/modules/telegram_identity.sh" --status || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_auth.sh" --status 2>/dev/null || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_gateway.sh" --status 2>/dev/null || true\n      say ""\n      "$MANAGER_HOME/modules/telegram_identity.sh" --list 2>/dev/null || true',
)
replace_once(
    "manager",
    '      say " manager telegram auth resolve /root/initdata.txt"\n      pause',
    '      say " manager telegram auth resolve /root/initdata.txt"\n      say " manager telegram gateway call-stdin /root/request.json < /root/initdata.txt"\n      pause',
)

# docs/TELEGRAM.md
replace_once(
    "docs/TELEGRAM.md",
    '## Próximas fatias da 0.9\n\nA camada Bot/Mini App ainda precisa:\n\n1. criar o gateway Bot/Mini App consumindo somente ações tipadas e allowlisted da Automation v2;\n2. aplicar rate limit e idempotência por requisição no gateway;\n3. implementar telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;\n4. adicionar gate end-to-end do gateway real, mantendo o bot token fora de argv, logs e respostas públicas.\n\nO Telegram será uma interface do control plane já existente, não uma nova autoridade paralela.',
    '''## Gateway tipado para Mini App\n\nO gateway 0.9.0 transforma uma requisição autenticada do Mini App em uma chamada normal da Automation v2, sem executar shell e sem duplicar RBAC. O contrato de entrada é:\n\n```text\nmanager-telegram-gateway-request-v1\n```\n\nFormato:\n\n```json\n{\n  "contract": "manager-telegram-gateway-request-v1",\n  "request_id": "miniapp-00000001",\n  "action_id": "connection.status",\n  "params": {"id": "maria"}\n}\n```\n\nAções inicialmente allowlisted:\n\n- `system.describe`;\n- `node.usage`;\n- `connection.preflight`;\n- `connection.create`;\n- `connection.status`;\n- `connection.revoke`.\n\nCada ação possui schema fechado de parâmetros. Campo desconhecido, ação fora da allowlist ou parâmetro de tipo incorreto é recusado antes da Automation v2. Não existe campo `command`, `shell`, `script` ou caminho executável controlado pelo Telegram.\n\nFluxo de confiança:\n\n```text\nTelegram.WebApp.initData\n  -> HMAC + freshness\n  -> telegram_user_id\n  -> binding Telegram -> principal\n  -> gateway tipado\n  -> Ed25519 v2 do principal\n  -> managerd\n  -> RBAC + node/pool/action scope\n  -> rate limit\n  -> idempotência\n  -> dispatcher allowlisted\n```\n\nO gateway mantém uma credencial Ed25519 de cliente por principal em `/etc/manager/telegram/gateway/credentials/`, `0600`, enquanto a Automation v2 mantém somente a parte pública em seu registry normal. Essa credencial não concede autoridade nova: principal desabilitado, escopo removido ou ação recusada continuam falhando dentro do `managerd`. Se a credencial do gateway for revogada, a ponte prepara uma nova credencial local antes da próxima chamada; o RBAC continua sendo reavaliado.\n\nO `request_id` externo é namespaced por principal antes de entrar na Automation v2. Repetir o mesmo request com a mesma ação/payload recebe o replay idempotente do cache existente; reutilizar o mesmo ID com payload diferente é conflito. O rate limit também é o token bucket já existente da Automation v2 por `(principal_id, action_id)`, portanto não existe uma segunda política paralela.\n\nCLI:\n\n```bash\nmanager telegram gateway status\nmanager telegram gateway call /root/initdata.txt /root/request.json\nprintf '%s' "$TELEGRAM_INIT_DATA" | manager telegram gateway call-stdin /root/request.json\n```\n\nO contrato de saída é `manager-telegram-gateway-v1`. O audit `/var/log/manager/telegram-gateway-audit.jsonl` registra somente IDs, ação, decisão, código e estado de cache; não recebe bot token, initData, hash, assinatura, query_id, credencial privada ou conteúdo da resposta.\n\n## Próximas fatias da 0.9\n\nA camada Telegram ainda precisa:\n\n1. adicionar ingresso autenticado do Telegram Bot (webhook/long polling) para alimentar o mesmo gateway tipado sem confiar em username/chat;\n2. implementar telas e fluxos de sessões, clientes, produtos, cotas, nós e diagnósticos;\n3. expandir o E2E para o transporte real do Bot quando esse ingresso existir.\n\nO Mini App já possui E2E do `initData` até a Automation v2. O Telegram permanece apenas uma interface do control plane existente, não uma nova autoridade paralela.''',
)

# docs/ROADMAP.md
replace_once(
    "docs/ROADMAP.md",
    'Ainda pendente para fechar 0.9.0:\n\n- gateway Bot/Mini App consumindo apenas ações tipadas/allowlisted;\n- rate limit e idempotência de requisições Telegram;\n- gate end-to-end do gateway Telegram.\n\nFases seguintes da série 0.9:',
    '''Gateway Mini App implementado nesta fatia:\n\n- contrato `manager-telegram-gateway-request-v1` com allowlist e schemas fechados por ação;\n- ponte usa credencial Ed25519 v2 do principal e entra pela Automation v2 normal, sem `local-root` na ação final;\n- `managerd` continua sendo a autoridade de role/subject/node/pool/action scope e revalida RBAC antes da idempotência;\n- rate limit reutiliza o bucket da Automation v2 por principal/ação;\n- `request_id` Telegram é namespaced por principal e reutiliza o cache idempotente já existente; payload divergente com o mesmo ID é conflito;\n- `initData`, bot token e credencial privada não entram em argv, audit ou contrato público do gateway;\n- gate E2E cobre HMAC/freshness -> binding -> gateway -> Ed25519 -> RBAC -> dispatcher, replay idempotente, conflito e rate limit.\n\nAinda pendente para fechar toda a integração Bot/Mini App da série 0.9:\n\n- ingresso autenticado do Telegram Bot por webhook/long polling reutilizando o mesmo gateway tipado;\n- telas/fluxos de produto posteriores.\n\nFases seguintes da série 0.9:''',
)

print("telegram gateway integration patched")
