# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. A ordem das fases é intencional: primeiro estabilizar identidade/política/sessão, depois automação, depois distribuição multi-servidor e, por fim, as interfaces de administração.

## Princípios

- o MANAGER novo não deve ser funcionalmente capado em relação ao SSHPlus útil;
- compatibilidade não significa copiar práticas inseguras do legado;
- operações privilegiadas passam por ações conhecidas, versionadas e auditáveis;
- integrações nunca recebem shell arbitrário;
- nenhum módulo deve limpar firewall global ou sobrescrever configuração SSH inteira;
- segredos gerados não são mantidos em texto claro para permitir replay posterior;
- Colmeia não deve ser antecipada antes da superfície de Automation estar estabilizada;
- administração futura continua centrada em Telegram Bot + Mini App, sem painel web administrativo obrigatório.

## 0.4.x — Fundação ✅

Concluído:

- health check e diagnóstico;
- manutenção;
- CLI não interativa;
- update/rollback conservadores;
- CI com Bash syntax, ShellCheck e regressões de segurança;
- política segura de download/instalação.

## 0.5.x — Paridade SSHPlus útil ✅

Concluído:

- usuários SSH, testes temporários e expirados;
- backup/migração segura;
- banner e monitor de sessões;
- revendedor/subrevendedor;
- proxies/túneis opcionais;
- WireGuard/OpenVPN;
- serviços, firewall, Fail2ban, TLS, DNS e diagnóstico.

O MANAGER preserva capacidades úteis, não implementações inseguras do legado.

## 0.6.x — Connection / Policy / Session Engine ✅

**Série encerrada em 0.6.11.**

### 0.6.0 — identidade comum ✅

- identidade MANAGER independente do usuário Linux;
- bindings SSH/WireGuard/OpenVPN;
- owner, validade, protocolos e `max_sessions`.

### 0.6.1 — Policy Enforcement ✅

- estado efetivo aplicado a SSH, WireGuard e OpenVPN;
- reconciliação automática;
- bloqueio reversível sem destruir credenciais persistentes.

### 0.6.2 — Session / Lease Engine ✅

- `session_id`, TTL, heartbeat e release;
- aquisição idempotente e limite atômico;
- `session_epoch`, fencing, switch e revoke.

### 0.6.3 — Protocol Lease Bridge ✅

- SSH via PAM;
- OpenVPN por fila privilegiada controlada;
- WireGuard por handshake recente + gate do peer;
- lifecycle de hooks em update/rollback/uninstall.

### 0.6.4 — Identity Usage ✅

- accounting real de WireGuard/OpenVPN por identidade;
- baseline/deltas e reset de contador;
- atividade/sessão SSH sem inventar bytes;
- persistência em `/var/lib/manager/identity-usage`.

### 0.6.5 — Produtos, ACL e franquias ✅

- catálogo de planos;
- protocolos, `max_sessions`, validade e franquia;
- ACL de região/pool/nó;
- `warn/block` e integração com Policy/Session Engine.

### 0.6.6 — Provisionamento unificado ✅

- preflight + create + bindings + policy em operação transacional;
- rollback de recursos criados na tentativa;
- senha SSH one-shot;
- revogação centralizada.

### 0.6.7 — Cotas de revenda por identidade/produto ✅

- identidade lógica como unidade de cota;
- VPN-only sem usuário Linux;
- hierarquia pai/subrevendedor;
- cotas opcionais por produto;
- deduplicação de propriedade SSH legada.

### 0.6.8 — IPv6 dual-stack ✅

- WireGuard/OpenVPN dual-stack quando o host suporta IPv6 real;
- ULA + NAT66 portátil;
- IPv6 Guard ligado ao mesmo Policy/Session Engine;
- lifecycle seguro sem flush global.

### 0.6.9 — identidade e metadados do nó ✅

- `node_id` persistente;
- país, região, pool, provedor, cidade, capacidade, peso e limite declarado;
- protocolos/IPv6 detectados localmente;
- estado dentro do Connection Engine.

### 0.6.10 — ACL automática pelo nó ✅

- Product Policy resolve `region`, `pool` e `node_id` automaticamente;
- fail-closed quando metadado obrigatório falta;
- Session Engine recusa lease em nó fora da ACL.

### 0.6.11 — fechamento do Connection Engine ✅

- `manager-connection-actions-v1`: `preflight/create/status/revoke/describe` allowlisted;
- `manager-node-usage-v1`: telemetria local por nó;
- sem shell/comando/caminho arbitrário;
- telemetria local marcada como não autoritativa para billing global.

## 0.7.x — Automation Engine

A série 0.7 cria a superfície oficial de integração. Ela deve estar estabilizada **antes** da Colmeia.

### 0.7.0 — Automation Legacy v1 ✅

Compatibilidade controlada com `syncpainel` e painéis antigos:

- desligado por padrão;
- `manager automation legacy status|enable|disable|restart|rotate-password`;
- listener OpenSSH dedicado;
- conta não-root `manager-legacy`;
- `ForceCommand`, sudoers exato e allowlist;
- comandos históricos suportados sem `eval`;
- senha de integração one-shot, sem armazenamento em texto claro;
- lifecycle completo e CI próprio.

Documentação: `docs/AUTOMATION_LEGACY.md`.

### 0.7.1 — Automation v2: núcleo local estruturado ✅

Implementado:

- `managerd` + `managerctl`;
- socket Unix `/run/manager-automation-v2/manager.sock`;
- runtime `0700`, socket `0600` e validação do peer com `SO_PEERCRED`;
- contrato `manager-automation-v2-local-v1`;
- envelope JSON versionado;
- `request_id`, `action_id` e códigos estáveis;
- allowlist inicial `system.describe`, `node.usage` e lifecycle `connection.*`;
- nenhuma ação de shell/comando/caminho arbitrário;
- idempotência persistente com conflito para reutilização de `request_id` com payload diferente;
- respostas persistidas são sanitizadas: segredos são one-shot e não podem ser recuperados por replay;
- audit JSONL sem stdout/senha/chaves privadas;
- install espera o socket realmente ficar pronto antes de retornar sucesso;
- rollback/uninstall conhecem daemon, socket, aliases e estado persistente;
- CI cobre allowlist, create/replay/conflito/revoke, segredo fora do cache/audit e reinstall.

Documentação: `docs/AUTOMATION_V2.md`.

### 0.7.2 — Principals e RBAC — próximo

Objetivo: deixar de ter apenas `UID 0` como único principal local e introduzir uma identidade explícita de automação.

Planejado:

- principals internos estáveis;
- papéis `admin`, `revendedor`, `subrevendedor` e `user`;
- escopo por owner/identidade/produto;
- matriz `action_id -> papel/escopo`;
- autorização antes do dispatcher privilegiado;
- auditoria com principal efetivo e decisão RBAC;
- sem ampliar a allowlist de forma implícita.

### 0.7.3 — autenticação criptográfica e enrollment

Planejado:

- identidade criptográfica das integrações;
- enrollment/revogação;
- rotação de chaves;
- fingerprints e armazenamento root-only;
- nenhuma senha compartilhada em texto claro.

### 0.7.4 — anti-replay, rate limiting e transporte remoto estruturado

Planejado:

- timestamp/nonce;
- janela de validade;
- cache de replay;
- limites por principal/ação;
- transporte remoto autenticado e criptografado;
- o Unix socket continua sendo a fronteira privilegiada local;
- sem shell remoto arbitrário.

**A série 0.7 só é considerada concluída quando RBAC, autenticação, anti-replay e rate limiting estiverem estabilizados.**

## 0.8.x — Modo Colmeia

Só começa depois da Automation v2 estar pronta para autenticar e autorizar integrações/nós.

Planejado:

### Enrollment e confiança dos nós

- identidade criptográfica por servidor;
- troca/rotação de chaves;
- comunicação autenticada e criptografada;
- integração com `node_id`, região e pool existentes.

### Heartbeat e saúde

- CPU, RAM e rede;
- sessões/capacidade;
- latência;
- protocolos/serviços;
- `HEALTHY`, `DEGRADED`, `DRAINING`, `OFFLINE`.

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
- troca de servidor sem sessão fantasma;
- grace controlado durante falha temporária do Hub.

### Accounting global

- ingestão idempotente de deltas por nó;
- deduplicação;
- franquia global;
- telemetria local 0.6.11 continua não sendo billing autoritativo sozinha.

## 0.9.x — Telegram Bot + Mini App

Planejado depois da Automation/Colmeia:

- identidade pelo `user.id` numérico do Telegram;
- admin, revendedor, subrevendedor e usuário;
- Mini App consumindo operações estruturadas;
- sessões, usuários, produtos, cotas, nós e diagnósticos;
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
