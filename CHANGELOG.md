# Changelog

Todas as mudanças relevantes do MANAGER são registradas aqui. O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

> O histórico detalhado das revisões antigas continua disponível no histórico Git. A partir da série 0.7, este arquivo prioriza mudanças de arquitetura e segurança que afetam contratos públicos/operacionais.

## [0.7.4] - 2026-10-11

### Anti-replay e freshness da Automation v2

- O esquema de autenticação não-local evoluiu para `ed25519-v2`.
- `issued_at` e `nonce` agora fazem parte do payload canônico assinado.
- Janela de freshness fixada em 120 segundos; timestamp antigo ou excessivamente futuro é recusado.
- Nonce possui formato restrito e é consumido uma única vez.
- Cache anti-replay persistente em `/var/lib/manager/automation-v2/replay/<principal>/<key_id>/`.
- O nome persistido deriva do SHA-256 do nonce, evitando armazenar o nonce original como nome de arquivo.
- Registro de nonce usa criação exclusiva para fechar corrida entre duas cópias do mesmo envelope.
- Retenção de replay é maior que a janela de freshness, evitando reutilização do mesmo envelope dentro do período útil.
- Retry idempotente continua funcionando quando usa o mesmo `request_id` lógico, mas gera novo `issued_at`, novo nonce e nova assinatura.
- Principal/chave continuam sendo revalidados antes de qualquer replay idempotente.

### Rate limiting

- Token bucket por `(principal_id, action_id)` para principals não-locais.
- Ações de leitura (`system.describe`, `node.usage`, `connection.status`): 120 req/min, burst 20.
- Ações de escrita (`connection.preflight`, `connection.create`, `connection.revoke`): 30 req/min, burst 8.
- Excesso de chamadas retorna código temporário `75` e pode informar `retry_after_seconds`.
- `local-root`, autenticado pelo socket Unix, não passa pelo bucket de principal não-local.
- Gateway remoto possui proteção adicional por IP de origem, com burst 30 e refill de 2 conexões/s.

### Transporte remoto TLS 1.3

- Novo serviço `manager-automation-v2-remote.service`.
- Transporte remoto é opcional e separado do daemon local.
- Gateway termina TLS e encaminha o envelope estruturado ao socket Unix; autenticação, anti-replay, RBAC, idempotência e dispatcher continuam no `managerd` local.
- `remote_transport=1` passa a indicar capacidade disponível; `remote_enabled` indica se o listener está realmente ativo.
- Habilitação explícita: `manager automation v2 remote enable BIND_IP [PORT]`.
- Desabilitação explícita: `manager automation v2 remote disable`.
- Status: `manager automation v2 remote status`.
- Rotação: `manager automation v2 remote rotate-certificate`.
- `BIND_IP` precisa ser endereço IPv4/IPv6 literal e a porta precisa ficar entre 1024 e 65535.
- Certificado/chave de servidor Ed25519 armazenados root-only sob `/etc/manager/automation/v2/tls/`.
- Servidor e cliente aceitam somente TLS 1.3; TLS 1.2 é recusado.
- Cliente remoto exige pin SHA-256 explícito do certificado DER através de `--server-fingerprint`.
- Fingerprint incorreto falha fechado antes de enviar a operação ao daemon.
- `local-root` é proibido no transporte remoto.
- Transporte remoto exige credencial Ed25519 de principal não-local.
- O MANAGER não abre porta no firewall automaticamente ao habilitar o gateway.

### managerctl remoto

Exemplo:

```bash
managerctl \
  --credential /root/loja01.credential \
  --remote 203.0.113.10:9443 \
  --server-fingerprint SHA256:<64-hex> \
  connection.status id=maria
```

IPv6 usa endpoint no formato `[IP]:PORT`.

### Auditoria

- Audit registra `transport`.
- Audit registra decisão de freshness.
- Audit registra decisão anti-replay.
- Audit registra decisão de rate limit.
- `request_issued_at` pode ser registrado para diagnóstico.
- Assinatura, chave privada, senha e stdout sensível continuam fora do audit.

### Lifecycle

- Installer/update/rollback/uninstall reconhecem o serviço remoto.
- Uninstall normal fecha gateway/socket e preserva configuração/estado durável.
- Reinstall reaplica a configuração preservada e religa o gateway se `remote_enabled=1`.
- Purge remove estado server-side da Automation v2.
- Arquivos privados de credencial criados fora de `/etc/manager` continuam fora do purge automático.

### Robustez do Protocol Lease Bridge

- Corrigida janela de observação entre admissão da lease e aparição da sessão no protocolo.
- Maps SSH/OpenVPN recém-admitidas passam a registrar `created_epoch`.
- Reconciliador respeita uma janela curta de adoção de 10 segundos antes de remover uma lease ainda não observada.
- Isso impede abrir temporariamente uma vaga falsa para uma segunda sessão quando `max_sessions=1`.
- Se a sessão nunca aparecer, a lease continua sendo liberada normalmente depois da janela de adoção.

### CI

- Novo workflow `Automation v2 Secure Transport`.
- Testes cobrem timestamp antigo e futuro.
- Testes cobrem replay do mesmo envelope assinado.
- Testes confirmam retry idempotente com nonce novo.
- Testes exercitam rate limiting/burst.
- Testes exigem pin SHA-256 correto.
- Testes tentam pin incorreto.
- Testes confirmam TLS 1.3 e rejeição de TLS 1.2.
- Testes cobrem rotação do certificado.
- Testes cobrem uninstall/reinstall/purge do transporte remoto.
- `Automation v2 Authentication`, `Automation v2 RBAC`, `Automation v2 Core`, `Protocol Lease Security` e `Shell CI` permanecem verdes após o fechamento funcional.

### Próxima etapa

- A série 0.7 está concluída.
- 0.8.x inicia o Modo Colmeia.
- Primeiro milestone recomendado: identidade/enrollment criptográfico de nós + heartbeat/saúde, sem ainda mover a autoridade de leases globais.

## [0.7.3] - 2026-10-11

### Autenticação criptográfica e enrollment da Automation v2

- Adicionado registry de credenciais Ed25519 em `/etc/manager/automation/v2/credentials/<principal>/`.
- Cada principal não-local pode receber uma ou mais credenciais criptográficas por enrollment explícito.
- O servidor guarda somente chave pública, `key_id`, fingerprint, estado e timestamps de criação/revogação; a chave privada não é armazenada no registry do MANAGER.
- Arquivo privado de credencial é criado explicitamente em caminho fornecido pelo administrador, modo `0600`, e não entra em backup do estado do servidor.
- `local-root` continua autenticado pelo `SO_PEERCRED` do socket Unix e não aceita credencial externa.
- Todos os demais principals exigem assinatura Ed25519 válida antes de RBAC, dispatcher ou consulta ao cache idempotente.
- Envelope assinado inclui contrato, versão, `request_id`, `principal_id`, `action_id` e `params`.
- `managerctl --credential FILE ...` carrega a credencial privada localmente e assina a requisição com OpenSSL.
- Enrollment, listagem, rotação e revogação ficam disponíveis em `manager automation v2 credential ...`.
- Rotação cria a nova chave antes de desativar as credenciais anteriores.
- Revogação é independente do RBAC e é reavaliada antes de qualquer replay idempotente.
- `key_id` deriva do SHA-256 da chave pública DER e cada registro possui fingerprint SHA-256 estável.
- Audit registra esquema, `key_id`, fingerprint e decisão de autenticação, sem armazenar assinatura ou chave privada.
- Registry público sobrevive a uninstall/reinstall normal; purge remove estado server-side.

## [0.7.2] - 2026-10-11

### Principals e RBAC da Automation v2

- Registry root-only em `/etc/manager/automation/v2/principals/`.
- Principal reservado `local-root`.
- Roles explícitas: `admin`, `reseller`, `subreseller` e `user`.
- Principals de revenda reutilizam a hierarquia existente em `/etc/manager/access/resellers`.
- Principal `user` é vinculado a uma identidade real do Connection Engine.
- `principal_id` faz parte do envelope/resposta e do hash de idempotência.
- `node.usage` é admin-only.
- Revendedor acessa identidades próprias e de subrevendedores filhos diretos.
- Subrevendedor permanece no próprio owner.
- Usuário consulta somente a própria identidade e não pode revogar.
- Criação por revenda valida produto e ownership antes do dispatcher privilegiado.
- Autorização é reavaliada antes do cache idempotente.
- Audit JSONL registra principal, role, subject e decisão RBAC.

## [0.7.1] - 2026-10-11

### Automation v2 — núcleo local

- Introduzidos `managerd` e `managerctl` com socket Unix `/run/manager-automation-v2/manager.sock`.
- Runtime `0700`, socket `0600` e validação de peer com `SO_PEERCRED`.
- Contrato estruturado com envelope JSON versionado, `request_id`, `action_id` e códigos estáveis.
- Allowlist inicial: `system.describe`, `node.usage`, `connection.preflight`, `connection.create`, `connection.status` e `connection.revoke`.
- Nenhuma ação aceita shell, comando ou caminho arbitrário.
- Idempotência persistente com conflito para reutilização de `request_id` com payload diferente.
- Respostas persistidas são sanitizadas; senha SSH/chaves/segredos continuam one-shot.
- Audit estruturado sem conteúdo sensível.
- Lifecycle install/update/rollback/uninstall/reinstall.

## [0.7.0] - 2026-10-11

### Automation Legacy v1

- Compatibilidade controlada com o ecossistema antigo `syncpainel`, desligada por padrão.
- CLI `manager automation legacy status|enable [PORT]|disable|restart|rotate-password`.
- Transporte por instância OpenSSH dedicada e conta não-root `manager-legacy`.
- `PermitRootLogin no`, sem TTY/forwarding/túnel, `ForceCommand` fixo e sudoers exato.
- Senha de integração one-shot; MANAGER não armazena a senha em texto claro.
- Comandos históricos allowlisted.
- Sem `eval`, `/root/usuarios.db`, `/etc/SSHPlus/senha`, `chmod 777` ou flush destrutivo de firewall.

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
- **0.6.11:** contratos estruturados `manager-connection-actions-v1` e `manager-node-usage-v1`.

## Série [0.5.x]

- Paridade operacional principal do SSHPlus útil: contas teste, expirados, banner, speedtest, sessões SSH, backup/migração segura, revendedores/subrevendedores, cotas, hosts/proxies, Squid privado e túneis opcionais.

## Série [0.4.x]

- Fundação de confiabilidade: health check, manutenção, CLI, update/rollback, CI de Bash/ShellCheck e política segura de download/instalação.
