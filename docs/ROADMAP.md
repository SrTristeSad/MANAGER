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

Compatibilidade controlada com `syncpainel` e painéis antigos:

- desligado por padrão;
- listener OpenSSH dedicado;
- conta não-root `manager-legacy`;
- `ForceCommand`, sudoers exato e allowlist;
- comandos históricos suportados sem `eval`;
- senha de integração one-shot;
- lifecycle e CI próprios.

Documentação: `docs/AUTOMATION_LEGACY.md`.

### 0.7.1 — Automation v2: núcleo local estruturado ✅

Implementado:

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

Implementado:

- registry root-only em `/etc/manager/automation/v2/principals`;
- principal reservado `local-root` para compatibilidade local;
- roles `admin`, `reseller`, `subreseller` e `user`;
- principals de revenda reutilizam `/etc/manager/access/resellers`, sem duplicar a hierarquia;
- principal `user` é ligado a uma identidade real do Connection Engine;
- escopo por owner, identidade e produto;
- `node.usage` admin-only;
- reseller acessa sua árvore e subrevendedores filhos diretos;
- subreseller fica limitado ao próprio owner;
- user consulta somente sua identidade e não revoga;
- `owner` omitido em create/preflight de revenda é forçado pelo daemon;
- tentativa de cruzar para outra revenda é recusada;
- autorização ocorre antes do cache idempotente;
- `principal_id` entra no hash de idempotência;
- desabilitar principal corta retries já cacheados;
- audit registra principal, papel, decisão `allow/deny` e razão;
- arquivos de principal precisam ser root-owned e sem permissões de grupo/mundo;
- principals são preservados por uninstall/reinstall normal;
- CI dedicado cobre isolamento, produto, owner forçado, replay, audit e lifecycle.

Limite de confiança desta etapa:

```text
rbac=1
principal_assertion=root-local
cryptographic_auth=0
anti_replay=0
rate_limit=0
remote_transport=0
```

Ou seja: `managerctl --principal X` ainda é uma asserção de um chamador que já é root local no socket `0600`; não é autenticação de uma integração remota.

Documentação: `docs/AUTOMATION_V2.md`.

### 0.7.3 — autenticação criptográfica e enrollment — PRÓXIMO

Objetivo: transformar o principal lógico já autorizado em uma identidade comprovável criptograficamente.

Planejado:

- par de chaves/identidade por integração;
- enrollment explícito de uma chave em um `principal_id` existente;
- fingerprint estável;
- armazenamento root-only;
- rotação de chave sem recriar o principal;
- revogação de credencial independente da política RBAC;
- associação inequívoca `chave autenticada -> principal_id`;
- nenhuma senha compartilhada em texto claro;
- formato versionado para futura autenticação de Telegram gateway, Colmeia e outras integrações.

Nesta etapa ainda não é necessário expor TCP público: a autenticação pode ser construída/testada sobre a fronteira local antes do transporte remoto.

### 0.7.4 — anti-replay, rate limiting e transporte remoto estruturado

Planejado:

- timestamp e nonce;
- janela de validade;
- cache de replay;
- limites por principal/ação;
- quotas de chamadas e proteção contra burst;
- transporte remoto autenticado e criptografado;
- Unix socket continua como fronteira privilegiada local;
- nenhum shell remoto arbitrário.

**A série 0.7 só é considerada concluída quando RBAC, autenticação, anti-replay e rate limiting estiverem estabilizados.**

## 0.8.x — Modo Colmeia

Só começa depois da Automation v2 estar pronta para autenticar e autorizar integrações/nós.

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
