# MANAGER Roadmap

Este documento registra a direção técnica do MANAGER até a versão 1.0. O objetivo é preservar as capacidades úteis do ecossistema SSHPlus, modernizar a implementação e adicionar uma nova camada de automação e operação multi-servidor.

## Princípios

- O MANAGER novo não deve ser uma versão funcionalmente capada do SSHPlus original.
- Compatibilidade não significa copiar práticas inseguras do legado.
- Operações privilegiadas devem passar por ações conhecidas e auditáveis; integrações nunca devem receber shell arbitrário.
- Nenhum módulo deve limpar o firewall global, sobrescrever toda a configuração SSH ou usar permissões `777`.
- Administração remota futura será centrada em Telegram Bot + Telegram Mini App, sem painel web administrativo convencional.

## 0.4.x — Fundação

- corrigir regressões e inconsistências dos módulos atuais;
- endurecer instalador, atualização e rollback;
- manter CI com Bash syntax, ShellCheck e regressões de segurança;
- ampliar testes para distribuições suportadas;
- manter documentação sincronizada com o código.

## 0.5.0 — Paridade SSHPlus útil

Reimplementar, de forma moderna, as capacidades ainda ausentes do MANAGER original, incluindo conforme aplicável:

- contas temporárias/teste;
- limpeza e relatório de expirados;
- backup e migração de usuários;
- banner;
- speedtest;
- monitor de sessões SSH;
- hosts e serviços de proxy suportados;
- gerenciamento central de serviços;
- revendedores e subrevendedores;
- cotas e propriedade das contas.

Recursos legados que dependerem de técnicas obsoletas ou inseguras devem receber uma implementação moderna equivalente, e não uma cópia literal.

## 0.6.0 — Connection Engine

Criar uma camada comum para identidades e protocolos:

- SSH;
- WireGuard;
- OpenVPN;
- TLS e proxies suportados;
- IPv4/IPv6;
- expiração;
- ACL/políticas;
- limite de sessões;
- tráfego e estado por conta.

A conta passa a ser uma identidade MANAGER que pode possuir acesso a um ou mais protocolos, em vez de o núcleo assumir que toda identidade é somente um usuário Linux.

## 0.7.0 — Automation Engine

### Legacy v1

Uma única conexão de compatibilidade para o antigo ecossistema `syncpainel`, compartilhada pelos projetos/painéis compatíveis. Não haverá um protocolo separado por versão de painel.

O Legacy deve ser opcional e ficar desligado por padrão em instalações novas.

Interface planejada:

```text
manager automation legacy status
manager automation legacy enable
manager automation legacy disable
manager automation legacy restart
```

Quando desligado, nenhum listener ou tarefa exclusiva do Legacy deve permanecer ativo. Dados e configuração são preservados para reativação posterior.

A compatibilidade deve preservar o comportamento necessário para integrações antigas, mas não práticas inseguras como armazenamento desnecessário de senhas em texto claro.

### Automation v2

Novo protocolo oficial para integrações futuras:

- ações estruturadas e versionadas;
- IDs de requisição e idempotência;
- respostas e códigos de erro padronizados;
- RBAC;
- auditoria;
- autenticação criptográfica;
- anti-replay;
- rate limiting;
- interface local por Unix socket;
- `managerd`/`managerctl` ou mecanismo equivalente;
- nenhuma execução remota de shell arbitrário.

## 0.8.0 — Modo Colmeia

A Colmeia é uma rede de servidores MANAGER cooperando. Ela não é definida por país: pode reunir VPS no mesmo datacenter, cidade, país ou em várias regiões do mundo.

### Nós e regiões

Cada servidor terá identidade própria e metadados como:

- `server_id`;
- chave/fingerprint;
- país e região;
- provedor;
- capacidade/peso;
- protocolos disponíveis;
- estado e saúde.

Regiões são agrupamentos lógicos. Uma região Brasil pode conter várias VPS brasileiras, por exemplo.

### Distribuição de carga

O scheduler da Colmeia deve considerar, entre outros sinais:

- CPU;
- RAM;
- uso de rede;
- número de sessões;
- latência;
- estado dos serviços;
- capacidade/peso do servidor;
- protocolo solicitado.

Recursos planejados:

- weighted scheduling;
- sticky session/afinidade;
- limites de capacidade;
- `drain` para manutenção sem receber novas sessões;
- failover;
- health heartbeat;
- resultados parciais quando alguns nós estiverem offline.

### Sessões globais

A quantidade simultânea pertence à identidade/plano, e não individualmente a cada VPS.

Exemplo: uma conta pode ter acesso a dez servidores ou países, mas `max_sessions_global=1`. Se já houver uma sessão ativa em um nó, uma segunda conexão em outro nó deve ser negada ou executar uma troca controlada.

A implementação deve usar leases atômicos, heartbeat e expiração para evitar sessões presas e condições de corrida.

### Segurança da Colmeia

- identidade criptográfica por nó;
- bootstrap por convite/token temporário;
- chaves privadas permanecem no nó correspondente;
- comunicação autenticada e criptografada usando primitivas criptográficas consolidadas;
- rotação de chaves de sessão;
- proteção anti-replay;
- comprometimento de um nó não deve fornecer credenciais administrativas dos demais nós.

Nós devem preferencialmente iniciar a conexão de controle para reduzir a necessidade de portas administrativas públicas em todas as VPS.

## 0.9.0 — Telegram

Administração remota oficial via Telegram:

- Bot;
- Mini App;
- identidade principal pelo `Telegram user.id` numérico;
- validação server-side do contexto de autenticação do Mini App;
- RBAC no backend independentemente do que a UI exibe.

Papéis iniciais:

- admin;
- revendedor;
- subrevendedor;
- usuário.

O Mini App deve mostrar somente os servidores e operações autorizados ao usuário, enquanto o backend sempre revalida as permissões.

## 0.9.5 — Migração e escala

- importação assistida de instalações SSHPlus conhecidas;
- migração de usuários, limites e validade quando possível;
- testes de compatibilidade Legacy com projetos originais;
- testes de carga e concorrência;
- restauração de backup validada;
- testes de upgrade entre versões.

## 1.0.0 — Produção

Critérios mínimos planejados:

- paridade útil com o MANAGER/SSHPlus original;
- Legacy v1 compatível e desligável;
- Automation v2 estável;
- Colmeia com balanceamento e sessão global;
- comunicação criptografada da camada de controle;
- SSH, WireGuard e OpenVPN integrados ao modelo comum;
- revendedores/cotas;
- Telegram Bot + Mini App;
- backup, auditoria e migração;
- documentação e CI de release;
- suporte oficial às distribuições modernas definidas pelo projeto.

## Depois da 1.0

Possíveis evoluções:

- métricas e histórico avançados;
- roteamento por qualidade/latência;
- autoscaling assistido;
- alta disponibilidade do controlador da Colmeia;
- provisionamento assistido de novos nós;
- políticas de tráfego e capacidade mais avançadas.
