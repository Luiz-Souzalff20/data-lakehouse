# Data Lakehouse

Projeto de engenharia de dados containerizado, com arquitetura medalhão (bronze, prata, ouro) para ingestão de dados de APIs públicas e bancos de dados, processamento via Spark/Jupyter, armazenamento em formato Iceberg (Parquet) sobre object storage S3-compatible, e consulta via Trino.

## Visão Geral da Arquitetura

![Arquitetura](./.assets/pipeline_data_lakehouse.png)

**Catálogo Iceberg**: metastore JDBC compartilhado no Postgres (`metastore`), usado tanto pelo Spark (escrita) quanto pelo Trino (leitura).

**Orquestração**: o Jenkins é o ponto central de execução do pipeline. Cada etapa do ETL (Bronze, Prata, Ouro, Carga Postgres) é um **job Jenkins independente**, que executa o respectivo notebook `.ipynb` (via `papermill` ou `jupyter nbconvert --execute`) no container Spark/Jupyter. Os jobs são encadeados (Job 1 → Job 2 → Job 3 → Job 4), formando uma pipeline sequencial — sem execução manual dos notebooks.

## Camadas (Medalhão)

| Camada | Conteúdo | Formato | Notebook responsável | Acesso |
|---|---|---|---|---|
| **Bronze** | Dados brutos, sem transformação, espelho da fonte (API/DB) | Iceberg (Parquet) | `01_extracao_bronze.ipynb` | Spark (escrita), Trino (leitura) |
| **Prata** | Dados limpos, tipados, deduplicados, com regras de qualidade | Iceberg (Parquet) | `02_tratamento_prata.ipynb` | Spark (escrita), Trino (leitura) |
| **Ouro** | Tabelas dimensionais e fato (modelo estrela) | Iceberg (Parquet) | `03_modelagem_ouro.ipynb` | Spark (escrita), Trino (leitura) |
| **Ouro -> Postgres** | Export das tabelas Ouro para banco analítico | Tabelas Postgres | `04_carga_postgres.ipynb` | Spark (escrita), Metabase/Grafana (leitura) |

> Todas as camadas (incluindo Ouro) são gravadas primeiro em Iceberg/MinIO, garantindo versionamento, consulta via Trino e histórico de snapshots. A camada Ouro é, em seguida, **replicada para o Postgres** (Job 4) para consumo por ferramentas de BI tradicionais.

## Stacks

| Stack | Função | Status |
|---|---|---|
| `minio` | Object storage S3-compatible (warehouse Iceberg: bronze, prata, ouro) | ✅ |
| `postgres` | Metastore JDBC do Iceberg + banco analítico (`analytics`) da camada Ouro | ✅ |
| `trino` | Engine de consulta SQL sobre Iceberg (Bronze, Prata e Ouro) | ✅ |
| `spark-jupyter` | Notebooks Spark para ETL (extração, transformação, modelagem, carga) | ✅ |
| `jenkins` | **Orquestrador**: agenda e executa os notebooks `.ipynb` em sequência | ✅ |
| `dbeaver` | Cliente SQL para consulta via Trino/Postgres | ✅ |
| `metabase` | Dashboards e BI sobre a camada Ouro (Postgres) | ✅ |
| `grafana` | Monitoramento e dashboards operacionais | ✅ |

## Estrutura de Pastas

```
Data-Lakehouse
├── portainer-stacks
│   ├── dbeaver
│   │   └── dbeaver.yml
│   ├── grafana
│   │   └── grafana.yml
│   ├── jenkins
│   │   ├── jenkins.yml
│   │   └── comandos
│   │       ├── comandos.txt
│   ├── metabase
│   │   └── metabase.yml
│   ├── minio
│   │   └── minio.yml
│   ├── postgres
│   │   └── postgres.yml
│   ├── spark-jupyter
│   │   ├── spark-jupyter.yml
│   │   └── notebooks
│   │       ├── 01_extracao_bronze.ipynb
│   │       ├── 02_tratamento_prata.ipynb
│   │       ├── 03_modelagem_ouro.ipynb
│   │       └── 04_carga_postgres.ipynb
│   └── trino
│       ├── trino.yml
│       └── catalog
│           └── iceberg.properties
├── create-project.sh
├── portainer.yml
└── .env
```

## Pré-requisitos

- Docker + Docker Compose
- Rede Docker externa `lakehouse`:
  ```bash
  docker network create lakehouse
  ```

## Configuração do Catálogo Iceberg (Trino)

O catálogo Iceberg usa o tipo `jdbc`, com metastore no Postgres e storage no MinIO:

```properties
connector.name=iceberg
iceberg.catalog.type=jdbc
iceberg.jdbc-catalog.catalog-name=lakehouse
iceberg.jdbc-catalog.driver-class=org.postgresql.Driver
iceberg.jdbc-catalog.connection-url=jdbc:postgresql://postgres:5432/metastore
iceberg.jdbc-catalog.connection-user=<usuario>
iceberg.jdbc-catalog.connection-password=<senha>
iceberg.jdbc-catalog.default-warehouse-dir=s3://lakehouse/warehouse

fs.native-s3.enabled=true
s3.endpoint=http://minio:9000
s3.region=us-east-1
s3.path-style-access=true
s3.aws-access-key=<access-key>
s3.aws-secret-key=<secret-key>
```

> O mesmo catálogo (`catalog-name=lakehouse`) e o mesmo `warehouse-dir` devem ser usados na configuração do Spark (dentro dos notebooks), garantindo que Spark e Trino leiam/escrevam nas mesmas tabelas.

## Subindo as Stacks

Cada stack é independente e deve ser implantada via Portainer (ou `docker compose`) na ordem abaixo, respeitando dependências:

```bash
# Comandos para criação do ambiente e configuração
sudo bash ./data-lakehouse/portainer-stacks/create-project.sh
```

## Fluxo de ETL (orquestrado pelo Jenkins)

O Jenkins é o **gatilho de todo o pipeline**. Nenhum notebook é executado manualmente — cada etapa abaixo corresponde a um job Jenkins, executado em sequência (cada job dispara o próximo ao terminar com sucesso):

1. **Job 1 — Extração (Bronze)**: executa `01_extracao_bronze.ipynb`. Consome a API pública, grava dados crus em `lakehouse.bronze.data_api` via `MERGE INTO` (upsert por `id`), local `s3a://lakehouse/bronze/data_api`.

2. **Job 2 — Tratamento (Prata)**: executa `02_tratamento_prata.ipynb`. Lê a Bronze, aplica limpeza, padronização de tipos/strings, deduplicação e validações de qualidade, grava em `lakehouse.prata.data_api` via `MERGE INTO`, local `s3a://lakehouse/prata/data_api`.

3. **Job 3 — Modelagem (Ouro)**: executa `03_modelagem_ouro.ipynb`. Lê a Prata, monta o modelo estrela (`tab_dim_produto`, `tab_dim_categoria`, `tab_dim_data`, `tab_fato_vendas`) e grava em Iceberg em `s3a://lakehouse/ouro/tab_dim_vendas/...` e `s3a://lakehouse/ouro/tab_fato_vendas`.

4. **Job 4 — Carga Postgres**: executa `04_carga_postgres.ipynb`. Lê as tabelas Ouro (Iceberg) e replica para o Postgres (database `analytics`, schema `ouro`), via JDBC, para consumo por BI.

### Execução dos notebooks pelo Jenkins

Cada job Jenkins executa o respectivo `.ipynb` de forma não interativa dentro do container Jupyter com o comando:

```bash
docker exec -it jupyter \
/opt/conda/bin/jupyter nbconvert \
--to notebook \
--execute \
--inplace \
/home/jovyan/work/01_extracao_bronze.ipynb
```

O notebook executado (com outputs/logs de cada célula) é salvo em `notebooks/output/`, servindo como registro de execução/auditoria do job.

### Encadeamento dos jobs

No Jenkins, configure os jobs com **"Build after other projects are built"** (ou, em pipeline declarativa, um `Jenkinsfile` único orquestrando os 4 estágios):

```groovy
Segue os comando para as pipelines:
- ./data-lakehouse/portainer-stacks/stacks/jenkins/comandos/comandos.txt
```

Cada `stage` só inicia se o anterior terminar com sucesso — se o Job 1 falhar (ex: API indisponível), os jobs 2-4 não são executados, evitando processar dados parciais/corrompidos.

### Agendamento

O Jenkins pode disparar a pipeline completa por um trigger `cron` (ex: diário):

```groovy
triggers {
    cron('0 6 * * *')  // todos os dias às 06:00
}
```

## Consulta (Trino)

Trino expõe Bronze, Prata e Ouro para consulta ad-hoc via DBeaver:

```sql
-- Schemas disponíveis
SHOW SCHEMAS FROM iceberg;

-- Camada Bronze (dados crus)
SELECT * FROM iceberg.bronze.data_api LIMIT 10;

-- Camada Prata (dados tratados)
SELECT * FROM iceberg.prata.data_api LIMIT 10;

-- Camada Ouro (modelo dimensional)
SELECT * FROM iceberg.ouro.tab_dim_produto LIMIT 10;
SELECT * FROM iceberg.ouro.tab_fato_vendas LIMIT 10;

-- Histórico de snapshots (Iceberg)
SELECT * FROM iceberg.bronze."data_api$history";
```

A camada Ouro também é consultável diretamente no Postgres (`analytics.ouro.*`), após o Job 4, via Metabase/Grafana.

## Próxima Feature

A próxima etapa do projeto é **migrar a orquestração de containers para Docker Swarm**, substituindo os deploys individuais via Portainer/Compose por stacks gerenciadas em modo Swarm (`docker stack deploy`), com os benefícios de orquestração nativa: réplicas, rolling updates, Docker Secrets para credenciais, overlay networks e healthchecks integrados.

## Próximos Passos

- [ ] Migrar a orquestração de containers para **Docker Swarm**
- [ ] Adicionar testes de qualidade de dados (ex: Great Expectations) entre camadas, como etapa dos jobs
- [ ] Configurar notificações do Jenkins (e-mail/Slack) em caso de falha de algum job
- [ ] Adicionar uma nova stack para o OpenMetadata, para governança e observabilidade de dados

## Notas de Segurança

- Credenciais (Postgres, MinIO) devem ser gerenciadas via `.env`/credenciais do Jenkins, e **nunca** versionadas em texto puro nos arquivos `.properties`/`.yml`/notebooks.
- Avaliar uso de Docker Secrets ao migrar para Docker Swarm.
- Os jobs Jenkins devem usar credenciais armazenadas no **Credentials Manager** do próprio Jenkins, injetadas como variáveis de ambiente nos notebooks (evitar hardcode de senhas nos `.ipynb`).