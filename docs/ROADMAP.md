# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. O objetivo é preservar capacidades úteis do ecossistema SSHPlus, modernizar a implementação e adicionar automação segura e operação multi-servidor sem copiar fragilidades históricas.

## Princípios

- O MANAGER novo não deve ser funcionalmente capado em relação ao SSHPlus útil.
- Compatibilidade não significa copiar práticas inseguras do legado.
- Operações privilegiadas passam por ações conhecidas e auditáveis; integrações nunca recebem shell arbitrário.
- Nenhum módulo deve limpar o firewall global, sobrescrever todo o SSH ou usar permissões `777`.
- Estado durável de identidade, fencing e autoridade é preservado em update/rollback/uninstall normal.
- Administração remota será centrada em Telegram Bot + Telegram Mini App, sem painel web administrativo convencional.
- O tráfego VPN real não deve atravessar o controlador da Colmeia.

## 0.4.x — Fundação ✅

Health check, manutenção, CLI, update/rollback conservadores, CI Bash/ShellCheck e política segura de fontes/downloads.

## 0.5.x — Paridade SSHPlus útil ✅

Contas SSH/teste, expirados, sessões, backup/migração, banner, speedtest, serviços, revenda/subrevenda, cotas, hosts/proxies, Squid privado e túneis modernos.

## 0.6.x — Connection / Policy / Session Engine ✅

### 0.6.0 a 0.6.11

- identidade MANAGER independente do usuário Linux;
- SSH/WireGuard/OpenVPN por identidade;
- Policy Engine e enforcement;
- Session/Lease Engine com TTL, heartbeat, `session_epoch` e fencing;
- Protocol Lease Bridge real para SSH/OpenVPN/WireGuard;
- accounting local por identidade;
- produtos, ACL, franquias e cotas;
- provisionamento transacional;
- cotas de revenda por identidade/produto;
- IPv6 dual-stack e IPv6 Guard;
- `node_id` + metadata de região/pool/capacidade/peso;
- ACL automática pelo contexto local do nó;
- contratos estruturados `manager-connection-actions-v1` e `manager-node-usage-v1`.

## 0.7.x — Automation Engine ✅

### 0.7.0 — Legacy v1 ✅

Compatibilidade controlada com `syncpainel`, listener OpenSSH dedicado, conta não-root, `ForceCommand`, sudoers exato, allowlist e lifecycle próprio.

### 0.7.1 — Automation v2 local core ✅

`managerd`/`managerctl`, socket Unix `0600`, envelope versionado, `request_id`, allowlist, idempotência e auditoria sem segredos.

### 0.7.2 — Principals + RBAC ✅

Roles `admin`, `reseller`, `subreseller`, `user`; escopo por owner/identidade/produto; autorização antes da idempotência.

### 0.7.3 — Ed25519 + enrollment ✅

Credenciais por principal, enrollment, fingerprint, rotação, revogação e autenticação criptográfica antes do RBAC/replay.

### 0.7.4 — anti-replay + rate limit + transporte remoto ✅

- assinatura `ed25519-v2` com `issued_at` e nonce;
- janela de freshness de 120 s;
- cache anti-replay;
- rate limit por principal/ação;
- gateway remoto TLS 1.3;
- pin SHA-256 obrigatório;
- `local-root` proibido no remoto;
- gateway fora da autoridade lógica: decisões permanecem no `managerd` local.

Documentação: `docs/AUTOMATION_V2.md`.

## 0.8.x — Modo Colmeia ✅

A série 0.8 transforma a autoridade local existente em coordenação distribuída entre VPS, mantendo o controlador fora do caminho de dados VPN.

### 0.8.0 — identidade e enrollment de nós ✅

Implementado:

- reutilização do `node_id` persistente;
- identidade Ed25519 por nó;
- identidade Ed25519 de controlador;
- contracts de enrollment request/bundle assinados;
- request com metadados, `issued_at`, nonce, chave pública, key ID e fingerprint;
- verificação de assinatura/identidade antes do registro;
- pin SHA-256 do controlador no primeiro aceite;
- `node_epoch` monotônico;
- revogação + re-enrollment explícito;
- fencing de bundle antigo;
- estado durável em `/etc/manager/hive`;
- backup/uninstall/reinstall/purge testados;
- CI `Hive Node Enrollment`.

### 0.8.1 — rede privada WireGuard da Colmeia ✅

Implementado:

- interface dedicada `mgh0`, separada do `wg0` dos clientes;
- mesh direto VPS↔VPS;
- chave WireGuard privada exclusiva de cada nó;
- network request assinado;
- IPv4/IPv6 privado único por nó;
- bundles de topologia assinados;
- `config_epoch` e fencing;
- nenhuma rota default;
- nenhuma abertura automática de firewall;
- ownership seguro de `mgh0.conf`;
- validação antes de aplicar;
- restart real quando topologia muda;
- rollback de runtime;
- lifecycle de uninstall/rollback preservando estado durável;
- CI `Hive Private Network` + `Hive Network Lifecycle`.

### 0.8.2 — heartbeat e saúde ✅

Implementado:

- heartbeat assinado pela identidade Ed25519 enrolled do nó;
- `controller_id`, `node_id`, `node_epoch`, timestamp, nonce e métricas cobertos pela assinatura;
- freshness de 120 segundos;
- anti-replay com nonce single-use e criação exclusiva;
- `node_epoch` exato como fencing de heartbeat stale;
- ACK do controlador assinado por Ed25519;
- transporte TLS 1.3 somente;
- pin SHA-256 obrigatório do certificado TLS do controlador;
- listener opt-in, sem abrir firewall automaticamente;
- rate limit por origem;
- CPU, RAM, load, rede, sessões, capacidade, peso, protocolos e serviços;
- estado da malha `mgh0` e RTT;
- estados `HEALTHY`, `DEGRADED`, `DRAINING`, `OFFLINE`;
- thresholds de heartbeat atrasado/offline configuráveis;
- audit de aceite/recusa sem segredos;
- lifecycle destaca timer/listener antes da malha no uninstall/rollback;
- CI `Hive Heartbeat and Health` cobrindo TLS pinning, tamper, replay, timeout, draining e epoch fencing.

### 0.8.3 — scheduler, drain e seleção de nó ✅

Implementado:

- scheduler `weighted-least-loaded` usando sessões, capacidade, peso e RTT como componente secundário;
- somente nós enrolled, habilitados, `HEALTHY`, não drenados e com capacidade são elegíveis para novas alocações;
- filtros por protocolo, região, pool e escopo explícito de `node_id`;
- placement controller-authoritative com nome amigável por nó;
- sticky affinity persistente enquanto o nó continua elegível;
- failover automático de seleção quando o sticky deixa de ser elegível;
- drain impede novas alocações sem encerrar sessões já existentes;
- seleção determinística em empates;
- audit JSONL de placement, seleção, drain/undrain e recusas;
- CLI pública `manager hive node ...`;
- estado de placement/sticky preservado em uninstall normal e removido com `--purge`;
- controlador continua fora do caminho de dados VPN;
- autoridade global de leases continua explicitamente fora desta etapa;
- CI dedicado `Hive Scheduler and Drain`.

Comandos:

```bash
manager hive node status
manager hive node list
manager hive node show BR-SP-02
manager hive node placement NODE_ID BR-SP-02 BR BR-SP PREMIUM
manager hive node drain BR-SP-02 maintenance
manager hive node undrain BR-SP-02
manager hive node select wireguard BR-SP PREMIUM maria '*'
```

### 0.8.4 — autoridade de sessões globais ✅

- lease global por identidade com `max_sessions_global` atômico;
- acquire/heartbeat/release autenticados por Ed25519 + TLS 1.3 pinado;
- reservas globais, fencing, revogação e grace limitado;
- bridge real SSH/WireGuard/OpenVPN;
- novas admissões fail-closed sem autoridade;
- controlador fora do caminho de dados VPN.

### 0.8.5 — VPN allocation / login global ✅

- ticket de allocation assinado vinculado a produto/protocolo/nó/epochs;
- distribuição durável por pull, ACK idempotente e provisionamento remoto tipado;
- resultado público sanitizado; SSH só retorna credencial recém-emitida;
- perfis WireGuard/OpenVPN exportáveis de forma controlada.

### 0.8.6 — quotas e accounting globais ✅

- snapshots cumulativos por nó e deltas idempotentes por geração;
- agregação multi-nó, quotas monthly/lifetime, warn/block;
- cobertura parcial de SSH não gera bloqueio falso por bytes.

### 0.8.7 — failover e resiliência operacional ✅

- estados healthy/outage/fenced, recovery e fencing persistentes;
- novas admissões fail-closed durante autoridade não confiável;
- sessões existentes respeitam grace limitado.

### 0.8.8 — comandos remotos controlados ✅

- somente ações tipadas Automation v2; nenhuma shell remota arbitrária;
- scopes por nó/pool/ação;
- routing por pool, sticky/failover e E2E com dois gateways TLS.

### 0.8.9 — rotação de chaves e anti-replay distribuído ✅

- rotação Ed25519 de nó/controlador;
- rotação staged WireGuard `mgh0`;
- epochs, nonce, freshness, replay cache e fencing consolidados.

### 0.8.10 — observabilidade distribuída ✅

- histórico sanitizado de health/capacidade, scheduler e leases;
- rotação/retenção segura dos audits, com rotação coordenada dos audits por rename atômico;
- export estruturado, incluindo export JSON versionado para integrações externas;
- métricas e séries temporais;
- gate final multi-nó com TLS 1.3, Ed25519 e fencing;
- gate final multi-nó permanente preserva o fechamento end-to-end da release;
- regressão completa do repositório permanece requisito para merge da release.

## 0.9.x — Telegram Bot + Mini App 🚧

### 0.9.0 — identidade Telegram + ponte RBAC 🚧

Fundação implementada:

- `user.id` numérico do Telegram é a identidade externa estável; username/nome/chat não concedem autoridade;
- binding root-only `telegram_user_id -> principal_id` sem duplicar roles ou ACL;
- role, subject, products, node/pool/action scopes continuam vindo exclusivamente da Automation v2;
- binding ou principal desabilitado falham fechado;
- validação HMAC-SHA-256 do `Telegram.WebApp.initData` com freshness;
- bot token instalado por arquivo root-only e nunca aceito em argv;
- contratos `manager-telegram-initdata-v1` e `manager-telegram-authenticated-principal-v1`;

Gateway Mini App implementado nesta fatia:

- gateway `manager-telegram-gateway-request-v1` aceita somente ações tipadas/allowlisted;
- gateway delega à Automation v2 usando credencial Ed25519 do principal, preservando RBAC, rate limit e idempotência;
- `managerd` continua sendo a autoridade de role/subject/node/pool/action scope e revalida RBAC antes da idempotência;
- `initData`, bot token e credencial privada não entram em argv, audit ou contrato público do gateway.

Ingresso Telegram Bot implementado nesta fatia:

- contrato de ingresso `manager-telegram-bot-ingress-v1`;
- ingresso autenticado do Telegram Bot por long polling HTTPS, reutilizando o gateway tipado;
- long polling HTTPS com a Telegram Bot API sem listener público adicional;
- somente chat privado com `from.id == chat.id` entra no parser;
- `from.id` numérico é resolvido no binding existente e nunca substituído por username/chat/nome;
- comandos Bot de leitura `/describe`, `/node` e `/status ID` usam `manager-telegram-gateway-request-v1`;
- texto desconhecido não vira action_id, shell ou comando arbitrário;
- respostas são enviadas com `sendMessage` e sanitizadas antes da entrega;
- offset root-only só avança após entrega aceita pela Bot API;
- falha de entrega reutiliza o mesmo `request_id` derivado do `update_id`, recebendo replay idempotente da Automation v2 em vez de executar a ação novamente;
- Automation v2 continua autoridade única para RBAC, scopes, rate limit, idempotência e dispatcher;
- bot token permanece fora de argv/audits/respostas;
- lifecycle de reinstall/uninstall/rollback preserva estado e não deixa unit apontando para código ausente.

Próximas fatias da série 0.9:

- comandos Bot read-only de clientes, produtos, sessões, nós e diagnósticos usando o gateway operacional existente (admin-only, sem shell) ✅;
- paginação e filtragem de owner/produto/escopo para consultas de revendedores, subrevendedores e usuários pela ação `ops.read` ✅;
- Mini App visual responsivo de clientes, sessões, produtos e cotas: HTTP local opt-in, HTTPS externo, initData HMAC, gateway e paginação por role ✅;
- telas administrativas de nós e diagnósticos com leitura somente administrativa e capability `node.usage` ✅;
- operações de escrita no Bot somente com confirmação explícita de UX;
- webhook autenticado opcional como transporte alternativo ao long polling;
- nenhuma execução arbitrária de shell.

## 0.9.5 — Migração e escala

Importadores assistidos, migração multi-VPS, métricas/retenção, testes de carga e documentação operacional.

## 1.0.0 — Release de produção

Critérios:

- paridade útil do legado sem copiar vulnerabilidades;
- Automation v2 autenticada, autorizada, anti-replay, auditável e rate-limited;
- transporte remoto TLS 1.3 estabilizado;
- Colmeia com scheduler/leases globais estáveis;
- Telegram consumindo somente contratos estruturados;
- backup/restore/migração testados;
- CI multi-OS e processo de release verificável.
