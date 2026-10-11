# Provisionamento Unificado — 0.6.6+

A 0.6.6 adicionou uma operação única para criar uma identidade MANAGER, aplicar um produto/plano e materializar os recursos técnicos permitidos por esse produto. A 0.6.7 remove a dependência de SSH para clientes de revenda ao integrar o provisionador às cotas por identidade e produto.

## Objetivo

Antes desta etapa, o fluxo normal era composto por várias operações separadas:

```text
criar usuário SSH
criar cliente WireGuard
criar cliente OpenVPN
criar identidade
fazer bindings
aplicar produto
reconciliar política
```

O provisionador reúne essas etapas em uma transação controlada:

```text
preflight
   ↓
reserva de cota, quando houver OWNER
   ↓
identidade
   ↓
produto
   ↓
recursos técnicos
   ↓
bindings
   ↓
Policy / Product reconcile
   ↓
commit
```

Se uma etapa falhar, os recursos criados naquela tentativa são revertidos em ordem inversa.

## CLI

Provisionar:

```bash
manager --provision ID PLANO [OWNER] [PROTOCOLS]
```

Exemplos:

```bash
manager --provision maria brasil-premium
manager --provision maria brasil-premium '' wireguard,openvpn
manager --provision cliente01 plano-ssh revenda01 ssh
manager --provision cliente02 plano-vpn revenda01 wireguard
```

Revogar todos os acessos técnicos vinculados:

```bash
manager --revoke-identity maria
```

Preflight interno, útil para automação futura:

```bash
/opt/manager/modules/provision.sh --preflight ID PLANO OWNER PROTOCOLS
```

O preflight não cria recursos. Ele valida ID, produto, protocolos, conflitos de nomes, disponibilidade dos servidores VPN e, quando houver proprietário, cota total da identidade, estado do revendedor/subrevendedor e cota específica do produto.

## Seleção de protocolos

Quando `PROTOCOLS` é informado, ele deve ser um subconjunto permitido pelo produto.

Protocolos reconhecidos:

```text
ssh
wireguard
openvpn
```

Quando `PROTOCOLS` fica vazio, o provisionador usa a lista do produto. Se o produto usa `protocols=*`, a seleção padrão é:

```text
ssh,wireguard,openvpn
```

Nesse caso, WireGuard e OpenVPN precisam estar configurados no servidor. Para criar somente parte dos acessos, informe explicitamente o subconjunto desejado.

## SSH

O provisionador:

1. cria o usuário Linux;
2. gera uma senha aleatória de 128 bits representada em 32 caracteres hexadecimais;
3. aplica a validade efetiva do produto quando houver;
4. mantém a senha bloqueada enquanto a transação está incompleta;
5. cria o binding SSH da identidade;
6. reconcilia produto e política;
7. libera a senha somente depois do commit.

A senha é retornada uma única vez como `ssh_password=...`. Ela não é gravada em `provision-events.log` nem em arquivos de compatibilidade em texto claro.

## WireGuard

WireGuard só pode ser provisionado quando o servidor MANAGER já está configurado. O provisionador escolhe endereço livre, gera chave privada/pública e PSK, grava perfil restrito, adiciona somente o peer correspondente em `wg0.conf`, recarrega a unidade quando necessário e cria o binding.

Em rollback, remove somente o peer e os arquivos daquela tentativa. Não existe flush global de firewall nem substituição global da configuração.

## OpenVPN

OpenVPN também exige que o servidor MANAGER já esteja configurado. O provisionador usa a PKI Easy-RSA existente para gerar certificado/chave, produzir o `.ovpn`, registrar metadados e criar binding.

Se a transação falhar depois da emissão, o certificado é revogado e a CRL é regenerada. O histórico da CA não é apagado.

## Produto, validade e sessões

O produto continua sendo a fonte das restrições comerciais/lógicas:

```text
duration_days
max_sessions
protocols
traffic_quota_bytes
quota_period
quota_action
ACL region/pool/node
```

O provisionador não implementa um segundo sistema de limites. Product Policy, Policy Engine e Session/Lease Engine continuam sendo as autoridades existentes.

## Revendedores e cotas — 0.6.7

Um `OWNER` pode agora receber identidade:

```text
ssh
wireguard
openvpn
ssh + wireguard
wireguard + openvpn
ssh + wireguard + openvpn
```

sem depender de usuário Linux para ser contado.

Antes da criação, o preflight verifica:

```text
cota total do owner
cota agregada do revendedor pai
cota do produto do owner
cota agregada do produto no pai
```

A criação da identidade reserva um slot em `/etc/manager/access/identity-slots/` sob lock. Uma identidade consome uma vaga independentemente da quantidade de protocolos vinculados.

Atribuição direta por `products.sh --assign` também verifica a cota de produto, portanto esse limite não pode ser contornado usando um caminho administrativo diferente do provisionador.

Documentação detalhada: [`RESELLER_QUOTAS.md`](RESELLER_QUOTAS.md).

## Sinalização transacional de política

Uma criação completa produz várias alterações na identidade. Pela CLI oficial, o MANAGER adia os sinais intermediários usados pelo watcher `manager-policy-reconcile.path` e emite um sinal ao final da operação.

Isso evita que uma unidade systemd tente aplicar uma identidade parcialmente construída enquanto bindings e credenciais ainda estão sendo preparados. A reconciliação necessária para validar o commit continua ocorrendo dentro da transação antes de o SSH ser desbloqueado.

## Revogação

`manager --revoke-identity ID` começa desativando a identidade e revogando as leases. Depois remove/revoga os recursos técnicos vinculados:

```text
SSH       → usuário Linux removido
WireGuard → peer/configuração do cliente removidos
OpenVPN   → certificado revogado + CRL atualizada
```

O produto é desvinculado e os bindings são limpos. Quando toda a revogação termina sem erro, a vaga de revenda da identidade é liberada.

A identidade lógica **não é apagada**. Ela permanece em estado `disabled`, permitindo histórico/auditoria. Se alguma etapa falhar, a identidade continua desativada e a vaga não é liberada prematuramente.

## Auditoria

Eventos ficam em:

```text
/var/log/manager/provision-events.log
```

O registro contém somente metadados operacionais (`action`, ID, produto, owner, protocolos e resultado). Senhas e chaves privadas não são gravadas nesse log.

## Lifecycle

O módulo é instalado em `/opt/manager/modules/provision.sh`. O estado durável continua nos diretórios usados pelos motores existentes; não existe banco paralelo para identidades/produtos.

Uninstall normal preserva o estado lógico do Connection Engine e da revenda. Recursos explicitamente revogados não são recriados por uma reinstalação.

## Automation v2

O contrato prepara a futura Automation v2:

```text
preflight
provision
revoke
resultado estruturado
códigos de erro
rollback controlado
```

A futura API não deverá ganhar shell remoto arbitrário; ela chamará operações allowlisted equivalentes a este motor de provisionamento.
