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

### Próximos itens 0.6.x

Antes da Automation v2, a base comum ainda deve ganhar:

1. registro comum de tráfego/estado por identidade e protocolo;
2. ACL/políticas independentes do protocolo;
3. provisionamento/revogação de SSH, WireGuard e OpenVPN pelo próprio Connection Engine;
4. cotas de revenda baseadas em **produto/identidade**, não somente usuário Linux;
5. IPv6 completo;
6. metadados de endpoint/nó/região que serão consumidos pela Colmeia.

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

O Protocol Lease Bridge da 0.6.3 deve continuar sendo a fronteira entre daemons de conexão e a autoridade de sessão, permitindo trocar a autoridade local por Automation/Colmeia sem reescrever os protocolos.

## 0.8.0 — Modo Colmeia

A Colmeia é uma rede de servidores MANAGER cooperando. Ela pode reunir VPS no mesmo datacenter, cidade, país ou em várias regiões.

### Nós e regiões

Cada servidor terá identidade própria e metadados como:

- `server_id`;
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
allowed_nodes = BR-01, US-01, DE-01, FR-01, ...
max_sessions_global = 1
```

Se já houver uma sessão ativa em um nó, uma segunda conexão em outro nó é negada ou executa uma troca controlada.

A Colmeia reutilizará os conceitos já implementados em 0.6.x:

```text
session_id
TTL
heartbeat
session_epoch
fencing
```

A diferença será a autoridade: o lock deixa de ser local e passa a ser global no Hub.

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
