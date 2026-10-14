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

Estado após 0.8.3:

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
scheduler=weighted-least-loaded
sticky_session=1
drain_runtime=1
selection_failover=1
global_lease_authority=0
global_max_sessions=0
global_accounting=0
```

Documentação: `docs/HIVE.md`.

### 0.8.4 — autoridade de sessões globais ✅

Implementado:

- lease global por identidade com política vinculável a produto/plano;
- `max_sessions_global` atômico sob lock único da autoridade;
- acquire/heartbeat/release autenticados pela identidade Ed25519 enrolled do nó;
- transporte TLS 1.3 com pin SHA-256 e listener opt-in;
- timestamp, nonce single-use e `node_epoch` no envelope assinado;
- scheduler + reserva global no comando de grant;
- reserva já conta para o limite e só pode ser reclamada pelo nó/protocolo/device selecionados;
- `authority_epoch` persistido no nó impede retorno de controlador antigo;
- revogação por identidade remove leases e incrementa `global_epoch`;
- Protocol Lease Bridge aplica a autoridade global a SSH, WireGuard e OpenVPN;
- novas admissões falham fechado sem autoridade;
- sessões existentes têm grace limitado somente em outage de transporte; deny/revoke/fencing continuam imediatos;
- controlador permanece fora do caminho de dados VPN;
- uninstall/reinstall preservam política/epochs/estado; purge remove; rollback destaca unit sem apagar estado durável;
- CI `Hive Global Lease Authority` cobre dois nós, limite global, grant/claim, fencing, revoke, bridge real, grace e lifecycle.

Exemplo validado em CI:

```text
Maria possui acesso a múltiplos nós
max_sessions_global = 1
→ uma sessão ocupa o slot global
→ tentativa simultânea em outro nó é recusada
```

`global_accounting=0` permanece intencional; billing global não faz parte desta etapa.

### 0.8.5 — VPN allocation / login global ✅

Implementado nesta fase:

- ticket de allocation Ed25519 vinculado a produto, região/pool, protocolo, nó/`node_epoch`, lease global e `session_epoch`;
- exact-grant: sessão só pode reclamar o `global_lease_id` autorizado pelo ticket atual;
- suporte do contrato a SSH, WireGuard e OpenVPN;
- outbox durável no controlador e distribuição automática por pull no mesmo TLS 1.3 pinado da autoridade de leases;
- pull autenticado pela identidade Ed25519 enrolled do nó, com freshness, nonce e fencing de `node_epoch`;
- ACK somente depois do aceite local durável; redelivery é idempotente e não exige nova porta/listener no nó;
- timer de sync no nó e comando manual `manager hive allocation sync` para diagnóstico/recuperação;
- revogação remove bundles ainda não entregues e mantém o controlador fora do caminho de dados VPN;
- nó selecionado executa provisionamento remoto idempotente antes do ACK da allocation;
- SSH, WireGuard e OpenVPN reutilizam o provisionamento transacional local, sem shell remoto arbitrário;
- redelivery após perda de ACK reutiliza o recurso já criado e um receipt root-only vinculado à allocation;
- falha de produto/protocolo/preflight no nó impede ACK e mantém o fluxo fail-closed.

Adicionado no fechamento da fase:

- ACK autenticado do nó carrega um `manager-hive-vpn-login-result-v1` sanitizado, sem segredo em argv, log ou audit;
- controlador persiste resultados sensíveis em `0600` e a CLI pública exporta para arquivo novo `0600`, nunca para stdout;
- `manager hive login create ...` inicia a allocation e `manager hive login result ALLOCATION_ID OUT` consulta/exporta o resultado;
- SSH distingue credencial recém-emitida de credencial já existente, sem tornar senhas antigas recuperáveis;
- WireGuard/OpenVPN devolvem o perfil gerenciado em base64 dentro do contrato;
- release 0.8.5 fechada após o gate público de login/provisionamento e a regressão completa concluírem com sucesso.

### 0.8.6 — quotas e accounting globais ✅

Implementado:

- cada nó envia snapshot cumulativo de uso por identidade pelo mesmo canal Ed25519 + TLS 1.3 pinado da autoridade de leases;
- o controlador deriva deltas por `(node_id, identity_id, source_epoch)`, tornando redelivery/reconnect idempotente;
- contador menor na mesma geração é recusado em vez de ser reinterpretado e contado novamente;
- mudança explícita de geração cria novo baseline sem somar o snapshot inicial, protegendo contra double counting após reset;
- uso de múltiplos nós é agregado em estado global root-only por identidade;
- franquia global possui política própria por identidade/produto, com `monthly`/`lifetime` e ação `warn`/`block`;
- grant/acquire global recusam novas sessões quando a franquia global `block` está excedida e a cobertura de bytes é completa;
- identidade com SSH continua marcada como cobertura parcial (`ssh_bytes_supported=0`), portanto não recebe bloqueio incorreto por bytes não medidos;
- telemetria local 0.6.11 continua não autoritativa sozinha: somente o estado agregado aceito pelo controlador é global;
- quota global e `max_sessions_global` permanecem autoridades e estados distintos.

### 0.8.7 — failover e resiliência operacional ✅

Implementado:

- estado operacional persistente da autoridade no nó (`healthy`, `outage`, `fenced`) sem transformar o controlador em caminho de dados;
- `last_success_epoch`, início da outage, última falha de transporte e contadores de recovery preservados em estado root-only;
- `manager hive lease node probe` reutiliza o mesmo envelope Ed25519 + TLS 1.3 pinado para testar autoridade e fechar recovery;
- falha de transporte marca outage e mantém novos grants fail-closed; resposta autoritativa válida fecha a outage e registra recovery;
- retorno de `authority_epoch` menor que o maior já observado marca o nó como `fenced` e continua fail-closed;
- estado de recovery é diagnóstico/controle e não carrega tráfego VPN de usuário.

Critérios da fase:

- controlador fora do caminho de dados VPN;
- sessões existentes sobrevivem a outage sob regras de grace;
- novos grants podem falhar fechado quando autoridade global não puder ser garantida;
- recovery/fencing após retorno do controlador;
- drain/failover sem expulsar sessão saudável desnecessariamente;
- sticky session preservada quando possível.

### 0.8.8 — comandos remotos controlados ✅

Implementado:

- operações remotas continuam usando exclusivamente os contratos tipados já allowlisted da Automation v2; não existe shell/comando/caminho arbitrário;
- principals não-locais passam a ter escopos persistentes `node_scope`, `pool_scope` e `action_scope`, com `*` como compatibilidade para registros antigos;
- o `managerd` valida ação, `node_id` local e pool local antes da idempotência e antes do dispatcher;
- alteração de escopo invalida efetivamente retries que antes seriam servidos do cache, pois RBAC é reavaliado primeiro;
- audit registra os escopos do principal e o contexto local usados na decisão;
- `local-root` permanece apenas local/Unix e não pode ser convertido em autoridade remota.

Nova fundação de roteamento explícito por nó:

- nó enrolled publica anúncio assinado contendo endpoint IP literal, fingerprint TLS, `action_scope`, `node_epoch` e `route_epoch`;
- controlador aceita rota somente para node_id registrado/ativo e cerca replay/rollback pelo `route_epoch`;
- `manager hive remote controller call NODE_ID ACTION ...` resolve endpoint/fingerprint apenas pelo registro assinado, nunca pela linha de comando;
- requisição remota reutiliza a chave Ed25519 do próprio controlador da Colmeia como principal reservado `hive-controller`; a chave privada não é distribuída;
- nó revalida controller_id, node_epoch e action_scope antes da idempotência/dispatcher da Automation v2.

Roteamento por pool implementado:

- o controlador filtra rotas assinadas por `action_scope` e passa apenas esses node_ids como `node_scope` ao scheduler 0.8.3;
- seleção por pool exige nó enrolled, `HEALTHY`, fora de drain, com protocolo/serviço ativo e capacidade disponível;
- weighted least-loaded, RTT secundário e sticky/failover continuam sendo calculados por uma única autoridade de scheduler;
- `manager hive remote controller select POOL PROTOCOL ACTION [STICKY]` expõe a decisão sem executar ação;
- `manager hive remote controller call-pool POOL PROTOCOL ACTION ...` seleciona e executa a mesma operação tipada, revalidando rota/node_epoch após a seleção;
- nós sem rota ou sem permissão para a ação nunca entram no conjunto de candidatos.

Fechamento da fase:

- gate end-to-end com dois gateways TLS distintos, múltiplos nós e pool validado;
- regressão completa de 33 workflows concluída antes do bump formal;
- integração com Telegram permanece futura e consumirá estes contratos sem criar uma segunda autoridade paralela.

### 0.8.9 — rotação de chaves e anti-replay distribuído ✅

- rotação Ed25519 explícita da identidade do nó com prova da chave antiga/nova e fencing por `node_epoch`;
- rotação Ed25519 do controlador com transição dual-signed e `controller_epoch` monotônico;
- rotação staged da chave WireGuard da malha `mgh0`, ativação por nova geração de topologia e commit local transacional;
- nonce, timestamp, freshness, replay cache persistente e retries idempotentes nos contratos de rotação;
- fencing consolidado por geração entre identidade, topologia e control plane;
- histórico conserva somente material público/documentos assinados; chaves privadas antigas não são arquivadas;
- nenhuma criptografia própria;
- gate final integrado e regressão funcional completa: **34/34 workflows** verdes antes do bump formal.

### 0.8.10 — observabilidade distribuída ✅

Fundação implementada nesta primeira fatia:

- histórico sanitizado de saúde/capacidade por nó a partir de heartbeat aceito;
- consulta ao histórico de decisões já auditadas pelo scheduler, sem duplicar autoridade;
- consulta sanitizada a grants/leases e eventos de recovery/fencing já auditados;
- summary por janela com failover sticky, drain/undrain, RTT médio/p95, grants/denies/releases e estado de autoridade;
- retenção temporal do histórico de health, root-only, sem chaves/credenciais/assinaturas/nonces;
- observabilidade failure-isolated: erro no histórico não invalida heartbeat aceito;
- rotação coordenada dos audits de scheduler/leases por rename atômico, sem truncar em lugar;
- consultas sanitizadas continuam atravessando segmentos arquivados + arquivo ativo;
- retenção temporal remove somente segmentos antigos, com armazenamento root-only e sem compressão concorrente;
- export JSON versionado, sanitizado e limitado para integração externa, sem listener adicional;
- séries temporais por buckets com CPU/RAM/RTT/load/sessões/utilização e deltas observados de rede;
- métricas operacionais por janela com p95/pico, taxa de failover/deny, estado dos nós e eventos de autoridade;
- contadores de rede tratam reboot/reset e mudança de `node_epoch` como nova baseline, sem delta negativo;
- retenção operacional preserva apenas campos allowlisted, sem interface/endereço/segredo;
- controlador continua fora do caminho de dados VPN.

Fechamento da fase:

- gate final multi-nó permanente com duas identidades enrolled, heartbeats Ed25519 reais, TLS 1.3 pinado e histórico automático de observabilidade;
- fencing comprova que heartbeat de nó revogado não entra no histórico após a revogação;
- summary, metrics, series e export são validados em conjunto sobre dados de múltiplos nós e eventos do control plane;
- regressão completa do repositório permanece requisito para merge da release;
- nenhum listener adicional foi criado pela observabilidade e o controlador continua fora do caminho de dados VPN.

## 0.9.x — Telegram Bot + Mini App 🚧

### 0.9.0 — identidade Telegram + ponte RBAC 🚧

Fundação implementada:

- `user.id` numérico do Telegram é a identidade externa estável; username/nome/chat não concedem autoridade;
- binding root-only `telegram_user_id -> principal_id` sem duplicar roles ou ACL;
- role, subject, products, node/pool/action scopes continuam vindo exclusivamente da Automation v2;
- um principal e um `user.id` formam vínculo 1:1 nesta fundação;
- binding ou principal desabilitado falham fechado;
- resolve estruturado `manager-telegram-identity-v1` sem segredo e sem shell arbitrário;
- validação HMAC-SHA-256 do `Telegram.WebApp.initData` usando chave derivada do bot token;
- `auth_date` obrigatório com freshness configurável e fail-closed para payload vencido/futuro;
- bot token instalado por arquivo, persistido root-only e nunca aceito em argv;
- `user.id` só entra no resolve RBAC depois de HMAC + freshness válidos;
- contratos `manager-telegram-initdata-v1` e `manager-telegram-authenticated-principal-v1`;
- audits de identidade/autenticação não retêm token, initData, hash, signature, query_id, nomes ou username;
- CLI `manager telegram identity ...` e `manager telegram auth ...`, com documentação em `docs/TELEGRAM.md`.

Gateway Mini App implementado nesta fatia:

- contrato `manager-telegram-gateway-request-v1` com allowlist e schemas fechados por ação;
- ponte usa credencial Ed25519 v2 do principal e entra pela Automation v2 normal, sem `local-root` na ação final;
- `managerd` continua sendo a autoridade de role/subject/node/pool/action scope e revalida RBAC antes da idempotência;
- rate limit reutiliza o bucket da Automation v2 por principal/ação;
- `request_id` Telegram é namespaced por principal e reutiliza o cache idempotente já existente; payload divergente com o mesmo ID é conflito;
- `initData`, bot token e credencial privada não entram em argv, audit ou contrato público do gateway;
- gate E2E cobre HMAC/freshness -> binding -> gateway -> Ed25519 -> RBAC -> dispatcher, replay idempotente, conflito e rate limit.

Ingresso Telegram Bot implementado nesta fatia:

- ingresso autenticado do Telegram Bot por long polling HTTPS, reutilizando o gateway tipado;
- long polling HTTPS com a Telegram Bot API sem listener público adicional;
- `from.id` numérico é resolvido no binding existente e nunca substituído por username/chat/nome;
- comandos Bot são mapeados para o mesmo contrato `manager-telegram-gateway-request-v1`;
- Automation v2 continua autoridade única para RBAC, scopes, rate limit, idempotência e dispatcher;
- offset de `update_id` é persistente/root-only para impedir reexecução de update consumido;
- bot token permanece fora de argv/audits/respostas.

Ainda pendente para fechar toda a integração Bot/Mini App da série 0.9:

- webhook autenticado como transporte alternativo ao long polling;
- telas/fluxos de produto posteriores.

Fases seguintes da série 0.9:

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
