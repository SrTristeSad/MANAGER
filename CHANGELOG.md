# Changelog

Todas as mudanças relevantes do MANAGER serão registradas aqui.

O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

## [0.6.7] - 2026-10-10

### Cotas por identidade

- A unidade principal de cota de revenda deixa de depender de usuário Linux e passa a ser a identidade lógica MANAGER.
- Identidades somente WireGuard ou somente OpenVPN agora podem pertencer a revendedor/subrevendedor sem criar uma conta SSH artificial.
- Uma identidade ocupa uma única vaga independentemente de usar SSH, WireGuard, OpenVPN ou uma combinação dos três.
- Novos slots persistentes em `/etc/manager/access/identity-slots` representam a ocupação de cota de cada cliente lógico.
- A reserva do slot acontece sob lock antes da gravação da identidade, impedindo duas criações concorrentes de ultrapassarem a mesma cota.
- O uso de subrevendedores continua agregado ao limite do revendedor pai.
- `manager --reseller-usage OWNER` mostra identidades diretas, contas SSH legadas ainda não absorvidas, uso total, cota e saldo.

### Compatibilidade e lifecycle

- Contas SSH antigas em `/etc/manager/access/owners` continuam contando enquanto não forem adotadas por uma identidade.
- Ao adotar uma conta SSH legada por uma identidade MANAGER correspondente, a contagem é deduplicada para manter um cliente = uma vaga.
- Desabilitar temporariamente uma identidade não libera sua vaga de revenda.
- Revogação completa pelo provisionador libera o slot somente depois que os acessos técnicos foram removidos/revogados com sucesso.
- Identidade com slot liberado precisa reservar capacidade novamente antes de ser reativada; reativação é recusada quando a cota está cheia.
- Uma identidade ainda ativa não pode liberar o próprio slot diretamente.
- Identidades históricas revogadas pela 0.6.6 (`disabled`, sem bindings e sem produto) são migradas com slot inativo, evitando que um upgrade faça clientes já revogados voltarem a consumir cota.

### Cotas por produto

- Novo `modules/reseller_product_quotas.sh` adiciona cota opcional por produto/plano para revendedor e subrevendedor.
- `0` significa ilimitado; cotas finitas não podem ser reduzidas abaixo do uso atual.
- Um subrevendedor pode possuir limite próprio por produto, mas continua sujeito ao limite agregado do revendedor pai.
- `products.sh --assign` valida a cota do produto antes de alterar a atribuição, evitando contorno do limite por uma chamada administrativa direta.
- O provisionamento unificado valida cota total e cota de produto no preflight, antes de criar identidade, usuário ou credencial VPN.
- `manager --reseller-product-quota OWNER PRODUCT` expõe uso, cota e saldo do produto.
- Menu principal ganhou `Cotas de produto por revendedor`.

### Provisionamento, persistência e testes

- `manager --provision ID PLAN OWNER PROTOCOLS` deixa de exigir `ssh` para clientes de revenda; VPN-only passa a usar a mesma reserva de identidade.
- Rollback de provisionamento remove a identidade antes de liberar o slot, preservando a proteção que impede liberar cota de uma identidade ainda ativa.
- O instalador passa a entregar e inicializar a nova camada de cotas sem criar banco paralelo.
- Slots e cotas de produto permanecem sob `/etc/manager/access`, entrando no backup, uninstall preservando estado e purge já existentes.
- Novo CI `Reseller Identity and Product Quotas` cobre clientes WG/OVPN sem SSH, hierarquia pai/subrevendedor, reativação sob cota cheia, limite por produto, adoção de SSH legado sem dupla contagem, migração de identidade revogada, preflight e persistência em uninstall/reinstall.
- Nova documentação `docs/RESELLER_QUOTAS.md`; `docs/PROVISIONING.md`, README e roadmap foram atualizados para o novo modelo.

### Limites desta etapa

- Cotas ainda são autoritativas por VPS. A futura Colmeia moverá a reserva para uma autoridade global para impedir excesso distribuído entre vários nós.
- Accounting de tráfego continua separado da cota de clientes/produtos e ainda não representa faturamento global.
- Os próximos itens 0.6.x são IPv6 completo, metadados de nó/região, passagem automática de contexto ACL e consolidação dos contratos internos que serão usados pela Automation v2.

## [0.6.6] - 2026-10-10

### Provisionamento unificado

- Novo `modules/provision.sh` cria identidade MANAGER, aplica produto/plano, materializa recursos técnicos e cria bindings numa única operação controlada.
- Novo comando `manager --provision ID PLANO [OWNER] [PROTOCOLS]` e nova opção de menu para provisionamento/revogação.
- Preflight valida ID, produto ativo, protocolos, conflitos de nomes, disponibilidade dos servidores WireGuard/OpenVPN e, quando aplicável, estado/cota do revendedor antes de alterar o sistema.
- Protocolos explicitamente solicitados precisam ser subconjunto do produto; quando omitidos, o provisionador usa os protocolos permitidos pelo plano.
- Resultado da criação é estruturado em `chave=valor`, preparando a superfície allowlisted que será reutilizada pela Automation v2.

### SSH, WireGuard e OpenVPN

- Usuário SSH nasce com senha aleatória de 128 bits representada em 32 caracteres hexadecimais e permanece bloqueado enquanto a transação está incompleta.
- A senha SSH só é desbloqueada depois da reconciliação bem-sucedida e é exibida uma única vez na saída; não é gravada no log de eventos.
- Validade efetiva do produto é aplicada ao usuário Linux quando configurada.
- WireGuard cria somente o peer/perfil do cliente solicitado, com chave privada/PSK protegidos e sem flush global de firewall ou substituição completa da configuração.
- OpenVPN reutiliza a PKI Easy-RSA existente; se a operação precisar ser desfeita depois da emissão, o certificado é revogado e a CRL é regenerada.
- O provisionador não cria um segundo sistema de limites: produto, Policy Engine e Session/Lease Engine continuam sendo as autoridades de validade, protocolo, franquia e simultaneidade.

### Transação, rollback e revogação

- Falha intermediária desfaz em ordem inversa os recursos criados naquela tentativa, incluindo usuário SSH, peer WireGuard, perfil/certificado OpenVPN, atribuição de produto e identidade recém-criada.
- Mudanças intermediárias da identidade podem adiar a sinalização do watcher de política durante a operação CLI, evitando que systemd aplique uma identidade parcialmente construída; o estado final é sinalizado após commit ou rollback.
- Novo `manager --revoke-identity ID` desativa primeiro a identidade, revoga leases, remove/revoga os recursos técnicos e limpa bindings/produto.
- A revogação preserva a identidade lógica em estado `disabled` para histórico e auditoria, em vez de apagar silenciosamente o objeto de conta.
- Se uma etapa da revogação falhar, a identidade permanece desativada e a operação retorna erro parcial, evitando reabilitar acesso incompleto.
- Eventos ficam em `/var/log/manager/provision-events.log` com metadados operacionais e resultado, sem senha, chave privada WireGuard ou chave privada OpenVPN.

### Revenda, lifecycle e testes

- Enquanto a cota antiga de revenda ainda contabilizar usuários Linux, provisionamentos com `OWNER` exigem `ssh`; isso impede identidades VPN-only de escaparem da cota legada.
- O instalador passa a entregar `modules/provision.sh` e anuncia o comando de provisionamento no resumo final.
- Uninstall normal continua preservando o estado lógico do Connection Engine; um acesso explicitamente revogado não é recriado por reinstalação.
- Novo CI `Unified Provisioning` cobre preflight, criação SSH por produto, validade, `max_sessions`, duplicata, falha limpa quando WireGuard não está configurado, revogação, ausência de segredo no audit log e persistência da identidade lógica após uninstall/reinstall.
- Nova documentação `docs/PROVISIONING.md` descreve o contrato, a transação, rollback, segurança e limites atuais.

### Limites desta etapa

- Cota de revenda por produto/identidade ainda não substituiu a cota baseada em usuário Linux; esse é o próximo passo para permitir revenda VPN-only corretamente.
- O código de materialização de WireGuard/OpenVPN ainda será consolidado gradualmente em contratos internos únicos de protocolo para que Automation v2 não duplique caminhos de criação/revogação.
- A autoridade de sessão, produto e accounting continua local à VPS até a futura Colmeia.

## [0.6.5] - 2026-10-10

### Produtos, planos e política efetiva

- Novo `products.sh` cria um catálogo de produtos/planos separado das credenciais técnicas de SSH, WireGuard e OpenVPN.
- Produtos podem restringir protocolos, duração, expiração e `max_sessions` de uma identidade MANAGER.
- Antes da atribuição, o MANAGER preserva `base_max_sessions`, `base_protocols` e `base_expires_epoch`; ao desvincular o produto, esses valores são restaurados.
- Protocolos do produto funcionam como interseção com a política base e nunca amplia silenciosamente os privilégios da identidade.
- Atualização de produto reaplica a política às identidades vinculadas e recusa uma alteração que deixaria uma delas sem protocolo compatível.
- Produto desabilitado adiciona o estado efetivo `product-disabled`, reaproveitando o mesmo caminho de enforcement do Policy/Session Engine.

### ACL e Colmeia

- Produtos ganharam ACL de `region`, `pool` e `node`, além da restrição de protocolo.
- Novo contrato `products.sh --authorize ID PROTOCOL REGION POOL NODE` valida estado, protocolo e as três dimensões de destino.
- A restrição de protocolo já é aplicada automaticamente na identidade local.
- ACL de região/pool/nó fica preparada para receber o contexto automático de endpoint quando os metadados de nó/região forem adicionados antes da Colmeia.

### Franquias de tráfego

- Produtos podem definir `traffic_quota_bytes`, ciclo `monthly` ou `lifetime` e ação `warn` ou `block`.
- A atribuição usa o acumulado atual como baseline, evitando cobrar tráfego anterior ao plano.
- Reset administrativo da franquia avança somente o baseline; o histórico consolidado do Identity Usage não é apagado.
- Em `warn`, o excesso permanece visível sem bloquear a identidade.
- Em `block`, uma identidade com accounting completo passa para `quota-exceeded`, que é consumido pelo Policy e Session Engine.
- Franquia mensal muda de ciclo em UTC e o reconciliador estabelece um novo baseline na primeira execução do novo mês.
- Identidades com SSH vinculado podem mostrar excesso, mas recebem `quota_enforceable=0` enquanto bytes SSH não forem medidos de forma confiável, evitando bloqueio por accounting parcial.

### CLI, persistência e lifecycle

- Novos comandos `manager --products`, `manager --product ID` e `manager --product-assignment ID`.
- Novo menu `Produtos, planos, ACL e franquias`.
- Catálogo e vínculos ficam em `/etc/manager/connection/products`; baselines/estado de franquia ficam em `/etc/manager/connection/product-usage`.
- Esse estado usa o backup já existente do Connection Engine e é preservado no uninstall normal.
- Novo `manager-product-policy.timer` reconcilia produtos e franquias periodicamente.
- Rollback desanexa o reconciliador antes da troca de código e só o reinstala quando a versão restaurada possui o módulo.
- `--purge` remove explicitamente produtos, ACL e estado de franquia junto com `/etc/manager`.

### Testes e documentação

- Nova documentação `docs/PRODUCTS.md` detalha política base/efetiva, ACL, franquia, `warn/block`, segurança do accounting SSH e lifecycle.
- CI dedicado cobre atribuição, ACL, limite `max_sessions`, franquia medida, `quota-exceeded`, `warn`, produto desabilitado, SSH parcial, restauração da política base, uninstall/reinstall e purge.
- Shell CI, Identity Usage e Protocol Lease Security continuam executando em paralelo para detectar regressões cruzadas.

### Limites desta etapa

- A franquia e a autoridade continuam locais a uma VPS; não são faturamento nem cota global da Colmeia.
- Cotas de revendedor ainda usam o modelo anterior e serão migradas para produto/identidade em etapa própria.
- ACL de região/pool/nó possui contrato pronto, mas ainda depende da futura passagem automática de metadados do nó para cada autorização.
- Byte accounting de SSH continua fora do enforcement de franquia até existir uma medição confiável por sessão.

## [0.6.4] - 2026-10-10

### Identity Usage Accounting

- Novo `identity_usage.sh` consolida tráfego e atividade em torno da identidade MANAGER, em vez de manter métricas isoladas por protocolo.
- WireGuard passa a alimentar o accounting usando os contadores reais de transferência de cada peer vinculado.
- OpenVPN passa a alimentar o accounting usando `Bytes Received` e `Bytes Sent` do status do servidor, com suporte aos formatos moderno e legado do arquivo de status.
- Bytes recebidos pelo servidor são tratados como upload da identidade; bytes enviados pelo servidor são tratados como download.
- A primeira observação de cada fonte vira baseline e não é somada retroativamente, evitando transformar tráfego anterior à ativação do coletor em consumo novo.
- Quando um daemon/interface reinicia e o contador absoluto diminui, o valor atual passa a ser tratado como delta após o reset, preservando o acumulado histórico.
- Totais gerais e por protocolo são persistidos em `/var/lib/manager/identity-usage/identities` com arquivos `0600`.
- Snapshots usados apenas para calcular deltas ficam separados em `/var/lib/manager/identity-usage/sources`.

### Sessões, atividade e cobertura

- Heartbeats de leases reais alimentam `last_activity`, `last_protocol` e `last_resource` da identidade.
- SSH participa da visão de sessão e última atividade, mas a 0.6.4 não contabiliza bytes SSH usando tráfego genérico do UID Linux, pois isso poderia misturar processos fora da sessão.
- Novo indicador `traffic_complete` diferencia identidades cujo tráfego vinculado é completamente mensurável das que possuem SSH e, portanto, têm accounting de bytes parcial.
- A saída expõe explicitamente `metered_protocols=wireguard,openvpn` e `ssh_bytes_supported=0` para impedir interpretação falsa dos totais.

### CLI, lifecycle e backup

- Novo comando `manager --usage [ID]` para listar ou detalhar uso, sessões e última atividade por identidade.
- Novo menu `Uso e atividade por identidade`, também acessível pelo módulo `Tráfego e conexões`.
- Novas unidades `manager-identity-usage.service` e `.timer` fazem coleta periódica a cada 30 segundos.
- Uninstall normal remove somente as unidades do coletor e preserva o histórico consolidado; `--purge` remove também `/var/lib/manager/identity-usage`.
- Rollback desanexa o coletor antes da troca de código e o reinstala somente se a versão restaurada possuir o módulo.
- Backup principal transporta apenas os acumulados consolidados; snapshots/baselines do nó de origem ficam fora do arquivo para não contaminar uma restauração em outra VPS.
- Após restore, o coletor cria baselines locais novos para as fontes disponíveis.

### Testes e documentação

- Nova documentação `docs/IDENTITY_USAGE.md` descreve semântica de upload/download, baseline, reset de contador, persistência, cobertura parcial de SSH e limites da etapa.
- CI dedicado valida baseline inicial, deltas, reset de contador, rejeição de recurso não vinculado, persistência através de uninstall/reinstall e remoção no purge.
- O parser de atividade de leases passou a identificar campos por nome, reduzindo acoplamento à ordem textual da saída do Session Engine.

### Limite desta etapa

- O accounting da 0.6.4 é local à VPS e ainda não é um sistema global de cobrança/franquia.
- Períodos de faturamento, limites de bytes, ações ao atingir cota, histórico diário/mensal e agregação multi-nó ficam para as próximas etapas sobre produto/plano e Colmeia.

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
