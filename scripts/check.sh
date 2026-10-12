#!/bin/bash
# Verificação do ambiente do laboratório Apache Iceberg.
#   curl -sS https://raw.githubusercontent.com/infobarbosa/iceberg-tableformat-demo/main/scripts/check.sh | bash

cd ~/project 2>/dev/null || { echo "✗ pasta ~/project não encontrada: rode no terminal do code-server"; exit 1; }

ok()   { echo "  ✓ $*"; }
aviso(){ echo "  ! $*"; }
erro() { echo "  ✗ $*"; FALHAS=$((FALHAS + 1)); }
FALHAS=0

echo "Ferramentas"
python3 -c "import pyiceberg" 2>/dev/null && ok "PyIceberg $(python3 -c 'import pyiceberg; print(pyiceberg.__version__)')" || erro "PyIceberg não encontrado"
command -v duckdb >/dev/null && ok "DuckDB $(duckdb -noheader -list -c 'SELECT version()')" || erro "DuckDB não encontrado"
python3 -c "import lab" 2>/dev/null && ok "lab.py ($(python3 -c 'import lab; print(lab.__file__)'))" || erro "lab.py não encontrado no PYTHONPATH"

echo
echo "Dados"
for f in orders products; do
  [ -s "dados/olist_${f}_dataset.csv.gz" ] && ok "dados/olist_${f}_dataset.csv.gz" || aviso "dados/olist_${f}_dataset.csv.gz: ainda não baixado (seção 2.a)"
done

echo
echo "Tabelas locais"
if [ -f warehouse/catalogo.db ]; then
  python3 - <<'PY'
from lab import catalogo
c = catalogo()
tabelas = {".".join(t) for t in c.list_tables("olist")} if ("olist",) in c.list_namespaces() else set()
for nome, secao in [("olist.orders", "3 (e recriada na 8)"), ("olist.products", "7")]:
    if nome not in tabelas:
        print(f"  ! {nome}: ainda não criada (seção {secao})")
        continue
    t = c.load_table(nome)
    linhas = t.scan().to_arrow().num_rows
    spec = ", ".join(str(f.transform) for f in t.spec().fields) or "sem partição"
    print(f"  ✓ {nome}: {linhas} linhas, {len(t.snapshots())} snapshots, partição: {spec}")
PY
else
  aviso "catálogo ainda não criado (seção 3)"
fi

echo
echo "AWS (Parte IV)"
if CONTA=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  ok "credenciais: $(aws sts get-caller-identity --query Arn --output text)"
  aws s3api head-bucket --bucket "iceberg-lab-${CONTA}" 2>/dev/null && ok "bucket iceberg-lab-${CONTA}" || aviso "bucket iceberg-lab-${CONTA}: ainda não criado (seção 13.b)"
  aws glue get-table --database-name olist --name orders >/dev/null 2>&1 && ok "Glue: olist.orders" || aviso "Glue: olist.orders ainda não criada (seção 13.c)"
else
  aviso "sem credenciais AWS (necessárias só na Parte IV)"
fi

echo
echo "Resultado"
[ "$FALHAS" -eq 0 ] && echo "  Ambiente pronto." || echo "  $FALHAS problema(s) encontrado(s)."
