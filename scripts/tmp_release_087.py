from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if old not in s:
        raise SystemExit(f"anchor missing in {path}: {old!r}")
    p.write_text(s.replace(old, new, 1))


replace_once('README.md', 'Versão atual: **0.8.6**.', 'Versão atual: **0.8.7**.')
replace_once('README.md', '## Colmeia — 0.8.0 a 0.8.6', '## Colmeia — 0.8.0 a 0.8.7')
replace_once(
    'README.md',
    '- **0.8.6** — accounting global idempotente por nó, deduplicação de deltas e franquia global separada de `max_sessions_global`.\n',
    '- **0.8.6** — accounting global idempotente por nó, deduplicação de deltas e franquia global separada de `max_sessions_global`.\n'
    '- **0.8.7** — resiliência operacional: estado de outage/recovery da autoridade, probe autenticado, fencing de geração e drain sem expulsão desnecessária.\n',
)
replace_once(
    'README.md',
    'O estado durável da Colmeia entra no backup protegido do MANAGER e pode conter chaves privadas de nó/controlador; trate o backup como segredo operacional. Uninstall normal preserva confiança, topologia, configuração de saúde, placement/sticky e política/estado global de lease; runtime e listeners MANAGER-owned são destacados. `--purge` remove também scheduler/lease state e audits server-side.\n\nDocumentação: [`docs/HIVE.md`](docs/HIVE.md).',
    'O estado durável da Colmeia entra no backup protegido do MANAGER e pode conter chaves privadas de nó/controlador; trate o backup como segredo operacional. Uninstall normal preserva confiança, topologia, configuração de saúde, placement/sticky e política/estado global de lease; runtime e listeners MANAGER-owned são destacados. `--purge` remove também scheduler/lease state e audits server-side.\n\nNa 0.8.7, o nó persiste o estado operacional da autoridade (`healthy`, `outage` ou `fenced`) e expõe `manager hive lease node probe` pelo mesmo canal Ed25519 + TLS 1.3 pinado. Outage de transporte mantém novas admissões fail-closed; sessões já válidas continuam limitadas ao grace existente. Uma autoridade que retorna com `authority_epoch` antigo é cercada, enquanto recovery válido é registrado sem colocar o controlador no caminho de dados VPN.\n\nDocumentação: [`docs/HIVE.md`](docs/HIVE.md).',
)

p = Path('CHANGELOG.md')
s = p.read_text()
marker = '## [0.8.6] - 2026-10-12\n'
section = '''## [0.8.7] - 2026-10-12

### Colmeia — failover e resiliência operacional

- O nó agora persiste o estado operacional da autoridade global como `healthy`, `outage` ou `fenced`, sem criar uma segunda autoridade e sem colocar o controlador no caminho de dados VPN.
- Estado root-only registra maior `authority_epoch` aceito, último sucesso, início da outage, última falha de transporte, último recovery, `recovery_count`, último fencing e a geração retornada.
- Novo `manager hive lease node probe` reutiliza o mesmo canal das leases globais: identidade Ed25519 enrolled, `node_epoch`, freshness/nonce, TLS 1.3 e pin SHA-256.
- Falha de transporte marca `outage` e novas admissões continuam fail-closed.
- Sessões globais já válidas preservam apenas o grace curto/configurado existente; deny autoritativo, revoke e fencing continuam sem grace.
- Uma resposta válida após outage fecha o estado de falha, registra recovery e volta a revalidar a autoridade normalmente.
- Retorno com `authority_epoch` inferior ao maior já observado marca `fenced`, preserva o maior epoch aceito e recusa a autoridade antiga.
- Drain continua bloqueando novas seleções sem revogar lease/sessão saudável já existente; sticky affinity permanece enquanto o nó continuar elegível.
- Eventos `node-authority-outage`, `node-authority-recovered` e `node-authority-fenced` entram no audit de leases sem persistir segredos.
- Estado de recovery é preservado por detach/uninstall normal e reinstalação.
- Novo gate permanente `Hive Operational Resilience` cobre outage, fail-closed, recovery, stale-authority fencing, retorno válido, drain e persistência.
- O HEAD funcional da 0.8.7 passou **29/29 workflows** antes do bump da release.

### Próxima etapa

- 0.8.8: comandos remotos controlados sobre contratos tipados, sem shell arbitrário.

'''
if '## [0.8.7] - 2026-10-12' not in s:
    if marker not in s:
        raise SystemExit('CHANGELOG 0.8.6 marker missing')
    p.write_text(s.replace(marker, section + marker, 1))

replace_once(
    'docs/ROADMAP.md',
    '### 0.8.7 — failover e resiliência operacional\n\nFundação implementada nesta fase:',
    '### 0.8.7 — failover e resiliência operacional ✅\n\nImplementado:',
)
