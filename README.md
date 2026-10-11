# MANAGER

Gerenciador moderno de VPS inspirado na experiência clássica do **SSHPlus Manager**, reconstruído para Debian/Ubuntu atuais.

> O objetivo não é executar cegamente binários antigos do SSHPlus. O MANAGER preserva capacidades úteis, substitui implementações inseguras/obsoletas e evolui para uma arquitetura própria de identidade, automação, VPN, revenda e operação multi-servidor.

Versão atual: **0.7.0**.

## Princípios

- não substituir o `sshd_config` inteiro;
- não executar `iptables -F`, `ip6tables -F` ou `nft flush ruleset`;
- não baixar executáveis opacos como root;
- validar configurações antes de recarregar serviços;
- manter módulos opcionais realmente opcionais;
- criar backup/rollback antes de mudanças críticas;
- preservar configurações que não pertencem ao MANAGER sempre que possível;
- compatibilidade com legado não significa copiar fragilidades do legado;
- integrações novas usam operações estruturadas, nunca shell remoto arbitrário.

## Recursos atuais

### Servidor, SSH e VPN

- informações do sistema, kernel, uptime, memória, disco, carga, IPs e serviços;
- usuários SSH: criar/remover, senha, validade, limite simultâneo, bloqueio e sessões;
- contas teste com duração em minutos e remoção automática;
- limpeza e relatório de expirados;
- banner SSH por `sshd_config.d`;
- WireGuard com servidor, clientes, revogação, QR Code e dual-stack IPv4/IPv6 quando a VPS possui saída IPv6 real;
- OpenVPN com Easy-RSA, perfis `.ovpn`, CRL, UDP/TCP e IPv6 opcional;
- IPv6 Guard ligado ao Policy/Session Engine;
- UFW, Fail2ban e hardening SSH;
- DNS Ad Block com dnsmasq;
- Squid privado, proxy TCP, WebSocket e TLS opcionais;
- TLS/Let's Encrypt;
- speedtest, diagnóstico, saúde, logs, manutenção e desempenho/BBR.

### Contas e revenda

- revendedor e subrevendedor;
- hierarquia, bloqueio/reativação e cota total por cliente lógico;
- identidades VPN-only podem pertencer à revenda sem usuário Linux;
- uma identidade ocupa uma vaga mesmo usando vários protocolos;
- cota do subrevendedor também entra no limite agregado do revendedor pai;
- cotas opcionais por produto/plano;
- propriedade SSH legada preservada e deduplicada ao adotar uma identidade;
- criação de conta diretamente vinculada ao proprietário;
- reserva de cota sob lock;
- exportação/restauração segura de usuários;
- detector de estruturas conhecidas do SSHPlus antigo;
- monitor de sessões SSH com encerramento seletivo.

Estado de revenda:

```text
/etc/manager/access/
```

Documentação: [`docs/RESELLER_QUOTAS.md`](docs/RESELLER_QUOTAS.md).

## Connection Engine

Desde a série 0.6, a identidade lógica não depende do `/etc/passwd`.

```text
maria
├── owner = revenda01
├── enabled = 1
├── expires_epoch = 0
├── max_sessions = 1
├── protocols = ssh,wireguard,openvpn
├── ssh_user = maria
├── wireguard_client = maria
└── openvpn_client = maria
```

Estado:

```text
/etc/manager/connection/identities/
```

As identidades não duplicam senhas, chaves privadas WireGuard nem certificados OpenVPN. Elas ligam política, plano e recursos técnicos a uma única conta lógica.

Documentação: [`docs/CONNECTION_ENGINE.md`](docs/CONNECTION_ENGINE.md).

## Policy Engine

O estado efetivo de uma identidade pode incluir:

```text
active
disabled
expired
product-disabled
product-missing
quota-exceeded
```

O Policy Engine aplica esse estado aos recursos reais.

### SSH

```text
/etc/ssh/sshd_config.d/65-manager-identity-policy.conf
/etc/security/limits.d/98-manager-identity.conf
```

Identidades inativas são bloqueadas com `DenyUsers`. Antes de reload, `sshd -t` valida a configuração.

### WireGuard

Uma identidade inativa pode ter somente seu peer retirado do runtime de `wg0`, preservando chaves e configuração persistente.

### OpenVPN

O bloqueio de identidade é reversível e não exige revogar o certificado apenas para uma suspensão temporária.

## Session / Lease Engine

```bash
manager --identity-sessions
manager --identity-sessions maria
manager --leases
manager --leases maria
```

Uma lease possui identidade, protocolo, recurso, dispositivo, `session_id`, `session_epoch`, TTL e heartbeat.

Leases ativas ficam em runtime:

```text
/run/manager-session-leases/active/
```

Fencing persistente:

```text
/etc/manager/connection/session-epochs/<id>.epoch
```

O motor possui aquisição atômica local, `max_sessions` sob lock, retry idempotente, TTL, heartbeat, release, troca de sessão, fencing e revogação automática quando política/recurso deixa de ser válido.

Documentação: [`docs/SESSION_ENGINE.md`](docs/SESSION_ENGINE.md).

## Protocol Lease Bridge

```text
SSH / WireGuard / OpenVPN
            ↓
   Protocol Lease Bridge
            ↓
       Session Engine
```

- SSH usa hook de sessão PAM;
- OpenVPN usa uma fila runtime privilegiada e allowlisted, sem entregar shell root ao daemon;
- WireGuard usa handshake recente como atividade e gate específico do peer;
- reconciliação periódica mantém leases e conexões reais alinhadas.

## Identity Usage Accounting

```bash
manager --usage
manager --usage maria
```

WireGuard e OpenVPN alimentam bytes reais reportados pelos protocolos. A primeira observação vira baseline e somente deltas posteriores entram no acumulado. Reset de contador do daemon não apaga o histórico.

SSH participa de sessão e última atividade, mas o MANAGER não inventa byte accounting por UID. Quando SSH está vinculado:

```text
traffic_complete=0
ssh_bytes_supported=0
```

Estado persistente:

```text
/var/lib/manager/identity-usage/identities/
```

Documentação: [`docs/IDENTITY_USAGE.md`](docs/IDENTITY_USAGE.md).

## Produtos, planos, ACL e franquias

```bash
manager --products
manager --product premium
manager --product-assignment maria
```

Produtos podem restringir protocolos, `max_sessions`, duração/expiração, franquia de bytes e ACL de região/pool/nó. Produto restringe a política base; não amplia privilégio silenciosamente.

Franquias podem usar ciclo `monthly` ou `lifetime`, com ação `warn` ou `block`. Uma franquia SSH não é bloqueada usando dados de tráfego incompletos.

Documentação: [`docs/PRODUCTS.md`](docs/PRODUCTS.md).

## Provisionamento unificado

```bash
manager --provision maria brasil-premium
manager --provision maria brasil-premium '' wireguard,openvpn
manager --provision cliente01 plano-ssh revenda01 ssh
```

O provisionador faz preflight, cria a identidade, aplica o produto, materializa somente os protocolos selecionados, cria bindings e reconcilia política. Falha intermediária aciona rollback dos recursos criados naquela tentativa.

No SSH, a senha aleatória fica bloqueada durante a transação e é mostrada uma única vez após o commit. Ela não entra no log operacional.

Revogação:

```bash
manager --revoke-identity maria
```

A identidade lógica permanece `disabled` para histórico/auditoria.

Documentação: [`docs/PROVISIONING.md`](docs/PROVISIONING.md).

## IPv6 / dual-stack

O MANAGER habilita IPv6 na VPN somente quando a VPS possui rota IPv6 padrão e endereço global utilizável.

WireGuard usa ULA própria em `fd66:66:66::/64`; OpenVPN usa `fd66:8::/64`. O modo portátil atual usa ULA + NAT66.

```bash
manager --ipv6-status
```

O IPv6 Guard espelha a decisão do Policy/Session Engine no forwarding IPv6 sem executar flush global do firewall.

Documentação: [`docs/IPV6.md`](docs/IPV6.md).

## Identidade e metadados do nó

Cada VPS possui um `node_id` persistente:

```text
/etc/manager/connection/node/node.conf
```

Metadados incluem nome, país, região, pool, provedor, cidade, capacidade, peso, limite declarado de sessões e estado administrativo.

```bash
manager --node
manager --node-context
manager --node-set country BR
manager --node-set region BR-SP
manager --node-set pool BRASIL-PREMIUM
manager --node-set capacity 8
manager --node-set weight 3
manager --node-set max_sessions 500
```

`country` é metadado; região e pool continuam sendo agrupamentos lógicos administrados pelo operador.

Documentação: [`docs/NODE_METADATA.md`](docs/NODE_METADATA.md).

## ACL automática por nó

O Product Policy resolve automaticamente `region`, `pool` e `node_id` do nó local quando o chamador não envia contexto explícito.

```bash
/opt/manager/modules/products.sh --authorize maria wireguard
```

ACL restrita falha fechada quando o metadado obrigatório está ausente ou não corresponde ao produto.

Documentação: [`docs/NODE_PRODUCT_ACL.md`](docs/NODE_PRODUCT_ACL.md).

## Fechamento do Connection Engine — 0.6.11

A série 0.6.x terminou com duas superfícies preparatórias para as camadas posteriores.

### Lifecycle allowlisted

```bash
/opt/manager/modules/connection_actions.sh --describe
/opt/manager/modules/connection_actions.sh --status maria
/opt/manager/modules/connection_actions.sh --preflight maria premium '' ssh,wireguard
/opt/manager/modules/connection_actions.sh --create maria premium '' ssh,wireguard
/opt/manager/modules/connection_actions.sh --revoke maria
```

O contrato `manager-connection-actions-v1` declara:

```text
arbitrary_shell=0
arbitrary_command=0
arbitrary_path=0
```

Documentação: [`docs/CONNECTION_ACTIONS.md`](docs/CONNECTION_ACTIONS.md).

### Uso agregado local por nó

```bash
/opt/manager/modules/node_usage.sh --show
```

O contrato `manager-node-usage-v1` agrega identidade do nó, região/pool, identidades, leases/sessões, protocolos, última atividade e bytes já contabilizados.

```text
usage_scope=node-local
billing_authoritative=0
global_usage_supported=0
```

Documentação: [`docs/NODE_USAGE.md`](docs/NODE_USAGE.md).

## Automation Legacy v1 — 0.7.0

A primeira etapa da série 0.7 implementa a compatibilidade controlada com o antigo ecossistema `syncpainel`.

Ela fica **desligada por padrão**.

```bash
manager automation legacy status
manager automation legacy enable
manager automation legacy enable 22022
manager automation legacy disable
manager automation legacy restart
manager automation legacy rotate-password
```

### Transporte compatível sem root remoto

Ao ativar, o MANAGER cria uma instância SSH dedicada e a conta:

```text
manager-legacy
```

O painel antigo pode continuar usando os campos tradicionais de servidor (`login_server`, senha e porta), mas a credencial não é `root`.

O listener dedicado possui:

- `PermitRootLogin no`;
- sem TTY;
- sem TCP/agent/X11 forwarding;
- sem túnel SSH;
- `ForceCommand` fixo;
- regra `sudoers` validada por `visudo` permitindo elevar somente o dispatcher Legacy;
- guard no SSH principal para impedir que `manager-legacy` vire shell normal.

A senha de integração é gerada na primeira ativação e devolvida uma única vez. Ela não é gravada em texto claro no estado ou no audit log do MANAGER.

### Contrato histórico suportado

```text
criarusuario.sh USER PASSWORD DAYS LIMIT
remover.sh USER
AlterarSenha.sh USER PASSWORD
AlterarData.sh USER DAYS
alterarlimite.sh USER LIMIT
KillUser.sh USER
sshmonitor.sh
```

O dispatcher usa allowlist e não executa `eval`. Qualquer comando fora dessa lista é recusado.

As operações de alteração/remoção só podem atingir usuários SSH vinculados ao Connection Engine. `root`, `manager-legacy` e usuários locais alheios ao MANAGER não podem ser manipulados pelo Legacy.

O adapter preserva os retornos relevantes esperados pelos painéis antigos, mas não recria `/root/usuarios.db`, `/etc/SSHPlus/senha`, `chmod 777`, firewall destrutivo ou senha em texto claro.

Estado:

```text
/etc/manager/automation/legacy/
```

Quando `disable` é executado, o serviço para, a porta dedicada fecha, a regra privilegiada é removida e a conta de integração fica bloqueada. Configuração é preservada para reativação.

O Legacy não abre porta UFW automaticamente. O operador decide explicitamente a regra de firewall, preferencialmente limitando a origem ao servidor do painel.

Documentação: [`docs/AUTOMATION_LEGACY.md`](docs/AUTOMATION_LEGACY.md).

## Limite atual e próxima etapa

Hoje a autoridade de lease, produto, accounting e cota ainda é local na VPS.

A **Automation Legacy v1 está concluída**, mas a **Automation v2 ainda não está**. A próxima etapa do 0.7 é introduzir a interface oficial para integrações novas: `managerd/managerctl` ou equivalente, Unix socket privilegiado, ações versionadas, request IDs, idempotência, RBAC, auditoria estruturada, autenticação criptográfica, anti-replay e rate limiting.

Somente depois dessa camada o roadmap entra na 0.8 Colmeia, onde locks e leases passam a poder ter autoridade global e entram heartbeat, scheduler, drain/failover e agregação multi-nó.

## Backup e migração

Backups ficam em `/var/backups/manager/` e incluem, quando presentes:

```text
/etc/manager/access
/etc/manager/connection
/etc/manager/automation
/etc/manager/proxy
/var/lib/manager/identity-usage/identities
estado WireGuard/OpenVPN
DNS/TLS/banner/performance
```

A exportação de usuários Linux é separada e não guarda senha em texto claro nem substitui `/etc/passwd`/`etc/shadow` inteiros durante restauração.

O detector de legado reconhece estruturas como `/root/usuarios.db`, `/etc/SSHPlus/senha/` e `/root/backup.vps` para migração assistida futura; o Legacy v1 não volta a usar essas estruturas inseguras.

## Segurança

- hardening OpenSSH por drop-in;
- Fail2ban;
- UFW com IPv4/IPv6 quando administrado pelo MANAGER;
- atualizações automáticas de segurança;
- TLS/Let's Encrypt;
- fingerprints de chaves públicas;
- Squid sem `http_access allow all`;
- nenhum flush global de firewall IPv4/IPv6;
- credenciais VPN com permissões restritas;
- estado de identidade, produto, revenda, nó e accounting restritos a root;
- OpenVPN não recebe shell root para conversar com o Lease Engine;
- IPv6 Guard cria/remove somente regras específicas;
- hooks externos são removidos antes de uninstall/rollback;
- provisionamento não registra senha/chaves privadas no audit log;
- ACL restrita de região/pool/nó falha fechada;
- `manager-connection-actions-v1` não aceita shell, comando ou caminho arbitrário;
- Legacy v1 usa conta não-root, SSH dedicado, `ForceCommand`, sudoers exato e allowlist;
- credencial Legacy não é armazenada em texto claro pelo MANAGER;
- Legacy desativado significa serviço parado, porta fechada e conta bloqueada;
- self-update baixa e valida o instalador antes da execução.

## CLI principal

```text
manager --health
manager --status
manager --expired
manager --ssh-sessions
manager --proxy-status
manager --proxy-hosts
manager --identities
manager --identity ID
manager --products
manager --product ID
manager --product-assignment ID
manager --reseller-usage OWNER
manager --reseller-product-quota OWNER PRODUCT
manager --provision ID PLAN [OWNER] [PROTOCOLS]
manager --revoke-identity ID
manager --identity-sessions [ID]
manager --leases [ID]
manager --usage [ID]
manager --ipv6-status
manager --node
manager --node-context
manager --node-set FIELD VALUE
manager automation legacy status
manager automation legacy enable [PORT]
manager automation legacy disable
manager automation legacy restart
manager automation legacy rotate-password
manager --diagnostics
manager --version
manager --help
```

Contratos internos:

```text
/opt/manager/modules/connection_actions.sh
/opt/manager/modules/node_usage.sh
/opt/manager/modules/automation_legacy.sh
```

## Sistemas suportados

- Ubuntu 22.04 ou superior;
- Debian 12 ou superior;
- `systemd` e `apt`.

## Instalação

Evite executar instalador remoto por pipe:

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/SrTristeSad/MANAGER/main/install.sh \
  -o /tmp/manager-install.sh
bash -n /tmp/manager-install.sh
bash /tmp/manager-install.sh
rm -f /tmp/manager-install.sh
```

Depois:

```bash
manager
```

Alias clássico: `menu`.

## Atualização, rollback e remoção

Atualização: opção `90` do menu.

```bash
manager-rollback
manager-uninstall
```

O uninstall normal preserva identidades, produtos, cotas/slots, ACL, baseline de franquia, `session_epoch`, metadados do nó, estado dual-stack, histórico consolidado de uso e configuração do Legacy. Porém o listener Legacy é fechado, a regra privilegiada é removida e `manager-legacy` fica bloqueado enquanto o código não está instalado.

Purge explícito:

```bash
manager-uninstall --purge
```

O purge remove também o estado do MANAGER, histórico de uso e a conta de integração Legacy. Pacotes do sistema, certificados Let's Encrypt, backups e regras alheias ao MANAGER continuam sendo tratados conservadoramente.

## Roadmap

Plano detalhado: [`docs/ROADMAP.md`](docs/ROADMAP.md).

```text
0.5.x  paridade SSHPlus útil                                         ✅
0.6.x  Connection/Policy/Session Engine completo                     ✅
0.7.0  Automation Legacy v1                                          ✅
0.7.x  Automation v2                                                 próximo
0.8.0  Modo Colmeia
0.9.0  Telegram Bot + Mini App
0.9.5  migração e escala
1.0.0  release de produção
```

### Automation v2

Será a interface oficial para projetos novos. Reutilizará o lifecycle allowlisted da 0.6.11 e adicionará contrato versionado, idempotência, RBAC, auditoria, autenticação criptográfica, anti-replay, rate limiting e interface local privilegiada controlada. Não haverá shell remoto arbitrário.

### Colmeia

A partir da base local existente: identidade criptográfica por nó, heartbeat/health, regiões/pools, capacidade real, drain/failover, sticky sessions, scheduler weighted least-loaded, sessão global por identidade/plano, cota global de revenda, fencing global, agregação global de uso e comunicação autenticada/criptografada.

### Telegram

Administração futura por Bot + Mini App, sem painel web administrativo convencional obrigatório.

## Testes

O CI cobre, entre outros:

- `bash -n` e ShellCheck;
- regressões de firewall/permissão e Squid aberto;
- política segura de fonte do instalador;
- instalação/update/rollback/uninstall;
- Connection/Policy/Session Engine;
- Protocol Lease Bridge;
- Identity Usage;
- produtos, ACL e franquias;
- provisionamento e revogação;
- cotas de revenda e produto;
- IPv6 dual-stack e guard;
- metadados e ACL automática de nó;
- lifecycle allowlisted e agregado local de uso;
- Legacy v1 desligado por padrão;
- validação `sshd -t` e `visudo` da fronteira Legacy;
- criação/alteração/remoção pelos comandos históricos;
- recusa de comando fora da allowlist;
- ausência de segredos Legacy/SSH nos arquivos de estado e audit logs;
- disable fechando listener e bloqueando a conta;
- persistência segura em uninstall/reinstall;
- purge removendo estado e conta de integração.

## Origem

O SSHPlus Manager original foi desenvolvido por **@crazy_vpn** e deu origem a vários forks comunitários. O MANAGER preserva a ideia de administração simples por terminal, mas evolui para uma arquitetura própria de identidade, automação, leases, accounting, produtos e operação multi-servidor.
