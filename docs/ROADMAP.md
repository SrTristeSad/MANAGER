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

`managerd`/`managerctl`, socket Unix `0600`, envelope versionado, `request_id`, allowlist, idempotência e audit sem segredos.

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

## 0.8.x — Modo Colmeia 🚧

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

Limites atuais após 0.8.2:

```text
private_hive_network=1
wireguard_mesh=1
heartbeat=1
node_health=1
signed_heartbeat=1
freshness=1
anti_replay=1
tls_transport=TLS1.3
tls_server_pinning=sha256
controller_in_user_vpn_path=0
scheduler=0
drain_runtime=0
failover=0
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

Documentação: `docs/HIVE.md`.

### 0.8.3 — scheduler, drain e seleção de nó — PRÓXIMO

Planejado:

- weighted least-loaded;
- capacidade/peso;
- somente nós `HEALTHY`/elegíveis para novas alocações;
- protocolo solicitado;
- região/pool/ACL;
- latência/health;
- sticky session;
- drain real;
- seleção determinística e auditável;
- failover de seleção quando um nó deixa de ser elegível, sem transformar o controlador em relay de tráfego.

Comando desejado:

```bash
manager hive node drain BR-SP-02
```

Drain deverá impedir novas conexões naquele nó, mas sessões existentes continuam até finalizar.

### 0.8.4 — autoridade de sessões globais

- lease global por identidade/plano;
- `max_sessions` global atômico;
- seleção de nó + aquisição de lease na mesma autoridade;
- fencing distribuído;
- `session_epoch` contra retorno de autoridade antiga;
- troca de servidor sem sessão fantasma;
- grace controlado em indisponibilidade temporária do controlador.

Exemplo obrigatório:

```text
Maria possui acesso a 10 países/nós
max_sessions global = 1
→ pode estar conectada em apenas um deles por vez
```

### 0.8.5 — VPN allocation / login global

- login/provisionamento capaz de escolher um nó elegível;
- vínculo entre produto, região/pool, protocolo e lease global;
- sessão criada somente no nó autorizado pelo grant atual;
- `session_epoch`/fencing impedindo nó stale de aceitar retorno antigo;
- suporte a SSH, WireGuard e OpenVPN conforme capacidades do nó.

### 0.8.6 — quotas e accounting globais

- ingestão idempotente de deltas por nó;
- deduplicação;
- franquia global;
- telemetria local 0.6.11 continua não autoritativa sozinha;
- proteção contra double counting após failover/reconnect;
- quota e `max_sessions` permanecem autoridades distintas.

### 0.8.7 — failover e resiliência operacional

- controlador fora do caminho de dados VPN;
- sessões existentes sobrevivem a outage sob regras de grace;
- novos grants podem falhar fechado quando autoridade global não puder ser garantida;
- recovery/fencing após retorno do controlador;
- drain/failover sem expulsar sessão saudável desnecessariamente;
- sticky session preservada quando possível.

### 0.8.8 — comandos remotos controlados

- operações remotas tipadas sobre contratos existentes;
- nenhuma execução arbitrária de shell;
- escopo/RBAC por nó, pool e ação;
- audit e idempotência;
- integração futura com Telegram sem criar uma segunda autoridade paralela.

### 0.8.9 — rotação de chaves e anti-replay distribuído

- rotação de identidade do nó/controlador com transição explícita;
- rotação de material da malha WireGuard;
- nonce/timestamp/freshness para mensagens distribuídas;
- revogação e fencing durante rotação;
- nenhuma criptografia própria.

### 0.8.10 — observabilidade distribuída

- visão histórica de saúde/capacidade por nó;
- histórico de decisões do scheduler;
- leases/grants globais auditáveis;
- métricas de failover, drain e latência;
- retenção operacional sem persistir segredos.

## 0.9.x — Telegram Bot + Mini App

- identidade pelo `user.id` numérico imutável do Telegram;
- admin, revendedor, subrevendedor e usuário;
- Bot + Mini App consumindo ações estruturadas;
- sessões, clientes, produtos, cotas, nós e diagnósticos;
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
