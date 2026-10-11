# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. O objetivo é preservar as capacidades úteis do ecossistema SSHPlus, modernizar a implementação e adicionar automação segura e operação multi-servidor sem copiar fragilidades históricas.

## Princípios

- O MANAGER novo não deve ser funcionalmente capado em relação ao SSHPlus útil.
- Compatibilidade não significa copiar práticas inseguras do legado.
- Operações privilegiadas passam por ações conhecidas e auditáveis; integrações nunca recebem shell arbitrário.
- Nenhum módulo deve limpar o firewall global, sobrescrever todo o SSH ou usar permissões `777`.
- Estado durável de identidade, fencing e autoridade é preservado em update/rollback/uninstall normal.
- Administração remota futura será centrada em Telegram Bot + Telegram Mini App, sem depender de painel web administrativo convencional.
- A Colmeia só começa depois que autenticação e autorização da Automation v2 estiverem estabilizadas.

## 0.4.x — Fundação ✅

Concluído:

- health check e manutenção;
- CLI não interativa;
- atualização/rollback conservadores;
- CI com Bash syntax, ShellCheck e regressões de segurança;
- política segura de fontes/downloads.

## 0.5.x — Paridade SSHPlus útil ✅

Concluído:

- contas SSH, contas teste, expirados e monitor de sessões;
- backup/migração segura de usuários;
- banner, speedtest e serviços;
- hosts de proxy, Squid privado, TCP, WebSocket e TLS;
- revendedores/subrevendedores, cotas e propriedade;
- criação vinculada à revenda sob lock.

Recursos antigos dependentes de técnicas inseguras recebem implementação moderna equivalente, não cópia literal.

## 0.6.x — Connection / Policy / Session Engine ✅

### 0.6.0 — identidade comum

- identidade MANAGER independente de `/etc/passwd`;
- SSH/WireGuard/OpenVPN por identidade;
- owner, expiração, protocolos e `max_sessions`;
- bindings para recursos técnicos.

### 0.6.1 — enforcement

- estado efetivo aplicado aos protocolos;
- `DenyUsers`/limites SSH sem substituir `sshd_config`;
- WireGuard removido/restaurado somente em runtime;
- OpenVPN bloqueável de forma reversível;
- reconciliação automática.

### 0.6.2 — Session / Lease Engine

- `session_id`, TTL, heartbeat e release;
- aquisição idempotente;
- limite local atômico sob lock;
- `session_epoch`, fencing, switch e revoke-all;
- leases separadas da visão de sessões observadas.

### 0.6.3 — Protocol Lease Bridge

- SSH via PAM `open_session/close_session`;
- OpenVPN via fila runtime privilegiada e allowlisted;
- WireGuard via handshake recente + gate específico do peer;
- reconciliação, heartbeat e adoção de sessões existentes;
- lifecycle seguro de hooks em update/rollback/uninstall.

### 0.6.4 — Identity Usage

- atividade e accounting comum por identidade;
- bytes reais de WireGuard/OpenVPN por delta;
- reset/restart de contador sem perder acumulado;
- SSH marcado explicitamente como cobertura parcial de bytes;
- estado durável e coleta periódica.

### 0.6.5 — produtos, ACL e franquias

- catálogo de planos separado das credenciais;
- restrição de protocolos/sessões/validade;
- franquia `monthly`/`lifetime`, `warn`/`block`;
- ACL de região/pool/nó;
- produto restringe e nunca amplia silenciosamente a política base.

### 0.6.6 — provisionamento unificado

- `manager --provision ID PLAN [OWNER] [PROTOCOLS]`;
- preflight;
- identidade + produto + recursos + bindings numa transação;
- rollback de falha intermediária;
- senha SSH one-shot;
- revogação centralizada.

### 0.6.7 — cotas de revenda por identidade/produto

- unidade de cota = identidade lógica;
- VPN-only pode pertencer à revenda;
- slots sob lock;
- pai inclui subrevendedor;
- cota opcional por produto;
- deduplicação de conta SSH legada absorvida por identidade.

### 0.6.8 — IPv6 / dual-stack

- WireGuard/OpenVPN dual-stack somente com egress IPv6 real;
- IPv6 Guard ligado à mesma autoridade Policy/Session;
- regras específicas sem flush global;
- ULA + NAT66 como modo portátil atual.

### 0.6.9 — identidade/metadados do nó

- `node_id` persistente;
- country/region/pool/provider/city/capacity/weight/max_sessions/enabled;
- contexto local consumível por ACL e futura Colmeia.

### 0.6.10 — ACL automática pelo nó

- Product Policy resolve região/pool/node local automaticamente;
- ACL restrita falha fechada;
- Session Engine usa a mesma autorização.

### 0.6.11 — fechamento da série 0.6

- `manager-connection-actions-v1`: `preflight/create/status/revoke/describe` allowlisted;
- `manager-node-usage-v1`: telemetria local por nó;
- sem shell/comando/caminho arbitrário;
- telemetria local marcada como não autoritativa para billing global.

## 0.7.x — Automation Engine

A série 0.7 cria a superfície oficial de integração. Ela deve estar estabilizada **antes** da Colmeia.

### 0.7.0 — Automation Legacy v1 ✅

- compatibilidade controlada com `syncpainel` e painéis antigos;
- desligado por padrão;
- listener OpenSSH dedicado;
- conta não-root `manager-legacy`;
- `ForceCommand`, sudoers exato e allowlist;
- senha de integração one-shot;
- lifecycle e CI próprios.

Documentação: `docs/AUTOMATION_LEGACY.md`.

### 0.7.1 — Automation v2: núcleo local estruturado ✅

- `managerd` + `managerctl`;
- socket Unix `/run/manager-automation-v2/manager.sock`;
- runtime `0700`, socket `0600`, `SO_PEERCRED`;
- contrato `manager-automation-v2-local-v1`;
- envelope JSON versionado;
- `request_id`, `action_id` e códigos estáveis;
- allowlist de `system.describe`, `node.usage` e lifecycle `connection.*`;
- nenhuma ação de shell/comando/caminho arbitrário;
- idempotência persistente;
- segredo one-shot fora do cache;
- audit JSONL sem senha/chaves privadas;
- lifecycle install/update/rollback/uninstall/reinstall.

### 0.7.2 — Principals e RBAC ✅

- registry root-only em `/etc/manager/automation/v2/principals`;
- principal reservado `local-root`;
- roles `admin`, `reseller`, `subreseller` e `user`;
- revenda reutiliza `/etc/manager/access/resellers`;
- principal `user` ligado a identidade do Connection Engine;
- escopo por owner, identidade e produto;
- `node.usage` admin-only;
- owner forçado/validado em criação por revenda;
- autorização antes da idempotência;
- `principal_id` no hash idempotente;
- audit allow/deny;
- lifecycle e CI dedicados.

A limitação histórica da 0.7.2 era `cryptographic_auth=0`; isso foi encerrado na 0.7.3.

### 0.7.3 — autenticação criptográfica e enrollment ✅

Implementado:

- Ed25519 via OpenSSL, sem criptografia inventada;
- registry público root-only em `/etc/manager/automation/v2/credentials/<principal>/`;
- enrollment explícito de uma chave em principal existente;
- servidor armazena somente chave pública, `key_id`, fingerprint e estado de revogação;
- arquivo privado de credencial criado externamente em modo `0600` e não incluído no backup server-side;
- `local-root` continua autenticado por `SO_PEERCRED` e não recebe credencial externa;
- todos os demais principals exigem assinatura Ed25519 válida;
- assinatura cobre contrato, versão, `request_id`, `principal_id`, `action_id` e parâmetros;
- `managerctl --credential FILE` assina o envelope localmente;
- daemon recalcula identidade/fingerprint da chave pública antes de confiar no registro;
- rotação cria nova chave e revoga as anteriores somente depois do novo registro estar ativo;
- revogação de credencial é independente do RBAC;
- autenticação é reavaliada antes do RBAC/idempotência, portanto chave revogada não consegue replay cacheado;
- audit registra esquema, `key_id`, fingerprint e decisão, sem assinatura/chave privada;
- uninstall/reinstall preservam registry público; purge remove estado server-side;
- CI `Automation v2 Authentication` cobre assinatura, negação sem assinatura, chave errada, rotação, fencing, revogação, audit e purge;
- CI RBAC usa principals realmente assinados.

Contrato de confiança atual:

```text
rbac=1
cryptographic_auth=1
credential_algorithm=ed25519
nonlocal_signature_required=1
anti_replay=0
rate_limit=0
remote_transport=0
```

A autenticação está pronta, mas o transporte continua local. Isso evita expor rede antes de existir proteção anti-replay/rate limit específica para essa superfície.

Documentação: `docs/AUTOMATION_V2.md`.

### 0.7.4 — anti-replay, rate limiting e transporte remoto estruturado — PRÓXIMO

Planejado:

- timestamp assinado e nonce;
- janela de validade;
- cache de replay;
- limites por principal/ação;
- quotas de chamadas e proteção contra burst;
- transporte remoto autenticado e criptografado;
- Unix socket continua como fronteira privilegiada local;
- nenhum shell remoto arbitrário;
- chave revogada/principal desabilitado continua falhando fechado antes do dispatcher.

**A série 0.7 só é considerada concluída quando anti-replay, rate limiting e transporte remoto estiverem estabilizados sobre a autenticação/RBAC já concluídos.**

## 0.8.x — Modo Colmeia

Só começa depois da Automation v2 estar pronta para autenticar e autorizar integrações/nós remotamente.

### Enrollment dos nós

A Colmeia reutilizará a identidade criptográfica da Automation, integrada ao `node_id`, região e pool.

### Heartbeat e saúde

- CPU, RAM e rede;
- sessões/capacidade;
- latência;
- protocolos/serviços;
- estados `HEALTHY`, `DEGRADED`, `DRAINING`, `OFFLINE`.

### Scheduler

- weighted least-loaded;
- capacidade/peso;
- protocolo solicitado;
- região/pool/ACL;
- sticky session;
- drain e failover.

### Sessões globais

- lease global por identidade/plano;
- `max_sessions` global atômico;
- fencing distribuído;
- `session_epoch` para impedir retorno de autoridade antiga;
- troca de servidor sem sessão fantasma;
- grace controlado durante falha temporária do controlador.

O tráfego VPN real não deve passar pelo controlador da Colmeia; o controlador coordena autoridade e seleção de nó.

### Accounting global

- ingestão idempotente de deltas por nó;
- deduplicação;
- franquia global;
- telemetria local 0.6.11 continua não sendo billing autoritativo sozinha.

## 0.9.x — Telegram Bot + Mini App

Planejado depois da Automation/Colmeia:

- identidade pelo `user.id` numérico imutável do Telegram;
- admin, revendedor, subrevendedor e usuário;
- Bot + Mini App consumindo ações estruturadas;
- sessões, clientes, produtos, cotas, nós e diagnósticos;
- nenhuma execução arbitrária de shell.

## 0.9.5 — Migração e escala

- importadores assistidos do SSHPlus;
- migração multi-VPS;
- métricas e retenção;
- testes de carga;
- documentação operacional.

## 1.0.0 — Release de produção

Critérios:

- paridade útil do legado sem copiar vulnerabilidades;
- Automation v2 autenticada, autorizada, auditável e rate-limited;
- Colmeia com scheduler/leases globais estáveis;
- Telegram consumindo somente contratos estruturados;
- backup/restore/migração testados;
- CI multi-OS e processo de release verificável.
