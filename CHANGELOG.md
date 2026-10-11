# Changelog

Todas as mudanças relevantes do MANAGER são registradas aqui. O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

> O histórico detalhado das revisões antigas continua disponível no histórico Git. A partir da série 0.7, este arquivo prioriza as mudanças de arquitetura e segurança que afetam contratos públicos/operacionais.

## [0.7.3] - 2026-10-11

### Autenticação criptográfica e enrollment da Automation v2

- Adicionado registry de credenciais Ed25519 em `/etc/manager/automation/v2/credentials/<principal>/`.
- Cada principal não-local pode receber uma ou mais credenciais criptográficas por enrollment explícito.
- O servidor guarda somente chave pública, `key_id`, fingerprint, estado e timestamps de criação/revogação; a chave privada não é armazenada no registry do MANAGER.
- Arquivo privado de credencial é criado explicitamente em caminho fornecido pelo administrador, modo `0600`, e não entra em backup do estado do servidor.
- `local-root` continua autenticado pelo `SO_PEERCRED` do socket Unix e não aceita credencial externa.
- Todos os demais principals exigem assinatura Ed25519 válida antes de RBAC, dispatcher ou consulta ao cache idempotente.
- Envelope assinado inclui contrato, versão, `request_id`, `principal_id`, `action_id` e `params`, impedindo alteração silenciosa do payload depois da assinatura.
- `managerctl --credential FILE ...` carrega a credencial privada localmente e assina a requisição com OpenSSL.
- Enrollment, listagem, rotação e revogação ficam disponíveis em `manager automation v2 credential ...`.
- Rotação cria a nova chave antes de desativar as credenciais anteriores; a chave antiga deixa de autenticar imediatamente.
- Revogação é independente do RBAC e é reavaliada antes de qualquer replay idempotente.
- `key_id` deriva do SHA-256 da chave pública DER e cada registro também possui fingerprint SHA-256 estável.
- Daemon recalcula `key_id` e fingerprint da chave pública antes de confiar no registro, reduzindo risco de metadado adulterado.
- Audit registra esquema, `key_id`, fingerprint e decisão de autenticação, sem armazenar assinatura ou chave privada.
- Registry público sobrevive a uninstall/reinstall normal; purge remove o estado server-side. Arquivos privados externos não são apagados pelo purge.
- Novo CI `Automation v2 Authentication` cobre assinatura válida, chamada sem assinatura, chave privada incorreta, rotação, fencing da chave antiga, revogação, audit sem segredo e purge.
- CI RBAC passou a exercitar todos os principals não-locais por chamadas assinadas.

### Limite de confiança desta versão

- O transporte continua Unix/local e root-only; `remote_transport=0`.
- A 0.7.3 prova criptograficamente a identidade de principals não-locais dentro da fronteira atual, mas ainda não abre listener remoto.
- Anti-replay temporal/nonce e rate limiting continuam explicitamente desativados (`anti_replay=0`, `rate_limit=0`) e pertencem à 0.7.4.
- Nenhuma ação de shell/comando/caminho arbitrário foi adicionada.

### Próxima etapa

- 0.7.4: timestamp/nonce, janela de validade, cache anti-replay, rate limiting por principal/ação e transporte remoto autenticado/criptografado.
- Unix socket permanece a fronteira privilegiada local.
- Colmeia continua somente depois do fechamento da série 0.7.

## [0.7.2] - 2026-10-11

### Principals e RBAC da Automation v2

- Novo registry `modules/automation_principals.sh` com estado root-only em `/etc/manager/automation/v2/principals/`.
- Principal reservado `local-root` criado automaticamente para manter compatibilidade das chamadas locais existentes.
- Roles explícitas: `admin`, `reseller`, `subreseller` e `user`.
- Principals de revenda reutilizam a hierarquia existente em `/etc/manager/access/resellers`; não há segundo banco de ownership.
- Principal `user` é vinculado a uma identidade real do Connection Engine.
- Nova administração: `manager automation v2 principals` e `manager automation v2 principal show|create|enable|disable|products`.
- `managerctl` aceita `--principal ID`; sem a opção usa `local-root`.
- `principal_id` passa a fazer parte do envelope/resposta e do hash de idempotência.
- `node.usage` é admin-only.
- Revendedor acessa identidades próprias e de subrevendedores filhos diretos; subrevendedor permanece no próprio owner; usuário consulta somente a própria identidade e não pode revogar.
- `connection.preflight/create` de revenda valida escopo de produto e ownership antes do dispatcher privilegiado.
- Quando uma revenda omite `owner`, o daemon injeta o owner permitido; apontar para outra árvore é recusado.
- Autorização é reavaliada antes do cache idempotente: desabilitar um principal também corta retries já cacheados.
- Reutilizar o mesmo `request_id` com outro principal produz conflito `65`.
- Arquivos de principal precisam ser regulares, pertencentes a root e sem permissões de grupo/mundo.
- Audit JSONL registra `principal_id`, role, subject, decisão `allow/deny` e razão, sem senha/chaves privadas.
- Principals sobrevivem a uninstall/reinstall normal; purge explícito remove o estado persistente.
- Novo CI `Automation v2 RBAC` cobre isolamento entre revendas, subrevenda, usuário/admin, escopo de produto, owner forçado, replay, audit e lifecycle.
- O contrato declara `rbac=1` e `principal_assertion=root-local`; autenticação criptográfica, anti-replay remoto, rate limiting e transporte remoto continuam desabilitados nesta versão.

### Segurança e compatibilidade

- O socket continua local, root-only e `0600`; `--principal` é uma asserção confiável do root local, **não** autenticação remota.
- A allowlist não foi ampliada para shell/comando/caminho arbitrário.
- Automation v2 Core, Shell CI e Protocol Lease Security continuam verdes com o novo RBAC.

### Próxima etapa

- 0.7.3: autenticação criptográfica + enrollment/rotação/revogação de credenciais vinculadas aos principals existentes.
- Anti-replay, rate limiting e transporte remoto estruturado permanecem para 0.7.4.
- Colmeia continua somente depois do fechamento da série 0.7.

## [0.7.1] - 2026-10-11

### Automation v2 — núcleo local

- Introduzidos `managerd` e `managerctl` com socket Unix `/run/manager-automation-v2/manager.sock`.
- Runtime `0700`, socket `0600` e validação de peer com `SO_PEERCRED`; apenas UID 0 entra na fronteira local.
- Contrato `manager-automation-v2-local-v1` com envelope JSON versionado, `request_id`, `action_id` e códigos estáveis.
- Allowlist inicial: `system.describe`, `node.usage`, `connection.preflight`, `connection.create`, `connection.status` e `connection.revoke`.
- Nenhuma ação aceita shell, comando ou caminho arbitrário; subprocessos usam `shell=False`.
- Idempotência persistente com conflito para reutilização de `request_id` com payload diferente.
- Respostas persistidas são sanitizadas; senha SSH/chaves/segredos continuam one-shot e não podem ser recuperados pelo replay.
- Audit estruturado em `/var/log/manager/automation-v2-audit.jsonl` sem conteúdo sensível.
- Installer só considera o daemon pronto depois que o socket realmente existe em `0600`.
- Update/rollback/uninstall conhecem daemon/socket/aliases; uninstall normal preserva estado durável para reinstall.
- Corrigida corrida de teardown do Protocol Lease Bridge que podia recriar runtime depois do uninstall.
- CI próprio cobre contrato, allowlist, create/replay/conflito, segredo fora do cache/audit, revoke e reinstall.

## [0.7.0] - 2026-10-11

### Automation Legacy v1

- Compatibilidade controlada com o ecossistema antigo `syncpainel`, desligada por padrão.
- CLI `manager automation legacy status|enable [PORT]|disable|restart|rotate-password`.
- Transporte por instância OpenSSH dedicada e conta não-root `manager-legacy`.
- `PermitRootLogin no`, sem TTY/forwarding/túnel, `ForceCommand` fixo e sudoers exato validado por `visudo`.
- Guard no SSH principal impede que a credencial Legacy vire shell comum.
- Senha de integração one-shot; MANAGER não armazena a senha em texto claro.
- Comandos históricos allowlisted: `criarusuario.sh`, `remover.sh`, `AlterarSenha.sh`, `AlterarData.sh`, `alterarlimite.sh`, `KillUser.sh` e `sshmonitor.sh`.
- Alterações/remoções limitadas a contas MANAGER; `root`, `manager-legacy` e usuários locais alheios são protegidos.
- Sem `eval`, `/root/usuarios.db`, `/etc/SSHPlus/senha`, `chmod 777` ou flush destrutivo de firewall.
- Lifecycle completo em backup/update/rollback/uninstall/reinstall/purge e CI dedicado.

## Série [0.6.x] - 2026-10-10 / 2026-10-11

### Connection, Policy e Session Engine

- **0.6.0:** identidade lógica independente do usuário Linux, bindings SSH/WireGuard/OpenVPN, owner, expiração e `max_sessions`.
- **0.6.1:** enforcement real nos protocolos e visão consolidada de sessões observadas.
- **0.6.2:** Session/Lease Engine com `session_id`, TTL, heartbeat, release, `session_epoch`, fencing, switch e limite local atômico.
- **0.6.3:** Protocol Lease Bridge ligando SSH PAM, OpenVPN e WireGuard às leases reais.
- **0.6.4:** accounting/atividade comum por identidade, sem inventar bytes SSH não observáveis.
- **0.6.5:** produtos/planos, ACL, franquias e política de quota.
- **0.6.6:** provisionamento unificado transacional e revogação centralizada.
- **0.6.7:** cotas de revenda por identidade/produto, incluindo VPN-only e hierarquia pai/subrevendedor.
- **0.6.8:** dual-stack IPv6 e IPv6 Guard sem flush global de firewall.
- **0.6.9:** `node_id` persistente e metadados de país/região/pool/capacidade/peso.
- **0.6.10:** Product Policy/Session Engine usam automaticamente contexto local de região/pool/nó.
- **0.6.11:** contratos `manager-connection-actions-v1` e `manager-node-usage-v1`, encerrando a série com superfícies estruturadas para Automation.

## Série [0.5.x]

- Paridade operacional principal do SSHPlus útil: contas teste, expirados, banner, speedtest, sessões SSH, backup/migração segura, revendedores/subrevendedores, cotas, hosts/proxies, Squid privado e túneis opcionais.

## Série [0.4.x]

- Fundação de confiabilidade: health check, manutenção, CLI, update/rollback, CI de Bash/ShellCheck e política segura de download/instalação.
