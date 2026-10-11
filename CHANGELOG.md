# Changelog

Todas as mudanças relevantes do MANAGER serão registradas aqui.

O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

## [0.6.3] - 2026-10-10

### Protocol Lease Bridge

- Novo `protocol_leases.sh` liga conexões reais de SSH, WireGuard e OpenVPN ao contrato `acquire -> heartbeat -> release` do Session Engine.
- Sessões reais e leases passam a ser duas visões complementares da mesma identidade: `manager --identity-sessions [ID]` mostra o observado e `manager --leases [ID]` mostra a autoridade de vaga.
- O bridge mantém mapas somente em `/run/manager-protocol-leases`, sem transformar estado transitório de conexão em backup durável.
- Timer próprio reconcilia conexões e leases a cada poucos segundos, renovando somente reservas que continuam correspondendo a sessões reais.

### SSH

- Integração de sessão via PAM usando bloco próprio em `/etc/pam.d/sshd` e wrapper `/usr/local/libexec/manager-ssh-lease-hook`.
- `open_session` de usuário vinculado precisa adquirir lease; `close_session` libera a reserva.
- O wrapper é fail-safe quando o código do MANAGER não está presente ou o contexto privilegiado esperado não existe, reduzindo risco de lockout durante rollback/recuperação.
- O reconciliador também adota sessões já abertas observadas por `who`; uma sessão gerenciada que não consiga vaga tem somente seu TTY encerrado e `root` não é alvo dessa rotina.

### OpenVPN

- O processo OpenVPN não recebe shell root nem regra ampla de `sudo` para consultar leases.
- Novo hook não privilegiado `/usr/local/libexec/manager-openvpn-lease-hook` usa fila runtime de pedidos/respostas.
- `manager-openvpn-lease-queue.path` e `.service` processam os pedidos como root por uma superfície allowlisted e devolvem `ALLOW`/`DENY` ao `client-connect`.
- `client-disconnect` libera a lease correspondente.
- Upgrade com clientes já ativos evita restart desnecessário; a mudança de hook pode ficar pendente até o servidor ficar sem clientes, enquanto a reconciliação continua observando/adotando as sessões existentes.
- Sessão OpenVPN gerenciada que não consegue lease pode ter somente seu IP virtual bloqueado, sem revogar certificado.

### WireGuard

- Handshake recente passa a dirigir `acquire`/`heartbeat` da lease do peer gerenciado.
- Sem lease válida, o tráfego daquele peer recebe uma regra específica em `FORWARD`; não existe flush global de firewall.
- Se a regra específica não puder ser aplicada, o fallback remove somente o peer correspondente do runtime do WireGuard.
- Quando o handshake deixa de ser recente, a lease é liberada.

### Lifecycle, rollback e testes

- Instalador entrega `libpam-modules`, instala o Protocol Lease Bridge depois de Connection/Session/Policy Engine e sobe timer/path automaticamente.
- Uninstall desmonta o bridge antes do Session Engine, removendo PAM hooks, hooks OpenVPN, unidades runtime e leases transitórias antes de apagar o código.
- Rollback desmonta bridge/política antes da troca de `/opt/manager` e reaplica somente componentes existentes na versão restaurada, evitando referências a módulos ausentes ao voltar para uma versão anterior.
- Purge continua conservador e não remove grupos potencialmente pré-existentes somente por nome.
- CI ganhou smoke test do bridge: instalação de hooks/unidades, aquisição de uma sessão real simulada, bloqueio da segunda sessão em `max_sessions=1`, release, preservação em update/rollback e remoção completa no uninstall.

### Limite desta etapa

- A autoridade ainda é local a cada VPS. A próxima evolução multi-VPS moverá a decisão de aquisição para o Hub da Colmeia, preservando `session_id`, TTL, heartbeat e `session_epoch` como contrato.

## [0.6.2] - 2026-10-10

### Session / Lease Engine

- Novo `session_engine.sh` como autoridade local de reservas de sessão e fundação do futuro lease global da Colmeia.
- Cada lease recebe `session_id` aleatório de 128 bits, identidade, protocolo, recurso, dispositivo, `session_epoch`, heartbeat e expiração.
- Leases ativas ficam somente em `/run/manager-session-leases`, evitando restaurar sessão fantasma após reboot ou backup.
- O `session_epoch` persistente fica em `/etc/manager/connection/session-epochs` e funciona como fencing token por identidade.
- Aquisições repetidas para a mesma identidade/protocolo/recurso/dispositivo na mesma geração são idempotentes: renovam a lease existente em vez de consumir uma segunda vaga.
- `max_sessions` passa a ser aplicado atomicamente no Lease Engine local sob lock.
- TTL padrão de 90 segundos, heartbeat renovável e limpeza automática de leases expiradas.
- `--switch` avança o epoch, revoga a geração anterior e cria a nova lease na mesma operação protegida por lock.
- `--revoke-all` permite invalidar administrativamente todas as leases da identidade e avançar o fencing token.

### Política, lifecycle e persistência

- Mudança de política invalida leases incompatíveis: identidade desabilitada/expirada, protocolo removido ou vínculo técnico alterado revogam as leases e avançam o epoch.
- Novo `manager-session-reconcile.path` reage ao marcador de mudanças do Connection Engine; timer periódico funciona como retaguarda para TTL e reconciliação.
- Eventos `ACQUIRE`, `RENEW`, `HEARTBEAT`, `RELEASE`, `EXPIRE`, `REVOKE` e `FENCE` são registrados em `/var/log/manager/session-events.log`, sem gravar credenciais.
- Desinstalação normal descarta apenas leases runtime e preserva identidades + `session_epoch`; `--purge` continua sendo a operação explícita para apagar o estado do MANAGER.
- O estado durável do Connection Engine ganhou snapshot defensivo durante uninstall para impedir regressões de módulos de remover identidades/epochs acidentalmente.

### CLI, documentação e testes

- Novo comando `manager --leases [ID]` para consultar reservas locais, separado de `manager --identity-sessions [ID]`, que mostra conexões reais observadas.
- Novo menu `Session / Lease Engine` para inspeção, reconciliação e revogação administrativa.
- Contratos não interativos: `--acquire`, `--heartbeat`, `--release`, `--switch`, `--revoke-all`, `--epoch`, `--cleanup` e `--reconcile`.
- Nova documentação `docs/SESSION_ENGINE.md` descreve TTL, idempotência, fencing, códigos de erro e caminho de migração para Colmeia.
- CI cobre limite `1/1`, retry idempotente, heartbeat, switch, fencing, TTL, invalidação por política e preservação do estado durável através de update, rollback e uninstall.

### Limite desta etapa

- A 0.6.2 cria a autoridade local de leases, mas conexões legadas de SSH/WireGuard/OpenVPN ainda não são obrigadas a adquirir lease em todos os caminhos. A próxima integração ligará os eventos reais de conexão ao contrato de lease sem quebrar clientes existentes.
- A atomicidade desta versão é local à VPS. A Colmeia moverá a autoridade de lease para o hub para garantir `max_sessions_global` entre vários servidores/países.

## [0.6.1] - 2026-10-10

### Policy Enforcement

- Novo `policy_engine.sh` para aplicar o estado efetivo das identidades aos recursos vinculados.
- Identidades `disabled` ou `expired` passam a bloquear o usuário SSH vinculado por drop-in `DenyUsers`, cobrindo senha e chave pública sem alterar o `sshd_config` principal.
- Sessões SSH existentes de identidades inativas são encerradas por TTY, sem matar processos de `root`.
- O limite local disponível para SSH passa a ser escrito em arquivo PAM separado, descontando sessões WireGuard/OpenVPN observadas da mesma identidade.
- WireGuard usa o peer em runtime como mecanismo reversível: identidade inativa remove o peer da interface sem apagar chaves/config; ao reativar, o peer pode ser restaurado a partir do estado existente.
- OpenVPN recebe um hook `client-connect` gerenciado para consultar a política antes de aceitar novas conexões de clientes vinculados.
- Clientes OpenVPN já conectados de uma identidade inativa têm o tráfego bloqueado por regras específicas e reversíveis, sem revogar o certificado.
- O hook OpenVPN só é ativado por restart automático quando não há clientes conectados; caso contrário o restart é adiado para evitar derrubar sessões válidas.

### Sessões e limite local

- Nova visão consolidada de sessões por identidade: SSH, WireGuard, OpenVPN, total observado e `max_sessions`.
- Novo comando `manager --identity-sessions [ID]`.
- `max_sessions` começa a ser aplicado localmente: OpenVPN consulta o total antes de nova conexão; SSH recebe `maxlogins` calculado; WireGuard não é reativado para uma nova sessão quando outras conexões já ocupam todas as vagas.
- Esta limitação local é deliberadamente conservadora e não substitui o futuro lease atômico da Colmeia para concorrência multi-VPS.

### Reconciliação e lifecycle

- `manager-policy-reconcile.path` reage a alterações do estado de identidades e um timer de 30 segundos funciona como retaguarda para expiração/atividade de sessões.
- Nova opção de menu para visualizar sessões e solicitar reconciliação manual.
- Instalador inicializa o enforcement automaticamente.
- Desinstalação sem `--purge` desanexa o enforcement antes de remover o código, preservando o estado das identidades para uma futura reinstalação.
- CI passou a validar autorização/bloqueio/reabilitação de uma identidade SSH vinculada, além da instalação e remoção das unidades de política.

## [0.6.0] - 2026-10-10

### Connection Engine

- Introduzida a identidade MANAGER independente do usuário Linux, armazenada em `/etc/manager/connection/identities`.
- Cada identidade possui ID estável, proprietário opcional, estado habilitado/desabilitado, expiração, limite planejado de sessões e lista de protocolos permitidos.
- Protocolos iniciais reconhecidos pelo modelo: `ssh`, `wireguard` e `openvpn`.
- Uma identidade pode ser vinculada a um usuário SSH, cliente WireGuard e/ou cliente OpenVPN já existentes sem duplicar as credenciais desses protocolos.
- Importação por nome detecta recursos existentes com o mesmo nome e cria/vincula a identidade correspondente.
- Vínculo SSH com proprietário de revenda reutiliza a validação de cota existente antes de registrar a propriedade.
- Estado efetivo diferencia `active`, `disabled` e `expired`.

### CLI e integração

- Novo menu `Connection Engine / identidades`.
- Novos comandos `manager --identities` e `manager --identity ID`.
- O módulo oferece contratos não interativos para inicialização, criação, consulta, bind, importação por nome e enable/disable, preparando a futura Automation v2.
- Instalador passou a instalar bibliotecas compartilhadas adicionais em `lib/*.sh` e inicializa o estado do Connection Engine.
- Backup principal passou a incluir `/etc/manager/connection`.

### Limites desta primeira etapa

- O `max_sessions` já faz parte da política da identidade, mas o enforcement unificado entre SSH/WireGuard/OpenVPN ainda será implementado nas próximas iterações 0.6.x.
- Desabilitar/expirar uma identidade ainda não revoga automaticamente todos os recursos de protocolo vinculados; esta versão cria o modelo comum e os vínculos sem quebrar os módulos existentes.
- A cota de revenda continua baseada nas contas SSH atuais; a migração para cotas baseadas em identidades/produtos será feita antes da Automation v2/Colmeia.

## [0.5.2] - 2026-10-10

### Hosts, proxies e túneis

- Nova lista moderna de hosts em `/etc/manager/proxy/hosts.txt`, com adicionar/remover/listar e importação controlada de `payload.txt` do SSHPlus antigo.
- Novo Squid gerenciado pelo MANAGER em configuração própria, sem sobrescrever o `squid.conf` da distribuição.
- O Squid do MANAGER não nasce como proxy aberto: por padrão aceita somente localhost e redes privadas RFC1918, com restrição adicional por hosts opcional.
- Proxy TCP gerenciado com `socat`, sempre encaminhando para serviço local em `127.0.0.1`.
- Túnel WebSocket opcional via pacote `websockify`, também restrito a backend local.
- Túnel TLS opcional via `stunnel4`, com certificado autoassinado inicial e estado preparado para futura integração com certificados confiáveis.
- Estado declarativo em `/etc/manager/proxy`, permitindo regenerar unidades systemd com `proxies.sh --reconcile`.
- Novos modos não interativos `manager --proxy-status` e `manager --proxy-hosts`.

### Contas de revenda

- Nova criação direta de usuário SSH vinculada a revendedor/subrevendedor.
- A cota é validada antes da criação e validada novamente sob lock na atribuição final.
- Se a cota mudar durante a operação ou a associação falhar, a conta recém-criada é revertida para não ficar órfã.
- Senhas continuam sem armazenamento em texto claro.

### Backup, purge e segurança

- Backup principal passou a incluir `/etc/manager/proxy`, inclusive certificados/chaves TLS gerenciados; o arquivo continua restrito a root.
- Restauração tenta reconciliar as unidades de proxy a partir do estado salvo, sem depender de copiar unidades dinâmicas antigas.
- `manager-uninstall --purge` desativa e remove as unidades próprias de Squid/TCP/WebSocket/TLS, preservando os pacotes instalados e regras UFW.
- CI ganhou regressão específica contra Squid aberto (`http_access allow all` e origem `0.0.0.0/0`) e smoke tests para hosts/estado de proxy.

## [0.5.1] - 2026-10-10

### Contas, revenda e migração

- Adicionada hierarquia local de `revendedor` e `subrevendedor`, com estado ativo/bloqueado, cota de contas e vínculo do subrevendedor ao revendedor pai.
- Contas SSH podem ser associadas a um proprietário; o uso da cota considera somente usuários Linux que ainda existem.
- Cota de revendedor inclui as contas dos subrevendedores vinculados, preparando o modelo para Automation v2 e Colmeia.
- O estado de revenda/propriedade fica protegido em `/etc/manager/access` e agora participa do backup/restore do MANAGER.
- Novo exportador de usuários SSH em `/var/backups/manager/users`, com SHA-256, permissões restritas, expiração, limite simultâneo e propriedade.
- Exportação guarda somente os hashes já existentes do sistema; senhas em texto claro não são gravadas nem publicadas por HTTP.
- A restauração recria cada usuário individualmente e nunca substitui `/etc/passwd`, `/etc/shadow`, `/etc/group` ou `/etc/gshadow` inteiros.
- Detector de estruturas SSHPlus antigas reconhece `/root/usuarios.db`, `/etc/SSHPlus/senha` e `/root/backup.vps` sem importar automaticamente formatos inseguros.

### Monitoramento SSH

- Novo monitor de sessões SSH com resumo por usuário, origem, duração, limite configurado e processos/sockets relacionados.
- Encerramento seletivo por TTY, recusando encerramento de sessão `root` pelo menu.
- Histórico de login via `last`.
- Novo modo não interativo `manager --ssh-sessions`.

### Integração e testes

- Menu principal ganhou a área `CONTAS E REVENDA` com monitor SSH, backup/migração de usuários e gestão de revendedores/cotas.
- Instalador passou a entregar os novos módulos de revenda, migração e monitoramento.
- CI passou a verificar os novos módulos, a CLI `--ssh-sessions` e a criação protegida do estado de revenda.

## [0.5.0] - 2026-10-10

### Paridade SSHPlus

- Gestão SSH ganhou contas de teste com duração em minutos, senha aleatória exibida apenas uma vez e remoção automática por timer systemd.
- O MANAGER não armazena a senha das contas teste em texto claro; registra apenas metadados de expiração.
- Listagem de contas expiradas e limpeza manual confirmada de usuários expirados.
- Novo modo CLI `manager --expired` para consultar expirados sem abrir o menu.
- Banner SSH próprio em `/etc/manager/banner/banner.txt`, habilitado por drop-in do OpenSSH e validado com `sshd -t` antes de reload.
- Speedtest/latência com instalação opcional via APT e histórico local em `/var/log/manager/speedtest.log`.
- Status de serviços evoluiu para gerenciamento central de start/stop/restart dos serviços conhecidos pelo MANAGER.
- Por segurança, o gerenciador não permite parar o OpenSSH pelo menu.

### Base para as próximas etapas

- Timer `manager-test-users.timer` remove contas de teste expiradas mesmo após reboot.
- Contas teste recebem também uma expiração de segurança no sistema, além do temporizador em minutos.
- A primeira leva de paridade mantém o comportamento útil do SSHPlus sem reproduzir armazenamento de senha em texto claro nem alterações destrutivas de sistema.

## [0.4.1] - 2026-10-10

### Corrigido

- Seleção do usuário no módulo de chaves SSH não é mais contaminada por mensagens de aviso ao administrar `root`.
- Health check interativo agora retorna ao menu normalmente mesmo quando há avisos ou checks críticos, evitando uma segunda pausa e falso erro de módulo.

### Segurança e confiabilidade

- O instalador agora aceita somente fontes `https://` em uso normal.
- `file://` permanece disponível apenas para CI ou testes locais com `MANAGER_ALLOW_FILE_SOURCE=1` explícito.
- Fontes `http://` e outros esquemas são recusadas antes de qualquer download.
- CI ganhou testes de regressão para garantir que a política de fontes do instalador continue sendo aplicada.

## [0.4.0] - 2026-10-10

### Adicionado

- Painel de saúde do servidor com checks de disco, inodes, memória, carga, systemd, SSH, rota, DNS, atualizações, UFW e Fail2ban.
- Modo não interativo `manager --health` com códigos de saída úteis para monitoramento: `0` saudável, `1` avisos e `2` crítico.
- CLI com `--version`, `--help`, `--status` e `--diagnostics`.
- Módulo de manutenção do sistema com APT, atualizações, unattended-upgrades, limpeza segura, journal, NTP e reboot explícito.
- Gerenciador de chaves públicas SSH com validação, fingerprints e correção de permissões.
- Resumo principal com consumo de RAM, disco, carga e aviso de reboot pendente.

### Segurança e confiabilidade

- Self-update deixou de executar diretamente `curl | bash`: o instalador é baixado para arquivo temporário, restrito e validado com `bash -n` antes da execução.
- Downloads do self-update exigem HTTPS/TLS moderno por padrão.
- Falha de um módulo não derruba mais o menu principal e agora preserva o código de saída para diagnóstico.
- Health check é somente leitura e pode ser integrado a cron, systemd ou monitoramento externo.

## [0.3.0] - 2026-10-10

### Adicionado

- OpenVPN moderno em `/etc/openvpn/server` com unidade `openvpn-server@manager`.
- PKI própria via Easy-RSA, certificados individuais de clientes e revogação por CRL.
- Perfis `.ovpn` completos com certificados/chaves embutidos.
- Integração opcional do OpenVPN com o DNS Ad Block.
- TLS/Let's Encrypt via Certbot em virtualenv isolado, com modos standalone e webroot.
- Timer systemd próprio para verificação de renovação de certificados.
- Whitelist e blacklist manuais no bloqueador DNS.
- Estatísticas DNS opcionais, desligadas por padrão por privacidade.
- Múltiplos listeners privados simultâneos no DNS para WireGuard e OpenVPN.
- Assistente de perfis guiados: servidor seguro, WireGuard, OpenVPN, DNS e completo.
- Diagnóstico, logs, backup e desinstalador expandidos para OpenVPN/TLS.
- Backup mais preciso: evita copiar configurações WireGuard alheias ao MANAGER.
- Roteiro de smoke test real em `docs/TESTING.md`.
- Dependabot para manter GitHub Actions atualizadas.

### Melhorado

- BBR/fq agora guarda e restaura imediatamente o congestion control e qdisc anteriores.
- Gestão de usuários SSH ganhou sessões online, bloqueio/desbloqueio e desconexão de usuário.
- OpenVPN diferencia corretamente `tcp-server` e `tcp-client` quando TCP é escolhido.
- WireGuard valida conflito de porta e insere apenas suas regras específicas no topo de `FORWARD`.
- O estado original de `net.ipv4.ip_forward` é salvo uma vez e restaurado pelo purge.
- Restauração de backup aceita somente arquivos do diretório protegido `/var/backups/manager`.
- DNS usa `bind-dynamic` e pode atender `127.0.0.1`, `10.66.66.1` e `10.8.0.1` simultaneamente sem bind público.
- Alterações dos listeners DNS possuem rollback se o dnsmasq rejeitar a nova configuração.
- Purge preserva certificados Let's Encrypt, regras UFW, backups e pacotes do sistema para reduzir risco de perda de serviço.

## [0.2.0] - 2026-10-10

### Adicionado

- Menu principal reorganizado por Servidor, Segurança e Manutenção.
- WireGuard com instalação de servidor, geração/revogação de clientes e QR Code.
- Bloqueio de anúncios por DNS com dnsmasq, listas personalizadas e atualização automática.
- Fail2ban para proteção contra brute force SSH.
- Firewall UFW com proteção para não bloquear uma porta SSH detectada.
- Hardening conservador de OpenSSH usando `sshd_config.d`.
- Atualizações automáticas de segurança com `unattended-upgrades`.
- Diagnóstico de rede, DNS, SSH, NTP, recursos e serviços.
- Monitoramento de tráfego, conexões e suporte opcional ao vnStat.
- Visualizador central de logs.
- Backup de configurações gerenciadas, SHA-256 e snapshot antes de restauração.
- Rollback de versão do código com `manager-rollback`.
- Desinstalador conservador com `manager-uninstall` e modo explícito `--purge`.
- BBR + fq com armazenamento e restauração dos valores anteriores.
- Gestão SSH ampliada: sessões online, bloqueio/desbloqueio, desconexão de usuário e limite simultâneo.
- GitHub Actions com Bash syntax, ShellCheck, validação de versão e regressões de segurança.

### Segurança

- O projeto não usa `iptables -F`, `ip6tables -F` ou `nft flush ruleset`.
- O instalador não substitui o `sshd_config` inteiro.
- Alterações SSH são validadas com `sshd -t` antes de reload.
- DNS adblock recusa listener em endereço IPv4 público.
- Configurações WireGuard e chaves são armazenadas com permissões restritas.
- O instalador valida os scripts antes de substituir a versão ativa.
- A versão anterior do código é preservada localmente para rollback.

## [0.1.0] - 2026-10-10

### Adicionado

- Base inicial do MANAGER.
- Informações do sistema.
- Gestão básica de usuários SSH.
- Primeira versão do bloqueador DNS.
- Self-update.
