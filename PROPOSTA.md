# Proposta — laboratório Apache Iceberg

Status: **aprovada em 2026-10-12, em implementação**. Spike local e AWS concluídos (seção 5); dados trocados para o Olist.

| Decisão | Escolha |
|---|---|
| Disciplina | Engenharia de Dados, bloco de Open Table Formats (OTF) |
| Domínio | Olist (Brazilian E-Commerce Public Dataset, dados reais, CC BY-NC-SA 4.0), via `infobarbosa/dataset-olist` |
| Interface | blocos copiáveis para o terminal (heredoc + `lab.py` de apoio) |
| Carga horária | 6 a 8 horas. Delta Lake e Hudi ficam em labs próprios, sem comparativo |
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
- **`lab.py`**: módulo de apoio com `catalogo()`, `tabela()`, `pedidos_novos('2017-01')`, `mudancas('2017-02')`, `produtos()` e `mostra()`. Ele baixa os CSVs do `dataset-olist` uma vez (cache em `~/dados`) e devolve tabelas Arrow. Assim cada bloco do README tem poucas linhas e mostra só o que importa. A derivação mensal (seção 3 abaixo) fica em SQL legível dentro do `lab.py`, para o aluno poder abrir e entender.
- `jq`, `sqlite3`, `tree`, `aws` CLI.

Não há banco para subir: o entrypoint só sobe o code-server.

## 3. Dados: Olist

[Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce): cerca de 100 mil pedidos reais (anonimizados) de marketplaces brasileiros, de 2016 a 2018, em 9 tabelas. A cópia em `infobarbosa/dataset-olist` (público, com atribuição e licença) existe para o lab baixar por curl, sem login no Kaggle. A licença é não comercial (uso em aula).

Tabelas do lab, com os nomes de colunas originais em inglês:
- **`olist.orders`** (principal): `order_id`, `customer_id`, `order_status`, `order_purchase_timestamp`, `order_approved_at`, `order_delivered_carrier_date`, `order_delivered_customer_date`, `order_estimated_delivery_date`.
- **`olist.products`** (apoio, seção 7): 32.951 produtos, com o erro de digitação original `product_name_lenght`.
- Ficam para o Desafio: `order_items`, `order_payments`, `order_reviews` e `customers`.

**A carga mensal reconstrói o ciclo de vida do pedido.** As datas de compra, aprovação, transportadora e entrega permitem montar o estado de cada pedido no fim de cada mês. A carga de um mês traz os pedidos novos e os pedidos antigos que mudaram de status. Números reais, de jan/2017 a ago/2018 (20 meses):

| | novos por mês | atualizados por mês |
|---|---|---|
| 2017 (jan–out) | 800 a 4.631 | 0 a 1.575 |
| nov/2017 | **7.544** (Black Friday em 24/11: **1.176 pedidos num dia**, cerca de 3 vezes o normal) | 1.560 |
| dez/2017 | 5.673 | **4.019** (as entregas da Black Friday) |
| 2018 (jan–ago) | 6.167 a 7.269 | 1.687 a 3.698 |

Uma simplificação, a explicar no README: `canceled` e `unavailable` não têm data, então o status final entra no mês do último evento conhecido do pedido.

**Progressão:** nas Partes I e II, a carga mensal só faz append dos **pedidos novos**. Na Parte III vem a revelação: o pedido de janeiro foi entregue em fevereiro, e a tabela continua dizendo `approved`. A partir daí, a carga mensal vira um **upsert** das mudanças.

**LGPD:** o cliente real é o `customer_unique_id` (tabela `customers`); 2.997 clientes têm mais de um pedido, cada um com um `customer_id` diferente. Apagar um cliente vira um `delete` com `In(customer_id, [...])`.

## 4. Roteiro: um conceito por vez

Cada seção segue o mesmo formato: **conceito → prática → "O que você deve conseguir responder"**. Cada seção reaproveita a tabela e os arquivos da anterior. Subseções numeradas (`3.a`) e blocos rotulados (`# 3.b.1`).

### Parte I — Do arquivo à tabela

**1. Ambiente.** CloudShell + `launch-lab.sh`, code-server, "Retomando o laboratório".

**2. O problema: um data lake de Parquet "cru".** O DuckDB grava os pedidos de jan a mar/2017 em `lake/orders/` (um Parquet por mês) e duas exportações de produtos em `lake/products/`, e consulta com glob.
Prática:
- (a) o time de cadastro corrige `product_name_lenght` para `product_name_length` na exportação nova, e o glob quebra (ou, com `union_by_name`, metade dos produtos vem com NULL);
- (b) um pedido de janeiro foi entregue: atualizar uma linha obriga a reescrever o Parquet do mês inteiro;
- (c) um relatório roda enquanto a carga de abril ainda está gravando e conta um mês pela metade;
- (d) "quantos pedidos tínhamos no fechamento de fevereiro?" não tem resposta.

*Conceito:* sem um formato de tabela, a "tabela" é só uma convenção sobre uma pasta. Cada um desses quatro problemas volta a ser resolvido numa seção adiante.

**3. Iceberg é uma especificação: catálogo, metadados, dados.** `create_namespace('olist')` + `create_table('orders')`, ainda vazia.
Prática: `tree` do warehouse (só `00000-….metadata.json`), `jq` nesse arquivo (schema com field IDs, `format-version`, `current-snapshot-id: null`) e `sqlite3` no catálogo (uma linha com `metadata_location`).
*Conceito:* as três camadas; o catálogo guarda só o ponteiro para o metadata.json atual.

**4. O primeiro commit: a árvore de metadados.** Carregar os pedidos novos de jan/2017.
Prática: descer a árvore um nível por vez. metadata.json → snapshot (`summary`: `added-records`) → **manifest list** (`snap-….avro`) → **manifest** (caminho do Parquet, `record_count`, min/max de `order_purchase_timestamp`) → **data file** (`parquet_metadata`, `parquet_schema` com `field_id`).
*Conceito:* a hierarquia de metadados (diagrama Excalidraw, como no lab Cassandra). O leitor não lista a pasta: ele segue os ponteiros.

**5. Snapshots e commits atômicos.** Carregar fev e mar/2017.
Prática:
- a cada mês nasce um metadata.json novo, os antigos ficam intactos, e o ponteiro troca no SQLite;
- a manifest list do snapshot 3 reaproveita os manifests dos meses anteriores;
- duas cargas de abril disparadas ao mesmo tempo: o segundo commit detecta o conflito, recarrega e entra também (log "retrying"), e abril fica duplicado;
- duas mudanças de schema concorrentes: aí o commit falha de verdade (`CommitFailedException`).

*Conceito:* um commit é uma troca atômica de ponteiro com concorrência otimista. Isso resolve o 2.c.

**6. Time travel, rollback e tags.**
Prática:
- contagem de pedidos de jan/2017 "como estava" em cada snapshot (PyIceberg e `iceberg_scan` do DuckDB);
- tag `fechamento-2017-03`;
- abril duplicado (seção 5) desfeito com rollback.

*Conceito:* snapshots são imutáveis, e voltar no tempo é só apontar para outro. Isso resolve o 2.d.

### Parte II — Mudar sem reescrever

**7. Schema evolution e field IDs.** Tabela `olist.products`.
Prática:
- corrigir `product_name_lenght` e `product_description_lenght` com rename, sem tocar nos Parquet;
- adicionar `product_category_name_english` (da tabela de tradução);
- o `field_id` no `parquet_schema` explica por que o arquivo antigo, ainda com "lenght", é lido com o nome novo. É o caso 2.a, agora funcionando;
- `sqlite3` mostra duas tabelas no mesmo namespace.

*Conceito:* a identidade da coluna é um ID, não um nome.

**8. Hidden partitioning e pruning por estatísticas.** Recriar `orders` com `month(order_purchase_timestamp)` e carregar 2017 (até outubro).
Prática:
- a consulta filtra por data de compra sem saber que existe partição;
- o manifest guarda os resumos de partição e o min/max;
- contar os data files lidos com o filtro e sem ele (`plan_files` do PyIceberg, `Total Files Read` no `EXPLAIN ANALYZE` do DuckDB).

*Conceito:* o leitor não precisa saber como a tabela é particionada. Liga com o min/max do Parquet e do ClickHouse dos outros labs.

**9. Partition evolution.** Vem novembro: a Black Friday de 24/11/2017 tem 1.176 pedidos num dia só, e as análises passam a ser por dia. O time muda o particionamento para `day(order_purchase_timestamp)` dali em diante.
Prática: `update_spec()`; out/2017 para trás continua no spec mensal e nov/dez no spec diário (`partition_spec_id` em cada manifest); a consulta da semana da Black Friday lê só os arquivos diários daquela semana; uma consulta de 2017 inteiro atravessa os dois specs.
*Conceito:* o particionamento é metadado, e trocá-lo não reescreve dados.

### Parte III — Atualizar dados imutáveis

**10. Upsert e delete (copy-on-write).** A revelação: o pedido de jan/2017 foi entregue em fevereiro, e a tabela continua dizendo `approved`.
Prática:
- a carga mensal vira `upsert` das mudanças (`mudancas('2017-12')`: 5.673 novos e 4.019 atualizados);
- ver quais Parquet foram reescritos e a `operation` dos snapshots;
- um cliente pede exclusão pela LGPD: `delete` dos pedidos de todos os `customer_id` dele;
- surpresa: com time travel, os pedidos do cliente continuam acessíveis.

*Conceito:* os arquivos nunca mudam; o que muda é qual conjunto deles compõe o snapshot. Isso resolve o 2.b, mas abre a questão do esquecimento.

**11. Manutenção: o custo do histórico.** Acompanhamento "em tempo real" da Black Friday: os pedidos de 24/11/2017 carregados hora a hora (24 commits pequenos).
Prática:
- medir os data files e os bytes de metadados;
- compactar (overwrite do dia);
- expirar snapshots e descobrir que os pedidos do cliente da LGPD **continuam no disco** em Parquet órfãos (achados com o DuckDB);
- remover os órfãos e medir de novo.

*Conceito:* small files, crescimento de metadados, retenção versus time travel, e a diferença entre "fora da tabela" e "fora do disco".

**12. Um formato, vários motores (local).** A mesma tabela lida pelo DuckDB direto do metadata.json, sem catálogo, e pelo PyIceberg através do catálogo. Tipos de catálogo (SQL, REST, Glue, S3 Tables) e o papel de cada um.
Diagrama-síntese da Parte I à III.

### Parte IV — Na AWS

**13. Do disco local para o S3 com o Glue Data Catalog.** Tentar copiar o warehouse para o S3 e ver o metadata.json apontando para `file:///home/barbosa/...` (os caminhos são absolutos: uma tabela Iceberg não se move com `cp`). Fazer certo: PyIceberg com `GlueCatalog` + S3, carregando 2017 de novo (a EC2 usa a LabRole).
Prática: a tabela aparece no console do Glue; o parâmetro `metadata_location` da tabela no Glue faz o mesmo papel da linha do SQLite; `aws s3 ls` mostra os mesmos `metadata/` e `data/`.

**14. Athena: outro motor, merge-on-read.** Consultar no Athena a tabela gravada pelo PyIceberg. Depois, a carga mensal em SQL: `MERGE INTO orders USING mudancas_2018_01` (uma tabela de staging gravada pelo PyIceberg); um `DELETE` da LGPD.
Prática:
- aparecem **delete files posicionais** no S3, e os data files não são reescritos;
- o aluno lê um delete file com o DuckDB: pares (`file_path`, `pos`);
- PyIceberg, DuckDB e Athena dão o mesmo resultado;
- `OPTIMIZE … REWRITE DATA` incorpora os deletes, e o `VACUUM` apaga os arquivos de verdade (contraste com a seção 11).

*Conceito:* copy-on-write (seção 10) versus merge-on-read: trocar custo de escrita por custo de leitura. Visão geral: o lakehouse que juntou tudo.

**15. Desafio** (com `order_items` e `order_payments`: faturamento por categoria, com uma mudança de schema e uma consulta de time travel). **Referências.** **Apêndices** (execução local; limpeza dos recursos na AWS).

## 5. Resultado do spike local (2026-10-12)

Feito num container Ubuntu 24.04 arm64 com **PyIceberg 0.12.0** (+ `pyiceberg-core` 0.10.1), **pyarrow 26**, **DuckDB 1.5.6** (extensões `iceberg` e `avro`). Todas as seções 2 a 12 foram executadas de ponta a ponta com o dataset infobarShop (antes da troca para o Olist; a mecânica do Iceberg não depende do dataset, mas os comandos serão revalidados com o Olist na implementação).

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
- **Dataset:** o gerador do infobarShop só cria datas até o dia 28 de cada mês (não existe Black Friday). Esse foi um dos motivos da troca para o Olist.
- Peso: venv com PyIceberg + Glue = 390 MB, DuckDB + extensões = 125 MB. A imagem final deve ficar em torno de 1,2 GB.

### Spike AWS (2026-10-12, numa conta real do AWS Academy)

Testado de um venv local com o perfil do Learner Lab (role `voclabs`). Na EC2 do lab, as credenciais vêm do `LabInstanceProfile`, que o `launch-lab.sh` já anexa.

| Seção | Resultado |
|---|---|
| 13. Glue + S3 | ok. `GlueCatalog(client.region=us-east-1)`; a tabela no Glue é `EXTERNAL_TABLE` com `table_type=ICEBERG`, `metadata_location` e `previous_metadata_location`, o mesmo papel da linha do SQLite. O S3 mostra `data/mes_criacao=…/` e `metadata/`, como no disco local. Três commits levaram 28 s saindo do Brasil; na EC2 deve ser bem menos. Detalhe: o spec de partição é criado com `update_spec()` depois do `create_table`, porque o schema Arrow não tem field IDs. |
| 14. Athena lê | ok. O faturamento por mês bate com o do lab local, e `"pedidos$snapshots"` mostra os appends do PyIceberg. |
| 14. Athena escreve (merge-on-read) | ok. `DELETE` grava **position delete files** (`added-position-delete-files=2`), e o Parquet original fica intacto (mesmos bytes). `UPDATE` e `MERGE` geram um delete posicional mais um data file novo. O DuckDB lê o delete file como pares (`file_path`, `pos`). |
| 14. Três motores concordam | ok. Athena, PyIceberg e DuckDB (`CREATE SECRET … PROVIDER credential_chain`) dão o mesmo resultado (4.996 linhas, soma 7.702), com os deletes aplicados. |
| 14. Manutenção | ok. `OPTIMIZE … REWRITE DATA USING BIN_PACK` incorpora os deletes (`operation=replace`, 0 delete files). `VACUUM` expira os snapshots **e apaga os arquivos do S3**, ao contrário do `expire_snapshots` do PyIceberg. Isso fecha a narrativa da LGPD. |

Detalhes para o README: o workgroup `primary` precisa de `OutputLocation` (um bucket de resultados criado pelo lab). Para a demonstração, o `VACUUM` precisa de `vacuum_max_snapshot_age_seconds` baixo (o padrão é 5 dias). Os recursos do spike (bucket, database e tabela) foram apagados.

## 6. Próximos passos

1. `iceberg-lab-docker-image` (privado): `main` mínima + branch `versao-inicial`, CI multi-arch.
2. `lab.py` com a derivação mensal do Olist e o README do `iceberg-tableformat-demo` numa branch, com todos os comandos validados num container limpo e a parte AWS validada no Academy.
