# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. O objetivo é preservar as capacidades úteis do ecossistema SSHPlus, modernizar a implementação e adicionar uma nova camada de automação e operação multi-servidor.

## Princípios

- O MANAGER novo não deve ser uma versão funcionalmente capada do SSHPlus original.
- Compatibilidade não significa copiar práticas inseguras do legado.
- Operações privilegiadas passam por ações conhecidas e auditáveis; integrações nunca recebem shell arbitrário.
- Nenhum módulo deve limpar o firewall global, sobrescrever toda a configuração SSH ou usar permissões `777`.
- Administração remota futura será centrada em Telegram Bot + Telegram Mini App, sem painel web administrativo convencional obrigatório.

## 0.4.x — Fundação

Concluído como base de confiabilidade:

- health check;
- manutenção;
- CLI não interativa;
- atualização/rollback conservadores;
- CI com Bash syntax, ShellCheck e regressões de segurança;
- endurecimento do instalador e da política de downloads.

## 0.5.x — Paridade SSHPlus útil

Status em **0.5.2**: a paridade operacional principal está implementada. O MANAGER já possui equivalentes modernos para:

- contas temporárias/teste;
- limpeza e relatório de expirados;
- backup e migração segura de usuários;
- banner;
- speedtest;
- monitor de sessões SSH;
- hosts de proxy e importação controlada de `payload.txt`;
- Squid privado, proxy TCP e túneis WebSocket/TLS opcionais;
- gerenciamento central de serviços;
- revendedores e subrevendedores;
- cotas e propriedade das contas;
- criação de conta diretamente vinculada ao revendedor com proteção contra corrida de cota.

Recursos legados dependentes de técnicas obsoletas/inseguras recebem implementação moderna equivalente, não cópia literal. Conversão completa de formatos antigos permanece uma etapa assistida de migração.

## 0.6.x — Connection, Policy e Session Engine

### 0.6.0 — identidade comum

Concluído:

- identidade MANAGER independente do usuário Linux;
- protocolos `ssh`, `wireguard` e `openvpn` por identidade;
- propriedade/revenda;
- expiração;
- `max_sessions`;
- bindings para recursos técnicos existentes;
- contratos estruturados de criação, consulta, bind e enable/disable.

### 0.6.1 — enforcement

Concluído:

- estado `active/disabled/expired` aplicado aos protocolos;
- `DenyUsers` e limites SSH sem substituir `sshd_config`;
- WireGuard removido/restaurado somente em runtime;
- OpenVPN bloqueável de forma reversível;
- visão consolidada `manager --identity-sessions`;
- reconciliação automática de política.

### 0.6.2 — Session / Lease Engine

Concluído:

- `session_id` estável por lease;
- TTL/heartbeat/release;
- aquisição idempotente;
- limite local atômico sob lock;
- `session_epoch` persistente;
- fencing;
- `switch` e `revoke-all`;
- invalidação de geração por mudança de política;
- `manager --leases` separado da visão de sessões observadas.

### 0.6.3 — Protocol Lease Bridge

Concluído:

- SSH `open_session/close_session` ligado a lease via PAM;
- OpenVPN `client-connect/client-disconnect` ligado a lease por fila runtime privilegiada controlada, sem dar shell root ao daemon;
- WireGuard ligado a lease por handshake recente e gate específico de tráfego do peer;
- heartbeat/reconciliação entre conexões reais e leases;
- adoção de sessões existentes durante upgrade;
- rollback/uninstall conscientes de hooks externos ao `/opt/manager`;
- CI cobrindo limite `1/1`, release e lifecycle completo do bridge.

### 0.6.4 — Identity Usage Accounting

Concluído:

- camada comum de tráfego e atividade por identidade;
- bytes reais de WireGuard e OpenVPN consolidados por identidade;
- primeira leitura usada como baseline, evitando contabilizar tráfego anterior à ativação do coletor;
- tratamento de reset/restart dos contadores absolutos sem zerar o acumulado da identidade;
- última atividade/protocolo/recurso alimentados pelas leases reais;
- SSH participa de sessão e atividade, mas bytes ficam explicitamente não medidos para evitar números falsos derivados de tráfego genérico do UID;
- indicador `traffic_complete` diferencia totais completos de medições parciais;
- estado persistente em `/var/lib/manager/identity-usage` e snapshots de origem separados;
- `manager --usage [ID]`, menu próprio e integração com `Tráfego e conexões`;
- coleta periódica por systemd;
- backup transporta somente os acumulados consolidados, não baselines de outro nó;
- uninstall normal preserva o histórico e `--purge` remove explicitamente;
- CI dedicado cobre baseline, delta, reset, vínculo, persistência e purge.

### 0.6.5 — Produtos, planos, ACL e franquias

Concluído:

- catálogo de produtos/planos separado das credenciais técnicas;
- vínculo de um produto a uma identidade MANAGER;
- preservação dos valores base de `max_sessions`, protocolos e expiração antes de aplicar o produto;
- produto restringe protocolos pela interseção com a política base e nunca amplia privilégios silenciosamente;
- produto pode reduzir `max_sessions` e duração/expiração;
- desvincular produto restaura a política base registrada;
- produto desabilitado produz estado efetivo `product-disabled`;
- franquia em bytes com ciclos `monthly` e `lifetime`;
- baseline no momento da atribuição/reset para não cobrar tráfego anterior retroativamente;
- ações `warn` e `block` ao exceder franquia;
- `quota-exceeded` integra-se ao mesmo `identity_effective_state` consumido pelo Policy e Session Engine;
- franquia com SSH vinculado é marcada como não-enforçável enquanto os bytes SSH não forem medidos de forma confiável;
- ACL de protocolo, região, pool e nó;
- protocolo já é aplicado automaticamente pela política efetiva da identidade;
- região/pool/nó possuem contrato de autorização pronto para o contexto futuro da Colmeia;
- `manager --products`, `manager --product ID` e `manager --product-assignment ID`;
- reconciliador periódico `manager-product-policy.timer`;
- catálogo, vínculos e baseline ficam sob `/etc/manager/connection`, entrando no backup/lifecycle existente;
- CI dedicado cobre ACL, limite de sessões, `warn/block`, franquia, SSH parcial, restauração da política base, uninstall/reinstall e purge.

### 0.6.6 — Provisionamento Unificado

Concluído:

- nova operação `manager --provision ID PLANO [OWNER] [PROTOCOLS]`;
- preflight valida produto, protocolos, conflitos e dependências antes de alterar o sistema;
- identidade, produto, recursos técnicos e bindings passam a ser tratados como uma única operação;
- usuário SSH nasce bloqueado durante a transação e só é liberado depois da reconciliação bem-sucedida;
- senha SSH aleatória é devolvida uma única vez e não entra no log de eventos;
- WireGuard cria somente peer/perfil do cliente solicitado, sem alterações destrutivas globais;
- OpenVPN reutiliza a PKI Easy-RSA existente e revoga certificado emitido se a transação precisar ser desfeita;
- falha intermediária aciona rollback dos recursos criados naquela tentativa;
- sinais intermediários do watcher de política podem ser adiados durante o fluxo CLI para evitar aplicação de identidade parcialmente construída;
- revogação `manager --revoke-identity ID` desativa primeiro, revoga leases, remove/revoga recursos técnicos e preserva a identidade lógica desativada para histórico/auditoria;
- log restrito `/var/log/manager/provision-events.log` guarda apenas metadados operacionais, sem senha ou chave privada;
- CI dedicado cobre criação SSH por produto, validade, limite de sessões, duplicata, preflight de VPN indisponível, revogação e persistência da identidade lógica após uninstall/reinstall;
- documentação própria em `docs/PROVISIONING.md`.

### 0.6.7 — Cotas de revenda por identidade/produto

Concluído:

- a unidade de cota passa de usuário Linux para identidade lógica MANAGER;
- identidades somente WireGuard ou somente OpenVPN agora podem pertencer a revendedor/subrevendedor sem conta SSH;
- uma identidade consome uma única vaga mesmo quando combina SSH, WireGuard e OpenVPN;
- reserva de slot ocorre antes da gravação da identidade e sob lock, impedindo corrida de criação acima da cota;
- uso de subrevendedor continua agregado à cota do revendedor pai;
- contas SSH legadas ainda contam enquanto não forem absorvidas por uma identidade, com deduplicação durante adoção;
- identidades revogadas preservadas pela 0.6.6 são migradas sem voltar a consumir cota;
- bloqueio temporário mantém a vaga, enquanto revogação completa libera o slot;
- reativação de identidade com slot liberado precisa reservar capacidade novamente;
- cotas opcionais por produto permitem limitar, por exemplo, quantos clientes `premium` cada revendedor pode manter;
- cota de produto do subrevendedor também respeita o limite agregado do pai;
- `products.sh --assign` aplica a cota de produto mesmo fora do provisionador;
- o preflight do provisionamento verifica cota total + cota de produto antes da criação dos recursos;
- novas consultas `manager --reseller-usage OWNER` e `manager --reseller-product-quota OWNER PRODUCT`;
- estado permanece sob `/etc/manager/access`, entrando no backup/lifecycle existente;
- CI dedicado cobre identidades VPN-only, pai/subrevendedor, reativação, cotas de produto, legado sem dupla contagem, migração de identidade revogada e persistência após uninstall/reinstall;
- documentação própria em `docs/RESELLER_QUOTAS.md`.

### 0.6.8 — IPv6 / dual-stack

Concluído:

- detecção compartilhada de rota IPv6 padrão e endereço global antes de habilitar dual-stack;
- WireGuard com `fd66:66:66::/64`, clientes IPv4 + IPv6, `::/0`, endpoint IPv6 literal corretamente formatado e migração de clientes existentes sem trocar chaves;
- OpenVPN com `fd66:8::/64`, `server-ipv6`, redirect IPv6 e rollback da migração quando o daemon não volta saudável;
- ULA + NAT66 como modo portátil para provedores que não delegam prefixo aos clientes;
- UFW configurado para cobrir IPv4 e IPv6 antes de administrar regras;
- novo IPv6 Guard espelhando no IPv6 as decisões já tomadas pelo Policy/Session Engine;
- bloqueio específico por identidade/IPv6 quando não há lease/política válida, sem flush global de firewall;
- `manager-ipv6-guard.timer` e lifecycle completo em install/update/rollback/uninstall;
- preservação e restauração do valor anterior de `net.ipv6.conf.all.forwarding` no purge;
- provisionamento unificado herda o estado dual-stack dos servidores e expõe `wireguard_ipv4`, `wireguard_ipv6` e `openvpn_ipv6`;
- `manager --ipv6-status` e opção própria no menu;
- accounting WireGuard/OpenVPN continua único, pois os contadores do túnel incluem tráfego IPv4 e IPv6;
- documentação própria em `docs/IPV6.md`;
- CI `IPv6 Dual Stack` cobre helpers, guard por lease e lifecycle.

### 0.6.9 — identidade e metadados do nó

Concluído:

- `node_id` persistente e independente das identidades de clientes;
- metadados administrativos `country`, `region`, `pool`, `provider`, `city`, `capacity`, `weight`, `max_sessions` e `enabled`;
- descoberta local de protocolos disponíveis e capacidade IPv6;
- `node_id` imutável por operações normais e preservado em reinstall;
- estado armazenado dentro de `/etc/manager/connection/node`, herdando backup/lifecycle do Connection Engine;
- comandos de consulta/contexto e atualização somente de campos allowlisted;
- CI dedicado cobrindo validação, imutabilidade e persistência.

### 0.6.10 — ACL automática pelo contexto do nó

Concluído:

- Product Policy resolve automaticamente `region`, `pool` e `node_id` a partir do nó local quando o chamador não fornece contexto explícito;
- valores explícitos continuam suportados para compatibilidade e testes;
- ACL restrita falha fechada quando o metadado necessário está ausente;
- Session Engine usa a mesma autorização e recusa lease em nó fora da ACL;
- CI dedicado cobre região/pool/nó corretos, incorretos, metadado ausente e compatibilidade manual.

### 0.6.11 — fechamento do Connection Engine

Concluído:

- agregado local `manager-node-usage-v1` soma uso medido e atividade por `node_id` sem criar um segundo banco de accounting;
- snapshot local inclui identidades, leases/sessões, protocolos ativos, bytes WireGuard/OpenVPN, última atividade e metadados do nó;
- o contrato declara `billing_authoritative=0` e `global_usage_supported=0`, impedindo que telemetria local seja confundida com faturamento global;
- cobertura incompleta de bytes por presença de SSH continua explícita por `traffic_complete=0` e `ssh_bytes_supported=0`;
- nova superfície privilegiada `manager-connection-actions-v1` consolida `preflight`, `create`, `revoke`, `status` e `describe`;
- a superfície reutiliza o provisionamento/revogação transacional já existente em vez de duplicar lógica de SSH/WireGuard/OpenVPN;
- somente `ssh`, `wireguard` e `openvpn` podem ser solicitados; não há parâmetro para shell, comando arbitrário ou caminho executável;
- códigos de saída são estabilizados para consumo futuro pela Automation v2;
- documentação em `docs/NODE_USAGE.md` e `docs/CONNECTION_ACTIONS.md`;
- CI dedicado cobre allowlist, segredo SSH fora do log, lifecycle create/status/revoke, accounting local e uninstall.

**Status: a série 0.6.x está concluída.** Novas capacidades de controle remoto, compatibilidade `syncpainel`, API, RBAC, idempotência e transporte pertencem à fase 0.7.x. Saúde distribuída, scheduler e autoridade multi-nó pertencem à fase 0.8.x, não à 0.6.x.

## 0.7.0 — Automation Engine

### Legacy v1

Uma única conexão de compatibilidade para o antigo ecossistema `syncpainel`, compartilhada pelos projetos/painéis compatíveis. Não haverá protocolo separado por versão de painel.

O Legacy é opcional e ficará desligado por padrão em instalações novas.

Interface planejada:

```text
manager automation legacy status
manager automation legacy enable
manager automation legacy disable
manager automation legacy restart
```

Quando desligado, nenhum listener/tarefa exclusiva do Legacy deve permanecer ativo. Dados e configuração são preservados para reativação posterior.

A compatibilidade preserva o contrato necessário para integrações antigas, mas não práticas inseguras como senha em texto claro, `chmod 777` ou alterações destrutivas de firewall.

### Automation v2

Novo protocolo oficial para integrações futuras:

- ações estruturadas e versionadas;
- IDs de requisição e idempotência;
- respostas/códigos de erro padronizados;
- RBAC;
- auditoria;
- autenticação criptográfica;
- anti-replay;
- rate limiting;
- interface privilegiada local por Unix socket;
- `managerd`/`managerctl` ou mecanismo equivalente;
- nenhuma execução remota de shell arbitrário.

O Protocol Lease Bridge da 0.6.3 continua sendo a fronteira entre daemons de conexão e a autoridade de sessão. O Identity Usage da 0.6.4 fornece a visão comum de consumo/atividade, a 0.6.5 fornece produto/limites/ACL, a 0.6.6 fornece provisionamento/revogação transacional, a 0.6.7 fornece cotas por identidade/produto, a 0.6.8 garante dual-stack, a 0.6.9/0.6.10 fornecem identidade/contexto real do nó e a 0.6.11 oferece a superfície allowlisted e telemetria local consumíveis pela Automation. Assim, a fase 0.7 pode tratar transporte, autenticação, autorização e compatibilidade sem reimplementar o ciclo de vida dos protocolos.

## 0.8.0 — Modo Colmeia

A Colmeia é uma rede de servidores MANAGER cooperando. Ela pode reunir VPS no mesmo datacenter, cidade, país ou em várias regiões.

### Nós e regiões

Cada servidor terá identidade própria e metadados como:

- `node_id`;
- chave/fingerprint;
- país e região;
- provedor;
- capacidade/peso;
- protocolos disponíveis;
- estado e saúde.

Regiões serão agrupamentos lógicos. Uma região Brasil pode conter várias VPS brasileiras, por exemplo.

### Distribuição de carga

O scheduler deve considerar:

- CPU;
- RAM;
- uso de rede;
- número de sessões;
- latência;
- estado dos serviços;
- capacidade/peso;
- protocolo solicitado.

Recursos planejados:

- weighted scheduling;
- sticky session/afinidade;
- limites de capacidade;
- `drain`;
- failover;
- health heartbeat;
- resultados parciais quando alguns nós estiverem offline.

### Sessões globais

A quantidade simultânea pertence à identidade/plano, não a cada VPS individualmente.

Exemplo:

```text
Maria
product = global-premium
allowed_region = BR, US, DE, FR, ...
max_sessions_global = 1
```

Se já houver uma sessão ativa em um nó, uma segunda conexão em outro nó é negada ou executa uma troca controlada.

A Colmeia reutilizará os conceitos já implementados em 0.6.x:

```text
product_id
ACL region/pool/node
session_id
TTL
heartbeat
session_epoch
fencing
usage counters
last activity
IPv4/IPv6 dual-stack
```

A diferença será a autoridade: o lock deixa de ser local e passa a ser global no Hub; o uso local de cada nó será agregado sem alterar os contadores originais.

### Segurança da Colmeia

- identidade criptográfica por nó;
- bootstrap por convite/token temporário;
- chave privada permanece no nó correspondente;
- comunicação autenticada e criptografada com primitivas consolidadas;
- rotação de chaves;
- anti-replay;
- comprometimento de um nó não deve entregar credenciais administrativas dos demais;
- nós preferencialmente iniciam conexão de controle para fora, reduzindo portas administrativas públicas.

## 0.9.0 — Telegram

Administração remota oficial via Telegram:

- Bot;
- Mini App;
- identidade principal pelo `Telegram user.id` numérico;
- validação server-side do contexto do Mini App;
- RBAC no backend independentemente da UI.

Papéis iniciais:

- admin;
- revendedor;
- subrevendedor;
- usuário.

O Mini App mostra somente servidores/operações autorizados, enquanto o backend sempre revalida permissões.

## 0.9.5 — Migração e escala

- importação assistida de instalações SSHPlus conhecidas;
- migração de usuários, limites e validade quando possível;
- testes reais de compatibilidade Legacy;
- testes de carga/concorrência;
- restauração de backup validada;
- testes de upgrade entre versões;
- matriz de CI ampliada para distribuições modernas suportadas.

## 1.0.0 — Produção

Critérios mínimos planejados:

- paridade útil com MANAGER/SSHPlus original;
- Legacy v1 compatível e desligável;
- Automation v2 estável;
- Colmeia com balanceamento e sessão global;
- comunicação criptografada da camada de controle;
- SSH, WireGuard e OpenVPN integrados ao modelo comum;
- revendedores/cotas por produto/identidade;
- Telegram Bot + Mini App;
- backup, auditoria e migração;
- documentação e CI de release;
- suporte oficial às distribuições modernas definidas pelo projeto.

## Depois da 1.0

Possíveis evoluções:

- métricas/histórico avançados;
- roteamento por qualidade/latência;
- autoscaling assistido;
- alta disponibilidade do Hub;
- provisionamento assistido de novos nós;
- políticas de tráfego e capacidade mais avançadas.
