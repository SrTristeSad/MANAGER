from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, got {count}")
    p.write_text(text.replace(old, new, 1))


replace_once("docs/ROADMAP.md", "### 0.8.5 — VPN allocation / login global — PRÓXIMO\n", "### 0.8.5 — VPN allocation / login global 🚧\n")

replace_once("docs/HIVE.md", "## 16. Audit global\n", '''## 16. Allocation / login global — fundação 0.8.5

A 0.8.5 introduz um ticket de allocation assinado pelo controlador. Ele vincula `identity_id`, `product_id`, protocolo, região/pool, nó e `node_epoch`, `global_lease_id`, `global_epoch` e `session_epoch`. O nó só aceita tickets destinados ao enrollment atual.

O modo é opt-in para preservar a compatibilidade da 0.8.4:

```bash
manager hive allocation enable
```

No controlador, uma allocation cria primeiro um grant global reservado e então emite o bundle Ed25519:

```bash
manager hive allocation controller create \\
  maria wireguard /root/maria.alloc.json BR-SP PREMIUM maria '*' 60
```

No nó selecionado:

```bash
manager hive allocation accept /root/maria.alloc.json
```

Quando o enforcement de allocation está ativo, o Protocol Lease Bridge exige um ticket local atual e reclama **exatamente** o `global_lease_id` vinculado. Não existe fallback para acquire global genérico apenas porque ainda há capacidade. SSH/OpenVPN continuam com admissão síncrona; WireGuard passa a poder receber autorização antes do primeiro uso quando a allocation é entregue ao nó.

Revogação avança o `session_epoch` da allocation e também revoga grants/leases globais:

```bash
manager hive allocation controller revoke maria compromised
```

O controlador continua fora do caminho de dados VPN.

## 17. Audit global
''')

p = Path("docs/HIVE.md")
text = p.read_text()
text = text.replace("## 17. Limites desta etapa", "## 18. Limites desta etapa", 1)
text = text.replace("## 18. Lifecycle", "## 19. Lifecycle", 1)
text = text.replace("## 19. Backup", "## 20. Backup", 1)
p.write_text(text)
