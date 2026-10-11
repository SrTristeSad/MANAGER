# Changelog

Todas as mudanças relevantes do MANAGER são registradas aqui. O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

> O histórico detalhado das revisões antigas continua disponível no histórico Git. A partir da série 0.7, este arquivo prioriza mudanças de arquitetura e segurança que afetam contratos públicos/operacionais.

## [0.8.0] - 2026-10-11

### Colmeia — identidade criptográfica e enrollment de nós

- Adicionado `modules/hive_identity.sh` como raiz de confiança da futura Colmeia.
- Cada VPS recebe identidade Ed25519 própria ligada ao `node_id` persistente do Node Metadata.
- Chave privada do nó permanece root-only em `/etc/manager/hive/node/node.key`; enrollment request leva somente a chave pública.
- Controlador pode inicializar identidade Ed25519 própria em `/etc/manager/hive/controller/`.
- Novos contratos `manager-hive-node-identity-v1`, `manager-hive-controller-identity-v1`, `manager-hive-enrollment-request-v1` e `manager-hive-enrollment-bundle-v1`.
- Enrollment request contém `node_id`, key ID, fingerprint, chave pública, snapshot de metadados, `issued_at`, nonce e assinatura Ed25519 do nó.
- Controlador valida assinatura e identidade derivada da chave pública antes de aprovar.
- Aprovação gera bundle assinado pelo controlador e registra a chave pública do nó.
- Nó aceita bundle somente quando `node_id`, geração de chave, fingerprint do próprio nó, assinatura do controlador e fingerprint pinado do controlador conferem.
- Nó não pode trocar silenciosamente de controlador depois do primeiro enrollment.
- Primeiro enrollment começa em `node_epoch=1`.
- Revogação desabilita o nó, registra motivo/timestamp e incrementa `node_epoch`.
- Nó revogado não volta por `approve` normal; retorno exige `controller reenroll` explícito.
- Re-enrollment incrementa novamente `node_epoch` e gera novo bundle.
- Bundle com epoch menor que o já aceito é recusado, preparando fencing para futuras fases distribuídas.

### CLI e lifecycle

- Novos comandos `manager hive status|request|accept`.
- Novos comandos `manager hive controller init|status|fingerprint|list|show|approve|reenroll|revoke`.
- Nova opção 39 no menu interativo para identidade/enrollment da Colmeia.
- Installer inicializa identidade criptográfica do nó depois do Node Metadata.
- `/etc/manager/hive` é estado durável e sobrevive a uninstall/reinstall normal.
- `manager-uninstall --purge` remove o estado server-side da Colmeia junto do restante de `/etc/manager`.
- Backup protegido inclui `/etc/manager/hive`; o aviso de backup agora explicita que o arquivo pode conter chaves privadas da Colmeia.

### Segurança e limites

- Ed25519/OpenSSL; nenhuma criptografia própria foi inventada.
- Arquivos de request/bundle são criados em `0600`, exigem caminho absoluto e não sobrescrevem arquivos existentes.
- Enrollment request possui validade máxima de 24 horas e nonce.
- Alteração de metadata ou qualquer campo coberto pela assinatura invalida o request.
- Pin SHA-256 do controlador é obrigatório no aceite inicial do bundle.
- 0.8.0 não abre novo listener de rede e não altera o caminho de dados VPN.
- Heartbeat, saúde distribuída, scheduler, drain/failover, lease global e accounting global continuam explicitamente fora deste milestone.

### CI

- Novo workflow `Hive Node Enrollment`.
- O CI simula controlador + segundo nó isolado na mesma VM.
- Testa request assinado, tamper detection, pin errado, aprovação correta, revogação, reenrollment e fencing de bundle antigo.
- Testa preservação das chaves em uninstall/reinstall normal.
- Testa purge do estado da Colmeia.
- Os 16 workflows do commit funcional fecharam sem falhas antes do bump de release.

### Próxima etapa

- 0.8.1: heartbeat assinado + saúde dos nós.
- Scheduler, drain/failover e seleção de nó ficam para 0.8.2.
- Autoridade global de sessões/leases fica para 0.8.3.

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

### Robustez do Protocol Lease Bridge

- Corrigida janela de observação entre admissão da lease e aparição da sessão no protocolo.
- Maps SSH/OpenVPN recém-admitidas registram `created_epoch`.
- Reconciliador respeita janela curta de adoção antes de remover lease ainda não observada.

### CI

- Workflow `Automation v2 Secure Transport` cobre timestamp, replay, retry idempotente, rate limit, TLS 1.3, pinning e lifecycle.
- A série 0.7 foi encerrada com todos os gates principais verdes.

## [0.7.3] - 2026-10-11

### Autenticação criptográfica e enrollment da Automation v2

- Registry de credenciais Ed25519 em `/etc/manager/automation/v2/credentials/<principal>/`.
- Servidor guarda somente chave pública, `key_id`, fingerprint, estado e timestamps; chave privada fica fora do registry.
- `local-root` continua autenticado pelo `SO_PEERCRED`.
- Principals não-locais exigem assinatura Ed25519 válida.
- Enrollment, rotação e revogação disponíveis no CLI.
- Revogação é reavaliada antes de qualquer replay idempotente.

## [0.7.2] - 2026-10-11

### Principals e RBAC da Automation v2

- Registry root-only em `/etc/manager/automation/v2/principals/`.
- Roles `admin`, `reseller`, `subreseller` e `user`.
- Escopo por owner/identidade/produto.
- Autorização antes do cache idempotente.
- Audit JSONL de principal/RBAC sem segredos.

## [0.7.1] - 2026-10-11

### Automation v2 — núcleo local

- `managerd` e `managerctl` via socket Unix root-only.
- Envelope versionado, allowlist, idempotência persistente e audit estruturado.
- Nenhuma ação aceita shell/comando/caminho arbitrário.
- Segredos permanecem one-shot e não entram no cache persistente.

## [0.7.0] - 2026-10-11

### Automation Legacy v1

- Compatibilidade controlada com `syncpainel`, desligada por padrão.
- OpenSSH dedicado, conta não-root, `ForceCommand`, sudoers exato e allowlist.
- Sem senha em texto claro, `chmod 777`, `eval` ou flush destrutivo de firewall.

## Série [0.6.x] - 2026-10-10 / 2026-10-11

- **0.6.0:** identidade comum.
- **0.6.1:** enforcement.
- **0.6.2:** Session/Lease Engine.
- **0.6.3:** Protocol Lease Bridge.
- **0.6.4:** Identity Usage.
- **0.6.5:** produtos/ACL/franquias.
- **0.6.6:** provisionamento transacional.
- **0.6.7:** cotas por identidade/produto.
- **0.6.8:** IPv6 dual-stack.
- **0.6.9:** node metadata.
- **0.6.10:** ACL automática pelo nó.
- **0.6.11:** contratos estruturados de conexão e uso local.

## Série [0.5.x]

- Paridade operacional útil do SSHPlus: contas, sessões, backup/migração, revenda, hosts/proxies, Squid privado e túneis opcionais.

## Série [0.4.x]

- Fundação de confiabilidade: health check, manutenção, CLI, update/rollback, CI e política segura de download/instalação.
