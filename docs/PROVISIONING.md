# Provisionamento Unificado — 0.6.6

A 0.6.6 adiciona uma operação única para criar uma identidade MANAGER, aplicar um produto/plano e materializar os recursos técnicos permitidos por esse produto.

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
```

Revogar todos os acessos técnicos vinculados:

```bash
manager --revoke-identity maria
```

Preflight interno, útil para automação futura:

```bash
/opt/manager/modules/provision.sh --preflight ID PLANO OWNER PROTOCOLS
```

O preflight não cria recursos. Ele valida o ID, existência/estado do produto, protocolos solicitados, conflitos de nomes, disponibilidade dos servidores VPN e, quando aplicável, estado/cota do revendedor.

## Seleção de protocolos

Quando `PROTOCOLS` é informado, ele deve ser um subconjunto permitido pelo produto.

Protocolos reconhecidos:

```text
ssh
wireguard
openvpn
```

Quando `PROTOCOLS` fica vazio, o provisionador usa a lista do produto. Se o produto usa `protocols=*`, a seleção padrão desta etapa é:

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

A senha é retornada uma única vez na saída da operação:

```text
ssh_password=...
```

Ela não é gravada em `provision-events.log` e não é adicionada a arquivos de compatibilidade em texto claro.

## WireGuard

WireGuard só pode ser provisionado quando o servidor MANAGER já está configurado.

O provisionador:

- escolhe um endereço livre na rede gerenciada atual;
- gera chave privada, chave pública e PSK;
- grava o perfil do cliente com permissão restrita;
- adiciona somente o bloco do peer correspondente em `wg0.conf`;
- recarrega/reinicia somente `wg-quick@wg0` quando necessário;
- cria o binding da identidade.

Em caso de rollback, remove somente o peer e os arquivos daquela tentativa. Não existe flush de firewall nem substituição global da configuração.

A saída informa o caminho do perfil e o IP atribuído, não replica a chave privada no log de eventos.

## OpenVPN

OpenVPN também exige que o servidor MANAGER já esteja configurado.

O provisionador usa a PKI Easy-RSA existente para:

- gerar o certificado/chave do cliente;
- produzir o perfil `.ovpn`;
- registrar metadados do cliente;
- criar o binding da identidade.

Se a transação falhar depois da emissão, o certificado é revogado e a CRL é regenerada. O histórico de revogação da CA não é apagado para fingir que o certificado nunca existiu.

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

O provisionador não implementa um segundo sistema de limites. Depois do binding, Product Policy, Policy Engine e Session/Lease Engine continuam sendo as autoridades já existentes.

## Sinalização transacional de política

Uma criação completa produz várias alterações na identidade. Pela CLI oficial, o MANAGER adia os sinais intermediários usados pelo watcher `manager-policy-reconcile.path` e emite um sinal ao final da operação.

Isso evita que uma unidade systemd tente aplicar uma identidade parcialmente construída enquanto o provisionador ainda está criando bindings/credenciais.

A reconciliação necessária para validar o commit continua ocorrendo dentro da transação antes de o SSH ser desbloqueado.

## Revogação

`manager --revoke-identity ID` começa desativando a identidade e revogando as leases. Depois remove/revoga os recursos técnicos vinculados:

```text
SSH       → usuário Linux removido
WireGuard → peer/configuração do cliente removidos
OpenVPN   → certificado revogado + CRL atualizada
```

O produto é desvinculado e os bindings são limpos.

A identidade lógica **não é apagada**. Ela permanece em estado `disabled`, permitindo histórico, auditoria e uma futura política explícita de reativação/reprovisionamento.

Se uma etapa da revogação falhar, a identidade permanece desativada e a operação retorna erro parcial em vez de reabilitar acesso incompleto.

## Revendedores — limite temporário da 0.6.6

A camada antiga de cotas de revenda ainda conta contas SSH/Linux. Por isso, nesta etapa, um provisionamento com `OWNER` exige que `ssh` esteja entre os protocolos selecionados.

Isso evita criar uma identidade WireGuard/OpenVPN de revenda que não seria contabilizada pela cota antiga.

A próxima migração deve mover a cota de revenda para **produto/identidade**, permitindo revendedores criarem identidades VPN-only sem depender de usuário Linux.

## Auditoria

Eventos ficam em:

```text
/var/log/manager/provision-events.log
```

O registro contém somente metadados operacionais:

```text
action
identity id
product
owner
protocols
result
```

Senhas, chaves privadas WireGuard e chaves privadas OpenVPN não são gravadas nesse log.

## Lifecycle

O módulo é instalado em:

```text
/opt/manager/modules/provision.sh
```

O estado durável continua nos diretórios já usados pelos motores existentes. A 0.6.6 não cria um banco paralelo para identidades/produtos.

Uninstall normal preserva o estado lógico que já era preservado pelo Connection Engine. Recursos explicitamente revogados pelo operador não são recriados por uma reinstalação.

## Automation v2

O contrato desta versão prepara a futura Automation v2:

```text
preflight
provision
revoke
resultado estruturado
códigos de erro
rollback controlado
```

A futura API não deverá ganhar shell remoto arbitrário; ela chamará operações allowlisted equivalentes a este motor de provisionamento.
