# IPv6 / Dual Stack — MANAGER 0.6.8

A série 0.6.8 torna IPv6 parte do caminho normal de WireGuard, OpenVPN, firewall, provisionamento e enforcement de sessão. O objetivo não é apenas mostrar um endereço IPv6 no servidor: uma identidade dual-stack precisa obedecer às mesmas regras de produto, lease, bloqueio e lifecycle já aplicadas ao IPv4.

## Regra de ativação

O MANAGER só habilita IPv6 automaticamente em uma VPN nova quando a VPS possui:

- rota IPv6 padrão;
- endereço IPv6 global na interface de saída.

Sem essas duas condições, WireGuard e OpenVPN continuam IPv4-only. O MANAGER não cria perfil com `::/0` quando o servidor não tem como encaminhar esse tráfego.

Estado resumido:

```bash
manager --ipv6-status
```

Também existe a opção `Estado IPv6 / dual-stack` no menu principal.

## WireGuard

Rede IPv4 do MANAGER:

```text
10.66.66.0/24
```

Rede IPv6 da VPN:

```text
fd66:66:66::/64
```

Quando dual-stack está ativo, um cliente pode receber, por exemplo:

```text
Address = 10.66.66.2/32, fd66:66:66::2/128
AllowedIPs = 0.0.0.0/0, ::/0
```

O servidor recebe `fd66:66:66::1/64` e encaminha o prefixo ULA da VPN usando NAT66 somente na interface IPv6 de saída detectada.

O MANAGER continua criando e removendo apenas regras específicas. Não existe `ip6tables -F` nem limpeza global de firewall.

### Endpoint IPv6 literal

Um endereço IPv6 usado diretamente como endpoint precisa de colchetes para separar a porta:

```text
[2001:db8::10]:51820
```

O helper compartilhado do MANAGER faz essa formatação automaticamente. Domínios e IPv4 continuam no formato normal.

### Clientes existentes

Instalações WireGuard criadas anteriormente pelo MANAGER podem usar a opção `Ativar/reconciliar IPv6 dual-stack` no módulo WireGuard.

A migração:

- preserva as chaves existentes;
- adiciona o endereço IPv6 correspondente a cada cliente conhecido;
- adiciona `::/0` ao perfil do cliente;
- adiciona o IPv6 ao `AllowedIPs` do peer do servidor;
- reinicia `wg-quick@wg0` somente depois de preparar a configuração;
- restaura a configuração do servidor se o restart falhar.

Metadados novos usam:

```text
ip=10.66.66.2
ip4=10.66.66.2
ip6=fd66:66:66::2
```

`ip=` é mantido por compatibilidade com código e instalações anteriores.

## OpenVPN

Rede IPv4:

```text
10.8.0.0/24
```

Rede IPv6:

```text
fd66:8::/64
```

Quando a VPS possui saída IPv6, a configuração do servidor recebe:

```text
server-ipv6 fd66:8::/64
push "redirect-gateway ipv6"
```

O override systemd do OpenVPN instala somente regras IPv6 específicas para `tun0` e NAT66 do prefixo da VPN.

Uma instalação MANAGER existente pode ser atualizada pela opção `Ativar/reconciliar IPv6 dual-stack` do módulo OpenVPN. A configuração e o override anterior são preservados temporariamente; se o daemon não voltar ativo, a atualização é desfeita.

## Por que ULA + NAT66 nesta fase

O MANAGER usa ULA dentro das VPNs e traduz a saída para o IPv6 global da VPS. Isso permite que o mesmo modelo funcione em provedores que entregam apenas um endereço IPv6 ao servidor, sem depender de um prefixo roteado dedicado para clientes.

Isso é uma escolha de portabilidade da série 0.6.x, não uma limitação conceitual da futura Colmeia. Um modo posterior poderá usar prefixo IPv6 roteado diretamente quando o provedor entregar delegação adequada.

## IPv6 Guard

O `IPv6 Guard` não cria uma segunda autoridade de autenticação. Ele espelha no plano IPv6 a decisão já tomada pelo Connection/Policy/Session Engine.

Fluxo:

```text
identidade + produto
        ↓
Session / Lease Engine
        ↓
lease válida?
   ├── sim → tráfego IPv6 liberado
   └── não → DROP específico do endereço IPv6 da identidade
```

Unidades:

```text
manager-ipv6-guard.service
manager-ipv6-guard.timer
```

O reconciliador roda periodicamente e usa regras específicas por identidade.

### WireGuard

O endereço IPv6 é conhecido pelo metadata do peer. Uma identidade sem lease válida recebe um DROP somente para:

```text
-i wg0 -s <ipv6-do-cliente>/128
```

Quando a lease passa a existir novamente, somente essa regra é removida.

### OpenVPN

O endereço virtual IPv6 é obtido do status do servidor. O mesmo princípio é aplicado em `tun0`: identidade sem autorização recebe bloqueio específico, sem flush do firewall e sem necessidade de revogar o certificado.

## UFW

Ao instalar/configurar UFW pelo MANAGER, `/etc/default/ufw` é validado para:

```text
IPV6=yes
```

Assim, uma porta liberada ou bloqueada pelo módulo Firewall não fica protegida apenas em IPv4.

O estado pode ser consultado em:

```bash
/opt/manager/modules/firewall.sh --network-status
```

## Forwarding e lifecycle

Antes de alterar forwarding, o MANAGER preserva os valores anteriores:

```text
/etc/manager/network/previous-ip-forward
/etc/manager/network/previous-ipv6-forwarding
```

O purge explícito restaura ambos quando o valor anterior é conhecido.

No uninstall normal:

- o estado lógico dual-stack é preservado em `/etc/manager`;
- regras runtime do IPv6 Guard são removidas;
- unidades do guard são removidas;
- reinstalar o MANAGER recria o guard e volta a consumir o estado persistido.

Rollback também desmonta o guard antes da troca de código e só o reinstala quando a versão restaurada possui o módulo.

## Provisionamento unificado

`manager --provision` usa o estado do servidor em vez de criar um caminho separado.

Quando WireGuard está dual-stack, a saída estruturada inclui:

```text
wireguard_ip=10.66.66.2
wireguard_ipv4=10.66.66.2
wireguard_ipv6=fd66:66:66::2
```

`wireguard_ip` continua existindo por compatibilidade.

OpenVPN expõe também:

```text
openvpn_ipv6=1
```

A revogação reconcilia o IPv6 Guard junto com Policy/Session Engine.

## Accounting

WireGuard e OpenVPN já reportam contadores de transferência no nível do túnel/peer. Esses contadores incluem os bytes transportados pelo túnel independentemente de o payload interno ser IPv4 ou IPv6.

Por isso, a 0.6.8 não cria um segundo histórico de bytes apenas para IPv6. O Identity Usage Accounting existente continua sendo a fonte de consumo desses protocolos.

SSH continua com a mesma regra anterior: atividade e sessão são observadas, mas o MANAGER não inventa byte accounting por UID Linux.

## Limites atuais

- IPv6 continua dependente da conectividade real oferecida à VPS.
- ULA + NAT66 é o modo portátil atual; prefixos roteados/delegados poderão ser adicionados depois.
- A autoridade de sessão ainda é local a uma VPS. A Colmeia moverá leases para o Hub sem mudar o princípio de que IPv4 e IPv6 pertencem à mesma sessão lógica.
- O IPv6 Guard depende de `ip6tables` quando uma VPN dual-stack está em uso. Os módulos WireGuard/OpenVPN instalam o pacote necessário durante a instalação do serviço.
