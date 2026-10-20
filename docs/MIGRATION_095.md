# Migração assistida de contas SSH — pré-validação (0.9.5)

> **Estado:** ferramentas de pré-validação disponíveis; **ainda não há restauração multi-VPS automática**. Execute as verificações em um servidor de destino de testes, sem alterar contas existentes.

## Escopo

As ferramentas atuais processam exclusivamente arquivos `manager-users-v1` exportados pelo módulo de transferência de usuários SSH. Não transferem configurações da Colmeia, chaves WireGuard, credenciais OpenVPN, sessões ativas, identidades lógicas, produtos nem cotas. **Não substituem um processo de migração completo.**

Os arquivos contêm hashes de senha e são **segredos**: transporte somente por canal autenticado e cifrado, armazenamento com acesso restrito e exclusão segura segundo a política do operador. Nunca enviar para HTTP público, chat ou repositório Git.

## Sequência sem alterações no destino

1. Na origem, exporte os usuários pelo menu de transferência SSH do MANAGER; mantenha o `.tar.gz` e o `.sha256` juntos.
2. Em uma VPS descartável de destino, copie ambos os arquivos por meio de um canal autenticado e criptografado. Verifique permissões restritas nos arquivos.
3. Execute a partir de um checkout confiável do repositório MANAGER (os scripts em `tools/` ainda não são distribuídos pelo instalador):

```bash
python3 tools/migration_preflight.py /caminho/manager-users-EXEMPLO.tar.gz
python3 tools/migration_conflicts.py /caminho/manager-users-EXEMPLO.tar.gz
python3 tools/migration_plan.py /caminho/manager-users-EXEMPLO.tar.gz
```

4. Revise `blocked_users`, `eligible_users` e `archive_sha256`. Se houver qualquer conflito de nomes, interrompa o procedimento e resolva manualmente antes de aprovar.
5. Para validar a confirmação **sem executar restauração**, use o SHA-256 do plano:

```bash
python3 tools/migration_approval.py \
  /caminho/manager-users-EXEMPLO.tar.gz \
  --expected-sha256 SHA256_DO_PLANO
```

O programa solicita a frase `APROVAR SHA256_DO_PLANO` por **stdin**. Uma resposta de aprovação indica apenas que as verificações foram satisfeitas naquele momento. **Nenhum usuário é criado ou atualizado.** A aprovação não é uma autorização permanente e não deve ser reutilizada sem nova verificação de integridade e conflitos.

## Limites e critérios para implementação futura

- Garantir reserva atômica de nomes de usuários para evitar corrida entre pré-validação e criação.
- Reavaliar permissões e conflitos imediatamente antes de cada operação real.
- Nunca restaurar hashes de senha em contas existentes nem substituir `/etc/passwd` ou `/etc/shadow`.
- Validar UID/GID, shell, expiração, proprietários, cotas e estado do produto antes de criar uma conta.
- Fornecer backups, diário de execução auditável e rollback conservador por conta.
- Testar em duas VPS descartáveis (Ubuntu e Debian) antes de considerar implantação de produção.
- Manter a migração da Colmeia/identidades VPN em um fluxo distinto; estes arquivos **não** representam todo o estado do MANAGER.

Os comandos desta página são verificações locais não destrutivas. Não executar restauração manual diretamente dos campos do arquivo.
