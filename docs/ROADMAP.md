# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. O objetivo é preservar as capacidades úteis do ecossistema SSHPlus, modernizar a implementação e adicionar automação segura e operação multi-servidor sem copiar fragilidades históricas.

## Princípios

- O MANAGER novo não deve ser funcionalmente capado em relação ao SSHPlus útil.
- Compatibilidade não significa copiar práticas inseguras do legado.
- Operações privilegiadas passam por ações conhecidas e auditáveis; integrações nunca recebem shell arbitrário.
- Nenhum módulo deve limpar o firewall global, sobrescrever todo o SSH ou usar permissões `777`.
- Estado durável de identidade, fencing e autoridade é preservado em update/rollback/uninstall normal.
- Administração remota será centrada em Telegram Bot + Telegram Mini App, sem painel web administrativo convencional.
- O tráfego VPN real não deve atravessar o controlador da Colmeia.

## 0.4.x — Fundação ✅

- health check e manutenção;
- CLI não interativa;
- atualização/rollback conservadores;
- CI com Bash syntax, ShellCheck e regressões de segurança;
- política segura de fontes/downloads.

## 0.5.x — Paridade SSHPlus útil ✅

- contas SSH, contas teste, expirados e monitor de sessões;
- backup/migração segura de usuários;
- banner, speedtest e serviços;
- hosts de proxy, Squid privado, TCP, WebSocket e TLS;
- revendedores/subrevendedores, cotas e propriedade;
- criação vinculada à revenda sob lock.

## 0.6.x — Connection / Policy / Session Engine ✅

### 0.6.0 — identidade comum

- identidade MANAGER independente de `/etc/passwd`;
- SSH/WireGuard/OpenVPN por identidade;
- owner, expiração, protocolos e `max_sessions`;
- bindings para recursos técnicos.

### 0.6.1 — enforcement

- estado efetivo aplicado aos protocolos;
- SSH sem substituir todo `sshd_config`;
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
- reconciliação e adoção de sessões existentes;
- lifecycle seguro em update/rollback/uninstall.

A validação da 0.7.4 adicionou uma proteção de adoção curta para maps SSH/OpenVPN recém-admitidas, impedindo que o reconciliador libere uma lease antes que a sessão apareça na observação do protocolo.

### 0.6.4 — Identity Usage

- atividade e accounting comum por identidade;
- bytes reais de WireGuard/OpenVPN por delta;
- reset/restart de contador sem perder acumulado;
- SSH marcado como cobertura parcial de bytes;
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

## 0.7.x — Automation Engine ✅

A série 0.7 cria a superfície oficial de integração e está concluída na 0.7.4.

### 0.7.0 — Automation Legacy v1 ✅

- compatibilidade controlada com `syncpainel` e painéis antigos;
- desligado por padrão;
- listener OpenSSH dedicado;
- conta não-root `manager-legacy`;
- `ForceCommand`, sudoers exato e allowlist;
- senha de integração one-shot;
- lifecycle e CI próprios.

### 0.7.1 — Automation v2: núcleo local estruturado ✅

- `managerd` + `managerctl`;
- socket Unix `/run/manager-automation-v2/manager.sock`;
- runtime `0700`, socket `0600`, `SO_PEERCRED`;
- envelope JSON versionado;
- `request_id`, `action_id` e códigos estáveis;
- allowlist de `system.describe`, `node.usage` e lifecycle `connection.*`;
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
- audit allow/deny.

### 0.7.3 — autenticação criptográfica e enrollment ✅

- Ed25519 via OpenSSL;
- registry público root-only;
- enrollment explícito;
- chave privada fora do registry server-side;
- `local-root` continua autenticado por `SO_PEERCRED`;
- principals não-locais exigem assinatura;
- rotação e revogação;
- fingerprint/key ID derivados da chave pública;
- autenticação reavaliada antes de replay idempotente;
- CI de autenticação/RBAC dedicado.

### 0.7.4 — anti-replay, rate limiting e transporte remoto ✅

Implementado:

- `auth_scheme=ed25519-v2`;
- `issued_at` assinado;
- janela de freshness de 120 s;
- nonce assinado;
- cache anti-replay persistente por principal/chave;
- retenção de replay superior à janela de freshness;
- retry idempotente preservado com novo nonce/timestamp;
- token bucket por principal/ação;
- leitura: 120 req/min, burst 20;
- escrita: 30 req/min, burst 8;
- proteção adicional de burst por IP no gateway remoto;
- gateway dedicado `manager-automation-v2-remote.service`;
- somente TLS 1.3;
- certificado Ed25519 root-only;
- pin SHA-256 obrigatório no cliente;
- `local-root` explicitamente proibido no remoto;
- remote listener opt-in, desabilitável e com rotação de certificado;
- nenhuma regra de firewall é aberta automaticamente;
- gateway apenas encaminha ao socket Unix; autoridade permanece no `managerd`;
- audit registra transport/freshness/replay/rate-limit;
- lifecycle cobre install/update/rollback/uninstall/reinstall/purge;
- CI dedicado tenta replay, timestamp velho/futuro, burst, pin incorreto, TLS 1.2 e rotação do certificado.

Documentação: `docs/AUTOMATION_V2.md`.

## 0.8.x — Modo Colmeia — PRÓXIMO

A série 0.8 transforma a autoridade local existente em coordenação distribuída entre VPS.

### 0.8.0 — identidade e enrollment de nós

Próximo milestone recomendado:

- reutilizar `node_id` persistente;
- identidade criptográfica por nó;
- enrollment explícito no controlador;
- trust bootstrap sem segredo compartilhado permanente;
- metadados de região/pool/capacidade/peso;
- enable/disable/drain como estado de autoridade;
- rotação/revogação de credencial do nó;
- nenhuma sessão global ainda nesta primeira etapa.

### 0.8.1 — heartbeat e saúde

- CPU, RAM e rede;
- sessões/capacidade;
- latência;
- protocolos/serviços;
- estados `HEALTHY`, `DEGRADED`, `DRAINING`, `OFFLINE`;
- tolerância a heartbeat perdido;
- clock/freshness compatíveis com a Automation v2.

### 0.8.2 — scheduler

- weighted least-loaded;
- capacidade/peso;
- protocolo solicitado;
- região/pool/ACL;
- sticky session;
- drain;
- failover.

Comando desejado:

```bash
manager hive node drain BR-SP-02
```

Drain impede novas conexões, mas sessões existentes continuam até finalizar.

### 0.8.3 — autoridade de sessões globais

- lease global por identidade/plano;
- `max_sessions` global atômico;
- seleção de nó + aquisição de lease na mesma autoridade;
- fencing distribuído;
- `session_epoch` contra retorno de estado antigo;
- troca de servidor sem sessão fantasma;
- grace controlado em indisponibilidade temporária do controlador.

Exemplo obrigatório:

```text
Maria possui acesso a 10 países/nós
max_sessions global = 1
→ pode estar conectada em apenas um deles por vez
```

### 0.8.4 — accounting global

- ingestão idempotente de deltas por nó;
- deduplicação;
- franquia global;
- telemetria local 0.6.11 continua não autoritativa sozinha;
- proteção contra double counting após failover/reconnect.

### 0.8.5 — resiliência operacional

- controlador fora do caminho de dados VPN;
- sessões existentes podem sobreviver a outage do controlador sob regras de grace;
- novos grants podem falhar fechado quando autoridade global não puder ser garantida;
- recovery/fencing após retorno do controlador;
- observabilidade e auditoria distribuída.

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
- Automation v2 autenticada, autorizada, anti-replay, auditável e rate-limited;
- transporte remoto TLS 1.3 estabilizado;
- Colmeia com scheduler/leases globais estáveis;
- Telegram consumindo somente contratos estruturados;
- backup/restore/migração testados;
- CI multi-OS e processo de release verificável.
