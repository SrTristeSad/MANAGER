from pathlib import Path

# VERSION
Path('VERSION').write_text('0.8.5\n')

# README
p=Path('README.md'); s=p.read_text()
s=s.replace('Versão atual: **0.8.4**.', 'Versão atual: **0.8.5**.', 1)
s=s.replace('## Colmeia — 0.8.0 a 0.8.4', '## Colmeia — 0.8.0 a 0.8.5', 1)
old='- **0.8.4** — autoridade global de leases, `max_sessions_global`, fencing e grace controlado.'
new=old+'\n- **0.8.5** — VPN allocation / login global, entrega/provisionamento automático no nó selecionado e retorno seguro de credenciais/perfis.'
if old not in s: raise SystemExit('README 0.8.4 anchor missing')
s=s.replace(old,new,1); p.write_text(s)

# ROADMAP
p=Path('docs/ROADMAP.md'); s=p.read_text()
s=s.replace('### 0.8.5 — VPN allocation / login global 🚧','### 0.8.5 — VPN allocation / login global ✅',1)
s=s.replace('- `VERSION` continua 0.8.4 até os gates finais desta PR passarem.','- release 0.8.5 fechada após o gate público de login/provisionamento e a regressão completa concluírem com sucesso.',1)
p.write_text(s)

# CHANGELOG: prepend release before 0.8.4
p=Path('CHANGELOG.md'); s=p.read_text()
anchor='## [0.8.4] - 2026-10-12\n'
if anchor not in s: raise SystemExit('CHANGELOG anchor missing')
entry='''## [0.8.5] - 2026-10-12\n\n### Colmeia — VPN allocation / login global\n\n- Allocation assinada por Ed25519 vinculada a identidade, produto, protocolo, região/pool, nó, `node_epoch`, lease global exata e `session_epoch`.\n- Distribuição automática por pull no mesmo canal TLS 1.3 com fingerprint pinado da autoridade global; ACK somente após aceite local durável.\n- Provisionamento idempotente de SSH, WireGuard e OpenVPN no nó selecionado antes do ACK, com receipt local root-only e redelivery seguro.\n- Exact-grant impede fallback para outra reserva ou capacidade global genérica quando a allocation exige um `global_lease_id` específico.\n- Novo contrato `manager-hive-vpn-login-result-v1` devolve o resultado pelo ACK autenticado sem colocar segredo em argv, stdout ou audit.\n- Resultados sensíveis ficam em arquivo `0600` no controlador e são exportados para arquivo novo `0600` por `manager hive login result`.\n- SSH diferencia credencial recém-emitida de recurso já existente sem tornar senhas antigas recuperáveis; WireGuard/OpenVPN retornam o perfil gerenciado em base64.\n- CLI pública `manager hive login create` + `manager hive login result` fecha o fluxo de provisionamento/login de ponta a ponta.\n- CI permanente cobre allocation foundation, distribuição, provisionamento remoto e resultado público; o HEAD de fechamento passou a regressão completa antes do bump.\n- `global_accounting=0` permanece intencional; quotas/accounting globais ficam para 0.8.6.\n\n'''
s=s.replace(anchor,entry+anchor,1); p.write_text(s)
