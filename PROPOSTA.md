# Proposta — laboratório Apache Iceberg

Status: **proposta revisada com as decisões de 2026-10-12, aguardando ok para o spike**. Nada implementado ainda.

| Decisão | Escolha |
|---|---|
| Disciplina | Engenharia de Dados, bloco de Open Table Formats (OTF) |
| Domínio | infobarShop (pedidos de e-commerce) |
| Interface | blocos copiáveis para o terminal (heredoc + `lab.py` de apoio) |
| AWS | sim, como parte final |
| Nome | `iceberg-tableformat-demo` (tutorial) e `iceberg-lab-docker-image` (imagem) |

## 1. Iceberg sem Spark?

Sim. O Iceberg é uma **especificação de formato de tabela** (como os arquivos de metadados e de dados se organizam), não um motor nem um banco. Qualquer biblioteca que implemente a especificação lê e grava a tabela. O Spark é só a implementação mais completa (a de referência, em Java).

| | Sem Spark (PyIceberg + DuckDB) | Com Spark (spark-sql) |
|---|---|---|
| Peso da imagem / RAM | ~1 GB / poucos MB em repouso (não há servidor) | +600 MB de JVM e Spark / 1–2 GB de RAM por sessão |
| Interface | Python para escrever, SQL (DuckDB) para ler e inspecionar | Tudo em SQL |
| Atrito para o aluno | Baixo: arquivos locais, `tree`, `jq`, sem configuração de catálogo | Configuração verbosa do catálogo, stack traces Java, ~10 s para subir a sessão |
| Cobertura de recursos | Ampla (snapshots, time travel, schema e partition evolution, delete/overwrite/upsert copy-on-write, tags). Merge-on-read fica na parte AWS (Athena) | Completa (MERGE, merge-on-read, `CALL rewrite_data_files`, branches) |
| Aderência ao mercado | Média (PyIceberg e DuckDB crescem rápido) | Alta (EMR, Glue, Databricks) |
| Foco da aula | **Os arquivos em disco** | O motor |

**Decisão: sem Spark.** O PyIceberg grava e o DuckDB lê; na AWS entram o Glue Data Catalog e o Athena. Ao longo do lab a mesma tabela passa por três motores diferentes, o que é a melhor demonstração do que significa "open table format". O lab antigo (`data-eng-iceberg-demo`, com Spark + REST + MinIO) continua como está.

## 2. Ambiente

Imagem `infobarbosa/iceberg-lab-docker-image`, no mesmo padrão das outras (Ubuntu 24.04, code-server em 8080 com `--auth none`, tini, usuário `barbosa`, multi-arch, CI no GHCR):

- **PyIceberg** (com pyarrow e os extras `sql-sqlite`, `glue` e `s3fs`) num venv pré-instalado: é o motor de escrita.
- **Catálogo SQL em SQLite** (`SqlCatalog`): é um arquivo, não um servidor. O aluno abre com `sqlite3` e vê que o catálogo guarda só um ponteiro.
- **Warehouse no file system local** (`/home/barbosa/warehouse`), para o aluno poder rodar `tree`, `ls -l` e `jq` direto nos arquivos.
- **DuckDB CLI** com as extensões `iceberg`, `avro`, `parquet` e `httpfs` pré-instaladas: é a lente SQL (`iceberg_scan`, `iceberg_snapshots`, `iceberg_metadata`, `read_json`, `read_avro`, `parquet_metadata`).
- **`lab.py`**: módulo de apoio com `catalogo()`, `tabela()` e `carrega_mes('2024-01')`, que baixa o CSV do mês de `datasets-csv-pedidos` via curl e devolve uma tabela Arrow. Assim cada bloco do README tem poucas linhas e mostra só o que importa.
- `jq`, `sqlite3`, `tree`, `aws` CLI.

Não há banco para subir: o entrypoint só sobe o code-server.

## 3. Dados: infobarShop

A tabela principal é `infobarshop.pedidos`, com as colunas `id_pedido`, `produto`, `valor_unitario`, `quantidade`, `data_criacao`, `uf` e `id_cliente`. Ela vem de `datasets-csv-pedidos` (um CSV por mês, de jan/2024 a jun/2025, cerca de 2 mil pedidos por mês). Apoio: `datasets-csv-clientes` e `dataset-json-pagamentos`.

**Um mês carregado = um commit.** A carga incremental mensal faz os snapshots aparecerem naturalmente, sem truque. A narrativa acompanha o dia a dia do time de dados do infobarShop: carga mensal, fechamento contábil, mudança no sistema de origem, Black Friday, pedido de exclusão (LGPD) e migração para a nuvem.

## 4. Roteiro: um conceito por vez

Cada seção segue o mesmo formato: **conceito → prática → "O que você deve conseguir responder"**. Cada seção reaproveita a tabela e os arquivos da anterior. Subseções numeradas (`3.a`) e blocos rotulados (`# 3.b.1`).

### Parte I — Do arquivo à tabela

**1. Ambiente.** CloudShell + `launch-lab.sh`, code-server, "Retomando o laboratório".

**2. O problema: um data lake de Parquet "cru".** O DuckDB converte três meses de pedidos para Parquet numa pasta `lake/pedidos/` e consulta com glob.
Prática:
- (a) o sistema de origem passa a mandar `estado` no lugar de `uf`, e o faturamento por UF passa a vir com NULL;
- (b) cancelar um único pedido obriga a reescrever o arquivo do mês;
- (c) um relatório roda enquanto a carga de abril ainda está gravando e soma um mês pela metade;
- (d) "qual era o faturamento de janeiro no fechamento de 01/02?" não tem resposta.

*Conceito:* sem um formato de tabela, a "tabela" é só uma convenção sobre uma pasta. Cada um desses quatro problemas volta a ser resolvido numa seção adiante.

**3. Iceberg é uma especificação: catálogo, metadados, dados.** `create_namespace('infobarshop')` + `create_table('pedidos')`, ainda vazia.
Prática: `tree` do warehouse (só `00000-….metadata.json`), `jq` nesse arquivo (schema com field IDs, `format-version`, `current-snapshot-id: null`) e `sqlite3` no catálogo (uma linha com `metadata_location`).
*Conceito:* as três camadas; o catálogo guarda só o ponteiro para o metadata.json atual.

**4. O primeiro commit: a árvore de metadados.** Carregar jan/2024.
Prática: descer a árvore um nível por vez. metadata.json → snapshot (`summary`: `added-records`) → **manifest list** (`snap-….avro`) → **manifest** (caminho do Parquet, `record_count`, min/max de `data_criacao` e `valor_unitario`) → **data file** (`parquet_metadata`).
*Conceito:* a hierarquia de metadados (diagrama Excalidraw, como no lab Cassandra). O leitor não lista a pasta: ele segue os ponteiros.

**5. Snapshots e commits atômicos.** Carregar fev e mar/2024.
Prática:
- a cada mês nasce um metadata.json novo, os antigos ficam intactos, e o ponteiro troca no SQLite;
- a manifest list do snapshot 3 reaproveita os manifests dos meses anteriores;
- duas cargas concorrentes (abril e um ajuste): a segunda falha com `CommitFailedException`, recarrega e tenta de novo (concorrência otimista).

*Conceito:* um commit é uma troca atômica de ponteiro, e isso resolve o 2.c.

**6. Time travel, rollback e tags.**
Prática:
- faturamento de jan/2024 "como estava" em cada snapshot (PyIceberg e `iceberg_scan` do DuckDB);
- tag `fechamento-2024-01`;
- uma carga errada (abril carregado duas vezes) desfeita com rollback.

*Conceito:* snapshots são imutáveis, e voltar no tempo é só apontar para outro. Isso resolve o 2.d.

### Parte II — Mudar sem reescrever

**7. Schema evolution e field IDs.** O sistema de origem muda: `uf` vira `estado` e aparece `canal` (APP/SITE).
Prática: renomear e adicionar coluna sem tocar nos Parquet antigos; o `field_id` aparece no schema do Parquet (`parquet_schema`); a consulta por `estado` traz os meses antigos e os novos. É o caso 2.a, agora funcionando.
*Conceito:* a identidade da coluna é um ID, não um nome.

**8. Hidden partitioning e pruning por estatísticas.** Recriar a tabela com `month(data_criacao)` e recarregar 2024.
Prática:
- a consulta filtra `data_criacao BETWEEN …` sem saber que existe partição;
- o manifest guarda os resumos de partição e o min/max;
- contar os data files lidos com o filtro e sem ele (plan files do PyIceberg, `EXPLAIN ANALYZE` do DuckDB).

*Conceito:* o leitor não precisa saber como a tabela é particionada. Liga com o min/max do Parquet e do ClickHouse dos outros labs.

**9. Partition evolution.** Novembro/2024 (Black Friday) tem o maior volume do ano, e o time decide particionar por dia daí em diante.
Prática: `update_spec()` para `day(data_criacao)`; os meses antigos continuam no spec 0 e os novos ficam no spec 1 (`spec_id` em cada manifest); a mesma consulta atravessa os dois.
*Conceito:* o particionamento é metadado, e trocá-lo não reescreve dados.

### Parte III — Atualizar dados imutáveis

**10. Delete, update e upsert (copy-on-write).**
Prática:
- upsert do `status` do pedido a partir de `dataset-json-pagamentos` (PAGO, CANCELADO);
- um cliente pede exclusão pela LGPD: `delete(id_cliente = …)`;
- ver quais Parquet foram reescritos e a `operation` de cada snapshot (`overwrite` / `delete`);
- surpresa: com time travel, os dados do cliente continuam acessíveis.

*Conceito:* os arquivos nunca mudam; o que muda é qual conjunto deles compõe o snapshot. Isso resolve o 2.b, mas abre a questão do esquecimento.

**11. Manutenção: o custo do histórico.** Simular uma carga "quase streaming", com um commit por hora de um dia de pedidos (24 commits pequenos).
Prática: medir os data files e os bytes de metadados; compactar; expirar snapshots (e confirmar que o cliente da LGPD sumiu de vez, fechando a seção 10); remover arquivos órfãos; medir de novo.
*Conceito:* small files, crescimento de metadados e retenção versus time travel.

**12. Um formato, vários motores (local).** A mesma tabela lida pelo DuckDB direto do metadata.json, sem catálogo, e pelo PyIceberg através do catálogo. Tipos de catálogo (SQL, REST, Glue, S3 Tables) e o papel de cada um.
Diagrama-síntese da Parte I à III.

### Parte IV — Na AWS

**13. Do disco local para o S3 com o Glue Data Catalog.** Tentar copiar o warehouse para o S3 e ver o metadata.json apontando para `file:///home/barbosa/...` (os caminhos são absolutos: uma tabela Iceberg não se move com `cp`). Fazer certo: PyIceberg com `GlueCatalog` + S3, carregando os pedidos de novo (a EC2 usa a LabRole).
Prática: a tabela aparece no console do Glue; o parâmetro `metadata_location` da tabela no Glue faz o mesmo papel da linha do SQLite; `aws s3 ls` mostra os mesmos `metadata/` e `data/`.

**14. Athena: outro motor, merge-on-read.** Consultar no Athena a tabela gravada pelo PyIceberg. Depois `UPDATE`, `DELETE` e `MERGE INTO` no Athena.
Prática:
- aparecem **delete files posicionais** no S3, e os data files não são reescritos;
- o aluno inspeciona os delete files com o DuckDB;
- o PyIceberg e o DuckDB leem a tabela com os deletes aplicados;
- `OPTIMIZE … REWRITE DATA` e `VACUUM` fazem a manutenção do lado do Athena.

*Conceito:* copy-on-write (seção 10) versus merge-on-read: trocar custo de escrita por custo de leitura. Visão geral: o lakehouse do infobarShop.

**15. Desafio.** **Referências.** **Apêndices** (execução local; limpeza dos recursos na AWS).

## 5. Resultado do spike local (2026-10-12)

Feito num container Ubuntu 24.04 arm64 com **PyIceberg 0.12.0** (+ `pyiceberg-core` 0.10.1), **pyarrow 26**, **DuckDB 1.5.6** (extensões `iceberg` e `avro`). Todas as seções 2 a 12 foram executadas de ponta a ponta com os dados reais do infobarShop.

| Seção | Resultado |
|---|---|
| 2. Parquet cru | ok. O glob quebra quando `uf` vira `estado` ("schema mismatch in glob"); com `union_by_name`, fevereiro vem com 0 `uf`. |
| 3. Catálogo | ok. `tree` mostra só o `00000-….metadata.json`; o `sqlite3` mostra a tabela `iceberg_tables` com `metadata_location` e `previous_metadata_location`. |
| 4. Árvore de metadados | ok. `read_avro` do DuckDB lê a manifest list e o manifest (os bounds ficam em binário; para mostrar min/max legível, usar `inspect.files()` → `readable_metrics`). `parquet_schema` mostra o `field_id`. |
| 5. Commits | ok, com um bônus: dois appends concorrentes **não** falham, porque o PyIceberg detecta o conflito, recarrega e refaz o commit (log "Commit failed due to a concurrent update, retrying"), e abril fica duplicado. Isso alimenta a seção 6 (rollback). Conflitos que falham de verdade: duas mudanças de schema (`CommitFailedException: current schema id has changed`) e dois deletes (`ValidationException`). |
| 6. Time travel | ok. `scan(snapshot_id=…)`, tag, `rollback_to_snapshot`; o DuckDB (`iceberg_scan` direto no metadata.json, com `snapshot_from_id`) respeita o rollback. |
| 7. Schema evolution | ok. O Parquet antigo continua com a coluna `uf` (`field_id` 6) e é lido como `estado`. |
| 8. Partições e pruning | ok. Filtro de um mês: 1 de 10 arquivos (`plan_files`); o `EXPLAIN ANALYZE` do DuckDB mostra `Total Files Read: 1`. As pastas `mes_criacao=…` aparecem no disco. |
| 9. Partition evolution | ok. Os specs 1 (month) e 2 (day) convivem; os manifests têm `partition_spec_id` diferente. |
| 10. Upsert / delete | ok em copy-on-write (o arquivo inteiro de janeiro é reescrito). O delete gera `operation=overwrite`, e o time travel ainda acha o cliente. **Bug do PyIceberg 0.12:** um `upsert` logo depois de um `add_column` falha (ele lê com o schema do snapshot atual). Contorno que vira narrativa: junho já chega com `status_pagamento` (append) e só depois o upsert preenche janeiro. |
| 11. Manutenção | ok. 24 commits de 94 linhas fazem os **metadados crescerem 600 KB e os dados, 65 KB**. Sem `rewrite_data_files` no PyIceberg, a compactação é um `overwrite` do mês (23 → 7 arquivos). O `expire_snapshots` **não apaga arquivos**: os pedidos do cliente da LGPD continuam em 2 Parquet órfãos, encontrados com o DuckDB. A remoção de órfãos fica num script do `lab.py` que compara o disco com `inspect.all_files()`. `write.metadata.delete-after-commit.enabled` limita os metadata.json antigos. |

Outros achados:
- **Dataset:** o gerador de pedidos só cria datas até o dia 28 de cada mês, então não existe 29/11/2024 (a Black Friday). O lab usa outro dia de novembro ou o problema é corrigido no gerador. A decidir.
- Os cabeçalhos dos CSVs vêm em maiúsculas e com `\r\n`; o `lab.py` normaliza.
- Peso: venv com PyIceberg + Glue = 390 MB, DuckDB + extensões = 125 MB. A imagem final deve ficar em torno de 1,2 GB.

### Pendente: a parte AWS (seções 13 e 14)

1. **AWS Academy (Learner Lab):** a LabRole consegue usar Glue e Athena (criar database e tabela, e gravar o resultado das consultas no S3)?
2. **Athena:** `UPDATE`/`DELETE`/`MERGE` geram delete files posicionais, e o PyIceberg e o DuckDB leem a tabela depois disso?

## 6. Em aberto

- Carga horária: 6 a 8 horas, com as 15 seções. Delta Lake e Hudi ficam para labs separados, sem comparativo.
