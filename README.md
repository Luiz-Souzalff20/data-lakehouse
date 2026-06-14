# Data Lakehouse

Projeto de engenharia de dados containerizado, com arquitetura medalhão (bronze, prata, ouro) para ingestão de dados de APIs públicas e bancos de dados, processamento via Spark/Jupyter, armazenamento em formato Iceberg (Parquet) sobre object storage S3-compatible, e consulta via Trino.

## Visão Geral da Arquitetura

```
                ┌──────────────┐
                │  APIs / DBs  │
                │   externas   │
                └──────┬───────┘
                       │
                       ▼
            ┌─────────────────────┐
            │  Jenkins (orquestra) │
            │  executa .ipynb via  │
            │  Spark (Jupyter)     │
            └──────────┬───────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼               ▼              ▼
    ┌────────┐     ┌─────────┐    ┌─────────┐
    │ Bronze │ --> │  Prata  │ -->│  Ouro   │
    │ (raw)  │     │(cleaned)│    │ (agg.)  │
    └────────┘     └─────────┘    └────┬────┘
        │               │               │
        └──── MinIO (S3) + Iceberg ─────┘
                       │
                       ▼
                  ┌─────────┐
                  │  Trino  │ ── consulta Bronze e Prata
                  └────┬────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
         ┌─────────┐      ┌──────────┐
         │ DBeaver │      │ Metabase │ (futuro)
         └─────────┘      └──────────┘

   Camada Ouro -> exportada para Postgres (banco analítico)
                          │
                          ▼
                     ┌──────────┐
                     │ Grafana  │ (futuro)
                     └──────────┘
```

**Catálogo Iceberg**: metastore JDBC compartilhado no Postgres, usado tanto pelo Spark (escrita) quanto pelo Trino (leitura).

## Camadas (Medalhão)

| Camada | Conteúdo | Formato | Acesso |
|---|---|---|---|
| **Bronze** | Dados brutos, sem transformação, espelho da fonte (API/DB) | Iceberg (Parquet) | Spark (escrita), Trino (leitura) |
| **Prata** | Dados limpos, tipados, deduplicados, com regras de qualidade | Iceberg (Parquet) | Spark (escrita), Trino (leitura) |
| **Ouro** | Dados agregados/modelados para consumo analítico | Tabelas Postgres | Spark/Trino (escrita), Metabase/Grafana (leitura) |

## Stacks

| Stack | Função | Status |
|---|---|---|
| `minio` | Object storage S3-compatible (warehouse Iceberg) | ✅ |
| `postgres` | Metastore JDBC do Iceberg + banco da camada Ouro | ✅ |
| `trino` | Engine de consulta SQL sobre Iceberg (Bronze/Prata) | ✅ |
| `spark-jupyter` | Notebooks Spark para ETL (extração, transformação, carga) | ✅ |
| `jenkins` | Orquestração: agenda e executa os notebooks `.ipynb` | ✅ |
| `dbeaver` | Cliente SQL para consulta via Trino/Postgres | ✅ |
| `metabase` | Dashboards e BI sobre a camada Ouro | 🔜 |
| `grafana` | Monitoramento e dashboards operacionais | 🔜 |

## Estrutura de Pastas

```
Data-Lakehouse
├── portainer-stacks
│   ├── dbeaver
│   │   └── dbeaver.yml
│   ├── jenkins
│   │   └── jenkins.yml
│   ├── minio
│   │   └── minio.yml
│   ├── postgres
│   │   └── postgres.yml
│   ├── spark-jupyter
│   │   ├── spark-jupyter.yml
│   │   └── notebooks
│   │       └── extracao_spark.ipynb
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

> O mesmo catálogo (`catalog-name=lakehouse`) e o mesmo `warehouse-dir` devem ser usados na configuração do Spark, garantindo que ambos leiam/escrevam nas mesmas tabelas.

## Subindo as Stacks

Cada stack é independente e deve ser implantada via Portainer (ou `docker compose`) na ordem abaixo, respeitando dependências:

```bash
# 1. Rede compartilhada
docker network create lakehouse

# 2. Infraestrutura base
docker compose -f portainer-stacks/minio/minio.yml up -d
docker compose -f portainer-stacks/postgres/postgres.yml up -d

# 3. Processamento
docker compose -f portainer-stacks/spark-jupyter/spark-jupyter.yml up -d

# 4. Consulta
docker compose -f portainer-stacks/trino/trino.yml up -d

# 5. Clientes / orquestração
docker compose -f portainer-stacks/dbeaver/dbeaver.yml up -d
docker compose -f portainer-stacks/jenkins/jenkins.yml up -d
```

## Fluxo de ETL

1. **Extração (Bronze)**: notebook Spark consome API pública ou banco de dados externo e grava os dados crus em `iceberg.bronze.<tabela>`, usando `MERGE INTO` para cargas incrementais (upsert por chave de negócio).
2. **Transformação (Prata)**: notebook Spark lê a Bronze, aplica limpeza, tipagem, deduplicação e regras de qualidade, gravando em `iceberg.prata.<tabela>`.
3. **Agregação (Ouro)**: notebook Spark lê a Prata, aplica agregações/modelagem analítica e grava em tabelas Postgres (banco da camada Ouro).
4. **Orquestração**: Jenkins agenda e executa os notebooks `.ipynb` em sequência (Bronze → Prata → Ouro), via job pipeline.
5. **Consulta**: Trino expõe Bronze e Prata para consulta ad-hoc via DBeaver. A camada Ouro é consultada diretamente no Postgres (futuramente via Metabase/Grafana).

## Exemplo: Carga Incremental (Bronze)

```python
# MERGE INTO garante upsert: registros existentes são atualizados,
# novos registros são inseridos — sem duplicar e sem reprocessar tudo.
spark.sql("""
MERGE INTO lakehouse.bronze.posts_api AS target
USING posts_staging AS source
ON target.id = source.id
WHEN MATCHED THEN UPDATE SET
    target.userId = source.userId,
    target.title = source.title,
    target.body = source.body,
    target.data_carga = source.data_carga
WHEN NOT MATCHED THEN INSERT (userId, id, title, body, data_carga)
VALUES (source.userId, source.id, source.title, source.body, source.data_carga)
""")
```

## Verificando o Pipeline

```sql
-- Via Trino
SHOW SCHEMAS FROM iceberg;
SELECT * FROM iceberg.bronze.posts_api LIMIT 10;

-- Histórico de snapshots (Iceberg)
SELECT * FROM iceberg.bronze."posts_api$history";
```

## Próximos Passos

- [ ] Migrar a orquestração de containers para **Docker Swarm**
- [ ] Implementar camada **Prata** com regras de qualidade e deduplicação
- [ ] Implementar camada **Ouro** com export para Postgres
- [ ] Adicionar stack **Metabase** para dashboards sobre a camada Ouro
- [ ] Adicionar stack **Grafana** para monitoramento operacional
- [ ] Configurar jobs Jenkins para execução agendada dos notebooks (Bronze → Prata → Ouro)
- [ ] Adicionar testes de qualidade de dados (ex: Great Expectations) entre camadas

## Notas de Segurança

- Credenciais (Postgres, MinIO) devem ser gerenciadas via `.env` e **nunca** versionadas em texto puro nos arquivos `.properties`/`.yml`.
- Avaliar uso de Docker Secrets ao migrar para Docker Swarm.