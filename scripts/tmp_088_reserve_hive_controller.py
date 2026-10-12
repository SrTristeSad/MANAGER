from pathlib import Path

p=Path('modules/automation_principals.sh')
s=p.read_text()
s=s.replace('LOCAL_ROOT_ID="local-root"\n', 'LOCAL_ROOT_ID="local-root"\nHIVE_CONTROLLER_ID="hive-controller"\n', 1)
old='''  [[ "$id" != "$LOCAL_ROOT_ID" ]] || { err "$LOCAL_ROOT_ID é reservado"; return 65; }
  [[ ! -e "$(principal_file "$id")" ]] || { err "Principal já existe: $id"; return 65; }
'''
new='''  [[ "$id" != "$LOCAL_ROOT_ID" ]] || { err "$LOCAL_ROOT_ID é reservado"; return 65; }
  [[ "$id" != "$HIVE_CONTROLLER_ID" ]] || { err "$HIVE_CONTROLLER_ID é reservado para a identidade da Colmeia"; return 65; }
  [[ ! -e "$(principal_file "$id")" ]] || { err "Principal já existe: $id"; return 65; }
'''
if old not in s:
    raise SystemExit('create_principal reserved-id anchor missing')
s=s.replace(old,new,1)
p.write_text(s)
