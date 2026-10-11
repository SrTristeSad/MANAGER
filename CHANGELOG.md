# Changelog

Todas as mudanças relevantes do MANAGER são registradas aqui. O projeto usa versionamento semântico (`MAJOR.MINOR.PATCH`) enquanto a API/estrutura ainda está evoluindo.

> O histórico detalhado das revisões antigas continua disponível no histórico Git. A partir da série 0.7, este arquivo prioriza mudanças de arquitetura e segurança que afetam contratos públicos/operacionais.

## [0.8.2] - 2026-10-11

### Colmeia — heartbeat assinado e saúde dos nós

- Adicionado `modules/hive_health.sh` como plano de telemetria/saúde da Colmeia.
- Cada heartbeat usa a identidade Ed25519 já enrolled do nó; não cria uma segunda identidade de autoridade.
- Payload assinado inclui `controller_id`, `node_id`, `node_epoch`, `issued_at`, nonce e todas as métricas.
- Controlador valida a chave pública registrada, exige `node_epoch` exato e recusa nó revogado/desabilitado.
- Janela de freshness de 120 segundos e nonce single-use com cache anti-replay persistente.
- O nome persistido do replay deriva do SHA-256 do nonce; o nonce original não vira nome de arquivo.
- ACK do controlador também é assinado com sua identidade Ed25519 e verificado pelo nó.

### Transporte e segurança

- Novo listener de health opcional sobre TLS 1.3 somente.
- Certificado TLS Ed25519 do controlador possui pin SHA-256 explícito no nó.
- Fingerprint incorreto falha fechado antes de enviar o heartbeat.
- Listener fica desligado até `manager hive health controller enable ...`.
- Porta padrão 9444 quando não informada.
- O MANAGER não abre firewall automaticamente para o heartbeat.
- Rate limit por endereço de origem reduz burst abusivo antes da validação completa.
- O controlador continua fora do caminho de dados VPN dos usuários.

### Métricas e estados

- Heartbeat reporta uptime, CPU, CPUs lógicas, load 1/5/15, RAM total/disponível/usada, interface e contadores RX/TX.
- Inclui sessões/identidades ativas, `max_sessions`, capacidade, peso e estado administrativo local.
- Inclui protocolos disponíveis e estado de SSH, WireGuard, OpenVPN e da malha `mgh0`.
- Inclui peer count da malha e RTT observado na troca anterior com o controlador.
- Estados derivados: `HEALTHY`, `DEGRADED`, `DRAINING` e `OFFLINE`.
- `DRAINING` em 0.8.2 é estado informativo quando o nó reporta `enabled=0`; scheduler/drain runtime continuam fora deste milestone.
- Threshold padrão: heartbeat atrasado após 75 s; offline após 180 s.
- Thresholds podem ser alterados com `manager hive health controller thresholds DEGRADED OFFLINE`.
- Revogação ou avanço de `node_epoch` transforma autoridade antiga em `OFFLINE`/fenced em vez de aceitar heartbeat stale.

### CLI e lifecycle

- `manager hive health status`.
- `manager hive health configure HOST PORT TLS_FP [INTERVAL]`.
- `manager hive health disable|send`.
- `manager hive health controller init|status|list`.
- `manager hive health controller show NODE_ID`.
- `manager hive health controller enable BIND_IP [PORT]`.
- `manager hive health controller disable`.
- `manager hive health controller thresholds DEGRADED OFFLINE`.
- `manager hive health controller rotate-tls`.
- Timer `manager-hive-heartbeat.timer` envia amostras periodicamente quando habilitado.
- Serviço `manager-hive-health-controller.service` executa o listener do controlador quando explicitamente habilitado.
- Lifecycle da Colmeia passa a destacar heartbeat/listener antes da rede `mgh0` em uninstall/rollback.
- Configuração durável de saúde permanece para reinstalação; units/runtime MANAGER são removidos no detach.

### CI

- Novo workflow `Hive Heartbeat and Health`.
- Testa enrollment isolado, listener TLS 1.3, pin correto e pin incorreto.
- Testa heartbeat assinado válido, registro de métricas, adulteração e replay.
- Testa derivação de `DEGRADED` por atraso e `OFFLINE` por timeout.
- Testa `DRAINING` administrativo sem declarar drain de scheduler já implementado.
- Testa revogação/`node_epoch` fencing contra heartbeat antigo.
- Testa lifecycle preservando configuração durável.
- Antes do bump de release, os **19/19 workflows** do HEAD funcional concluíram com sucesso e zero falhas.

### Próxima etapa

- 0.8.3: scheduler, drain e seleção de nó usando health/capacidade/latência.
- 0.8.4: autoridade global de sessões/leases.
- 0.8.5: VPN allocation / login global.

## [0.8.1] - 2026-10-11

### Colmeia — rede privada WireGuard

- Adicionado `modules/hive_network.sh` como plano de dados privado da Colmeia, separado das VPNs dos usuários.
- Interface dedicada `mgh0`; o `wg0` de clientes não é reutilizado nem alterado pela malha.
- Topologia inicial é mesh direto VPS↔VPS; o controlador distribui autoridade/topologia e não vira relay do tráfego VPN dos usuários.
- Cada nó gera sua própria chave WireGuard local; a chave privada nunca é enviada ao controlador, a outro nó, ao request ou ao bundle.
- Network request é assinado pela identidade Ed25519 do nó já enrolled e vinculado ao `node_id`/`node_epoch`.
- Controlador atribui IPv4/IPv6 internos únicos e mantém somente chave pública, endpoint, porta e estado de topologia.
- Bundles de topologia são assinados pelo controlador e emitidos por nó.
- Novo `config_epoch` monotônico cerca rollback de topologia; bundle antigo ou divergente no mesmo epoch é recusado.
- Nós podem ser habilitados/desabilitados na topologia sem apagar sua identidade criptográfica.
- Nenhum bundle da Colmeia instala rota default `0.0.0.0/0` ou `::/0`.
- O MANAGER não abre automaticamente a porta WireGuard da malha no firewall.

### Runtime e ownership

- `mgh0.conf` gerado pelo MANAGER recebe marker explícito e ownership durável separado.
- Configuração `mgh0.conf` externa, symlink, arquivo não regular ou arquivo sem ownership do MANAGER é preservada e recusada para overwrite/remove.
- Configuração renderizada é validada por `wg-quick strip` usando um arquivo temporário com basename exato `mgh0.conf`.
- Quando `mgh0` já está ativa, mudança/reconcile usa `restart`, garantindo remoção/aplicação real de peers.
- Falha de aplicação restaura configuração, ownership e estado de serviço anteriores.
- Aceite de bundle também restaura o estado/topologia anterior se a aplicação do runtime falhar.

### Lifecycle

- Adicionado `modules/hive_lifecycle.sh`.
- A malha se integra ao lifecycle já existente da `manager-automation-v2.service` através de drop-in systemd MANAGER-owned.
- `ExecStopPost` destaca `mgh0` durante uninstall/rollback enquanto o código atual ainda existe.
- `ExecStartPost` reconcilia a topologia durável após restart normal do Automation v2.
- Quando Automation v2 é desabilitado por uninstall/rollback, o helper/drop-in se auto-remove e não fica órfão numa versão antiga sem Hive Network.
- Uninstall normal remove somente runtime/ownership da malha e preserva chave WireGuard local/topologia durável.
- Rollback para uma versão sem Hive Network deixa `mgh0` e hooks externos removidos, preservando estado durável para retorno posterior.

### CLI

- `manager hive network status|init|up|down|reconcile`.
- `manager hive network request ENDPOINT OUT [PORT]`.
- `manager hive network accept BUNDLE`.
- `manager hive network controller init|status|list`.
- `manager hive network controller show NODE_ID`.
- `manager hive network controller approve REQUEST`.
- `manager hive network controller enable|disable NODE_ID`.
- `manager hive network controller bundle NODE_ID OUT`.
- `manager hive network controller bundle-all DIR`.

### CI

- Workflow `Hive Private Network` cobre dois nós isolados, requests assinados, tamper detection, endereços internos únicos, bundles assinados, ausência de chave privada exportada, ausência de rota default, `config_epoch`, disable de peer, ownership externo e restart de interface ativa.
- Workflow `Hive Network Lifecycle` cobre uninstall normal e rollback real para uma árvore 0.8.0 sem Hive Network.
- Regressão de `grep -q`/SIGPIPE no teste de status do Automation v2 foi corrigida sem alterar o daemon.
- Antes do bump de release, os **18/18 workflows** do HEAD funcional concluíram com sucesso.

### Próxima etapa

- 0.8.2: heartbeat assinado + saúde dos nós.
- 0.8.3: scheduler, drain e seleção de nó.
- 0.8.4: autoridade global de sessões/leases.

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
- OpenSSH dedicado, conta não-root, `ForceCommand`, sudoers exato, allowlist.
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
