# Cotas de revenda por identidade e produto

A versão 0.6.7 migra a unidade principal de cota de revenda de **usuário Linux** para **identidade lógica MANAGER**.

Isso permite que um cliente de revenda consuma uma vaga mesmo quando usa somente WireGuard ou OpenVPN e não possui conta SSH.

## Modelo

Uma identidade ocupa uma única vaga do revendedor, independentemente da quantidade de protocolos vinculados:

```text
maria
├── owner = revenda01
├── ssh = opcional
├── wireguard = opcional
└── openvpn = opcional

uso da cota = 1 cliente
```

Assim, uma identidade com SSH + WireGuard + OpenVPN continua contando como **um cliente**, não três acessos.

## Hierarquia

O modelo mantém dois níveis iniciais:

```text
revendedor
└── subrevendedor
```

A cota do subrevendedor limita seus próprios clientes. O uso do subrevendedor também entra no total do revendedor pai.

Exemplo:

```text
revenda01: cota 100
└── sub01: cota 20
    ├── cliente-a
    └── cliente-b
```

`sub01` usa 2/20 e `revenda01` também passa a contabilizar esses dois clientes em seu total agregado.

## Reserva atômica da vaga

Antes de gravar uma nova identidade com proprietário, o Connection Engine reserva uma vaga sob lock em:

```text
/etc/manager/access/identity-slots/
```

O slot é gravado antes da identidade para impedir que duas criações concorrentes ultrapassem a mesma cota.

Um slot registra:

```text
identity_id
owner
active
assigned_epoch
released_epoch
```

A identidade só é criada se a reserva for permitida pelo revendedor e, quando houver, pelo revendedor pai.

## Bloqueio, revogação e reativação

**Desabilitar** uma identidade não libera sua vaga automaticamente. Isso representa bloqueio temporário e mantém o cliente pertencendo à carteira do revendedor.

**Revogar definitivamente** pelo provisionador remove/revoga os recursos técnicos e, ao concluir sem falhas, libera a vaga. A identidade lógica permanece `disabled` para histórico e auditoria.

Uma identidade cuja vaga foi liberada precisa reservar uma vaga novamente antes de ser reativada. Se a cota estiver cheia, a reativação é recusada.

Uma identidade ainda ativa não pode liberar seu slot diretamente.

## Compatibilidade com contas SSH antigas

Contas SSH legadas continuam sendo reconhecidas em:

```text
/etc/manager/access/owners/
```

Enquanto não existir identidade correspondente, a conta Linux ainda ocupa uma vaga.

Quando uma conta SSH antiga é adotada por uma identidade MANAGER, o sistema deduplica a contagem:

```text
usuário SSH antigo = alex
identidade nova    = alex
resultado          = 1 vaga
```

A migração não transforma uma conta antiga em duas cobranças de cota.

Identidades revogadas preservadas pela 0.6.6, identificáveis como `disabled`, sem bindings técnicos e sem produto atribuído, são migradas com slot inativo para não voltarem a consumir cota somente por causa do upgrade.

## Cota por produto

Além da cota total de clientes, um revendedor pode ter limite opcional por produto:

```text
revenda01
├── clientes totais: 100
├── premium: 20
├── family: 10
└── basic: ilimitado
```

Estado:

```text
/etc/manager/access/product-quotas/<owner>/<product>.conf
```

`0` significa ilimitado.

A cota de produto também respeita a hierarquia. Um subrevendedor pode ter seu próprio limite, mas continua sujeito ao limite agregado do revendedor pai.

Comandos internos/administrativos:

```bash
/opt/manager/modules/reseller_product_quotas.sh --set OWNER PRODUCT QUOTA
/opt/manager/modules/reseller_product_quotas.sh --show OWNER PRODUCT
/opt/manager/modules/reseller_product_quotas.sh --list [OWNER]
```

Consulta pela CLI principal:

```bash
manager --reseller-usage revenda01
manager --reseller-product-quota revenda01 premium
```

O menu principal também possui a opção **Cotas de produto por revendedor**.

## Enforcement

A validação de produto não existe apenas no menu. `products.sh --assign` consulta a cota do proprietário antes de alterar a atribuição.

O provisionamento unificado valida no preflight:

1. cota total da identidade;
2. estado do revendedor/subrevendedor;
3. cota específica do produto;
4. limite agregado do pai, quando aplicável.

Assim uma operação que já sabe que excederia a cota é rejeitada antes da criação dos recursos técnicos.

O código `73` é usado para recusas de capacidade/autorização de cota nessa camada.

## Persistência e backup

Todo o estado de revenda continua dentro de:

```text
/etc/manager/access/
```

Portanto slots de identidade e cotas por produto participam do backup já existente do MANAGER e sobrevivem a uninstall normal. `--purge` continua sendo a operação explícita que remove o estado do MANAGER.

## Limite desta etapa

As cotas da 0.6.7 ainda são autoritativas **na VPS local**. A futura Colmeia moverá a reserva para uma autoridade global para impedir que o mesmo revendedor/identidade exceda seus limites distribuindo criações por nós diferentes.

A 0.6.7 não transforma o accounting local de tráfego em faturamento global e não substitui o futuro lease global de sessão.
