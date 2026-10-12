# Proposta — laboratório Apache Iceberg

Status: **proposta, aguardando aprovação**. Nada implementado ainda.

## 1. Iceberg sem Spark?

Sim. O Iceberg é uma **especificação de formato de tabela** (como os arquivos de metadados e de dados se organizam), não um motor nem um banco. Qualquer biblioteca que implemente a especificação lê e grava a tabela. O Spark é só a implementação mais completa (a de referência, em Java).

| | Sem Spark (PyIceberg + DuckDB) | Com Spark (spark-sql) |
|---|---|---|
| Peso da imagem / RAM | ~1 GB / poucos MB em repouso (não há servidor) | +600 MB de JVM e Spark / 1–2 GB de RAM por sessão |
| Interface | Python para escrever, SQL (DuckDB) para ler e inspecionar | Tudo em SQL |
| Atrito para o aluno | Baixo: arquivos locais, `tree`, `jq`, sem configuração de catálogo | Configuração verbosa do catálogo, stack traces Java, ~10 s para subir a sessão |
| Cobertura de recursos | Ampla (snapshots, time travel, schema e partition evolution, delete/overwrite/upsert copy-on-write, tags). Lacunas a confirmar no spike: merge-on-read e compactação | Completa (MERGE, merge-on-read, `CALL rewrite_data_files`, branches) |
| Aderência ao mercado | Média (PyIceberg e DuckDB crescem rápido) | Alta (EMR, Glue, Databricks) |
| Foco da aula | **Os arquivos em disco** | O motor |

**Recomendação: sem Spark na trilha principal.** Para uma aula sobre armazenamento, tirar o Spark tira justamente a camada que esconde os arquivos. Ficam de fora a JVM, a configuração e os erros que não têm a ver com o Iceberg. De quebra, isso mostra na prática a ideia central do formato: a mesma tabela é gravada por um motor (PyIceberg) e lida por outro (DuckDB). Se o Spark entrar, entra no fim, como "um terceiro motor lendo a mesma tabela".

O laboratório antigo (`data-eng-iceberg-demo`) usava Spark + REST + MinIO e era um passeio pelos recursos. Este segue a linha dos labs de armazenamento: abrir os arquivos e ver o que cada operação faz no disco.

## 2. Ambiente

Imagem `infobarbosa/iceberg-lab-docker-image`, no mesmo padrão das outras (Ubuntu 24.04, code-server em 8080 com `--auth none`, tini, usuário `barbosa`, multi-arch, CI no GHCR):

- **PyIceberg** (com pyarrow) num venv pré-instalado: é o motor de escrita.
- **Catálogo SQL em SQLite** (`SqlCatalog`): é um arquivo, não um servidor. O aluno abre com `sqlite3` e vê que o catálogo guarda só um ponteiro.
- **Warehouse no file system local** (`/home/barbosa/warehouse`), não em objeto (MinIO/S3), para o aluno poder rodar `tree`, `ls -l` e `jq` direto nos arquivos.
- **DuckDB CLI** com as extensões `iceberg`, `avro` e `parquet` pré-instaladas: é a lente SQL. `iceberg_scan`, `iceberg_snapshots` e `iceberg_metadata` leem a tabela; `read_json` lê o metadata.json, `read_avro` lê a manifest list e os manifests, e `parquet_metadata` lê os data files.
- `jq`, `sqlite3`, `tree`.

Não há banco para subir: o entrypoint só sobe o code-server. Em relação ao padrão "sem Python", aqui o Python é o próprio motor, e não um acessório.

Repo do tutorial: `iceberg-tableformat-demo` (público), com `launch-lab.sh`, `compose.yaml`, "Retomando o laboratório" e "Apêndice: Execução Local", seguindo os outros labs.

## 3. Roteiro: um conceito por vez

Cada seção segue o mesmo formato: **conceito → prática → "O que você deve conseguir responder"**. Cada seção reaproveita a tabela e os arquivos da anterior; nada é jogado fora. Subseções numeradas (`3.a`) e blocos rotulados (`# 3.b.1`).

### Parte I — Do arquivo à tabela

**1. Ambiente.** CloudShell + `launch-lab.sh`, code-server, "Retomando o laboratório".

**2. O problema: um data lake de Parquet "cru".** O DuckDB grava alguns Parquet numa pasta e consulta com glob (`*.parquet`).
Prática: (a) acrescentar um arquivo com uma coluna renomeada e ver a consulta quebrar ou trazer NULL; (b) apagar uma linha e descobrir que é preciso reescrever o arquivo; (c) um "escritor" no meio do caminho faz o leitor ver dados parciais; (d) "qual é a versão atual?" não tem resposta.
*Conceito:* sem um formato de tabela, a "tabela" é só uma convenção sobre uma pasta. Essa seção é a motivação de todo o resto, e cada problema volta a ser resolvido numa seção adiante.

**3. Iceberg é uma especificação: catálogo, metadados, dados.** Criar o catálogo e uma tabela vazia.
Prática: `tree` do warehouse (só `00000-….metadata.json`), `jq` nesse arquivo (schema, `format-version`, `current-snapshot-id: null`) e `sqlite3` no catálogo (uma linha com `metadata_location`).
*Conceito:* as três camadas; o catálogo guarda só o ponteiro para o metadata.json atual.

**4. O primeiro commit: a árvore de metadados.** Um `append`.
Prática: descer a árvore um nível por vez. metadata.json → snapshot → **manifest list** (`snap-….avro`, via `read_avro`) → **manifest** (`…-m0.avro`, com caminho, contagem de linhas e min/max por coluna) → **data file** (`parquet_metadata`).
*Conceito:* a hierarquia de metadados (diagrama Excalidraw, como no lab Cassandra). O leitor não lista a pasta: ele segue os ponteiros.

**5. Snapshots e commits atômicos.** Um segundo `append`.
Prática: um metadata.json novo e o antigo intacto; o ponteiro trocou no SQLite. Dois escritores concorrentes: o segundo commit falha com `CommitFailedException` e precisa recarregar e tentar de novo (concorrência otimista).
*Conceito:* um commit é uma troca atômica de ponteiro, e isso resolve o problema 2.c.

**6. Time travel, rollback e tags.**
Prática: consultar por `snapshot_id` e por timestamp (PyIceberg e `iceberg_scan` do DuckDB), fazer rollback para um snapshot anterior e criar uma tag `fechamento-mes`.
*Conceito:* snapshots são imutáveis, e "voltar no tempo" é só apontar para outro. Isso resolve o 2.d.

### Parte II — Mudar sem reescrever

**7. Schema evolution e field IDs.** Adicionar, renomear, remover e reordenar colunas.
Prática: os Parquet antigos ficam intactos, e o `field_id` aparece no schema do Parquet (`parquet_schema`). Repetir o caso 2.a e ver que agora ele funciona.
*Conceito:* a identidade da coluna é um ID, não um nome.

**8. Hidden partitioning e pruning por estatísticas.** Tabela particionada com transform (`day(ts)`, `bucket(n, id)`).
Prática: a consulta filtra por `ts` sem conhecer a coluna de partição; o manifest guarda os resumos de partição e o min/max; contar quantos arquivos são lidos com o filtro e sem ele.
*Conceito:* o leitor não precisa saber como a tabela é particionada. Liga com o min/max do Parquet e do ClickHouse dos outros labs.

**9. Partition evolution.** Mudar de `month` para `day` com a tabela já cheia.
Prática: os arquivos antigos continuam com o spec antigo (`spec_id` diferente em cada manifest) e a consulta atravessa os dois.
*Conceito:* o particionamento é metadado, e trocá-lo não reescreve dados.

### Parte III — Atualizar dados imutáveis

**10. Delete, update e upsert.**
Prática: um `delete` com filtro e um `upsert`; ver quais Parquet foram reescritos (copy-on-write) e a `operation` do snapshot (`delete`/`overwrite`). Depois, merge-on-read: delete files (posicionais / deletion vectors no v3). *O spike decide como mostrar isso sem Spark* (ver seção 5).
*Conceito:* os arquivos nunca mudam; o que muda é qual conjunto deles compõe o snapshot. Isso resolve o 2.b.

**11. Manutenção: o custo do histórico.** Cem appends pequenos.
Prática: medir arquivos e bytes de metadados; compactar; expirar snapshots; achar arquivos órfãos; medir de novo.
*Conceito:* small files, crescimento de metadados e retenção versus time travel.

### Parte IV — Visão geral

**12. Um formato, vários motores.** A mesma tabela lida pelo DuckDB, pelo PyIceberg e (opcional) por um terceiro motor. Tipos de catálogo (SQL, REST, Glue, S3 Tables), onde o Iceberg entra numa arquitetura lakehouse e um paralelo curto com Delta Lake e Hudi.
Diagrama-síntese que empilha tudo o que foi visto.

**13. Desafio.** **Referências.** **Apêndices** (execução local).

## 4. Interface do aluno com o PyIceberg

Proposta: blocos `python3 - <<'EOF' … EOF` copiáveis no terminal, mais um módulo `lab.py` pequeno, já na imagem, com `catalogo()` e `tabela()`, para não repetir a configuração do catálogo em todo bloco. Assim tudo continua num terminal com blocos rotulados, como nos outros labs. Alternativa: notebooks Jupyter no code-server (mais pesado e foge do padrão).

## 5. Riscos a verificar num spike (antes de escrever o README)

1. **Merge-on-read sem Spark.** O PyIceberg grava deletes em copy-on-write. O DuckDB grava delete files posicionais (desde a 1.4.2), mas só através de um catálogo REST. Opções: (a) mostrar o merge-on-read só lendo uma tabela pronta que vem na imagem; (b) acrescentar um catálogo REST leve; (c) aceitar apenas copy-on-write e explicar o merge-on-read no diagrama.
2. **Compactação e expire snapshots no PyIceberg** (versão atual, 0.11.x): confirmar o que já existe na API.
3. **`read_avro` do DuckDB** nos manifests do Iceberg (tipos aninhados) e `field_id` visível no `parquet_schema`.
4. Tamanho da imagem e RAM numa t3.medium; build em arm64.

## 6. Decisões que preciso de você

1. **Disciplina e carga horária**, para calibrar a profundidade (o lab Cassandra tinha 6 h).
2. **Domínio dos dados:** continuar no infobarBank (lançamentos de cartão como tabela analítica) ou usar pedidos/e-commerce (`datasets-csv-pedidos`, do lab antigo)?
3. **Interface:** heredoc + `lab.py` (recomendado) ou notebooks?
4. **Parte final na AWS** (S3 + Glue Catalog + Athena lendo a tabela), se o AWS Academy permitir: entra ou não?
5. **Nome do repo:** `iceberg-tableformat-demo` (escolhido) ou outro, como `iceberg-lakehouse-demo`.
