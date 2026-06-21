#!/usr/bin/env bash
# =============================================================================
# Lakehouse Setup — Inicialização completa da infraestrutura
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
log()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

compose_up() {
  local file="$1"
  log "Subindo stack: $file"
  docker compose -f "$file" up -d
  ok "$file iniciado."
}

# =============================================================================
# 1. REDE
# =============================================================================
log "Criando rede Docker 'lakehouse'..."
docker network inspect lakehouse &>/dev/null \
  && warn "Rede 'lakehouse' já existe — pulando." \
  || { docker network create lakehouse && ok "Rede criada."; }

# =============================================================================
# 2. PORTAINER (gerenciamento de containers)
# =============================================================================
compose_up "portainer.yml"

# =============================================================================
# 3. POSTGRESQL
# =============================================================================
compose_up "/stacks/postgres/postgres.yml"

log "Aguardando PostgreSQL ficar pronto..."
until docker exec postgres pg_isready -U dba_admin -q; do
  sleep 2
done
ok "PostgreSQL pronto."

log "Criando banco de dados 'db_ecommerce'..."
docker exec postgres psql -U dba_admin \
  -c "SELECT 1 FROM pg_database WHERE datname='db_ecommerce';" \
  | grep -q 1 \
  && warn "Banco 'db_ecommerce' já existe — pulando." \
  || { docker exec postgres psql -U dba_admin \
        -c "CREATE DATABASE db_ecommerce;" && ok "Banco criado."; }

log "Criando tabelas de metadados Iceberg no banco 'metastore'..."
docker exec -i postgres psql -U dba_admin -d metastore << 'SQL'
-- Tabela principal de tabelas Iceberg (usada pelo Trino como JDBC catalog)
CREATE TABLE IF NOT EXISTS iceberg_tables (
    catalog_name              VARCHAR(255) NOT NULL,
    table_namespace           VARCHAR(255) NOT NULL,
    table_name                VARCHAR(255) NOT NULL,
    metadata_location         VARCHAR(5000),
    previous_metadata_location VARCHAR(5000),
    PRIMARY KEY (catalog_name, table_namespace, table_name)
);

-- Coluna de tipo (VIEW / TABLE) adicionada separadamente para
-- compatibilidade com versões antigas do metastore JDBC do Trino
ALTER TABLE iceberg_tables
    ADD COLUMN IF NOT EXISTS iceberg_type VARCHAR(5);

-- Propriedades de namespace (schemas) do catálogo Iceberg
CREATE TABLE IF NOT EXISTS iceberg_namespace_properties (
    catalog_name   VARCHAR(255) NOT NULL,
    namespace      VARCHAR(255) NOT NULL,
    property_key   VARCHAR(255),
    property_value VARCHAR(1000),
    PRIMARY KEY (catalog_name, namespace, property_key)
);
SQL
ok "Tabelas de metadados criadas."

# =============================================================================
# 4. MINIO (data lake — armazenamento de objetos)
# =============================================================================
compose_up "/stacks/minio/minio.yml"

# =============================================================================
# 5. DBEAVER (cliente SQL para PostgreSQL e Trino)
# =============================================================================
# ATENÇÃO: verifique se o arquivo está em 'dbaver' ou 'dbeaver'
compose_up "/stacks/dbeaver/dbeaver.yml"

# =============================================================================
# 6. TRINO (query engine — SQL sobre o data lake)
# =============================================================================
compose_up "/stacks/trino/trino.yml"

log "Aguardando Trino ficar pronto..."
until docker exec trino trino --execute "SELECT 1" &>/dev/null; do
  sleep 3
done
ok "Trino pronto."

log "Criando schemas Iceberg (bronze / prata / ouro)..."
docker exec trino trino << 'TRINO'
CREATE SCHEMA IF NOT EXISTS iceberg.bronze
    WITH (location = 's3://lakehouse/warehouse/bronze');

CREATE SCHEMA IF NOT EXISTS iceberg.prata
    WITH (location = 's3://lakehouse/warehouse/prata');

CREATE SCHEMA IF NOT EXISTS iceberg.ouro
    WITH (location = 's3://lakehouse/warehouse/ouro');
TRINO
ok "Schemas criados."

# =============================================================================
# 7. METABASE (dashboards e visualizações)
# =============================================================================
compose_up "/stacks/metabase/metabase.yml"

# =============================================================================
# 8. JENKINS (orquestrador de pipelines ETL)
# =============================================================================
compose_up "/stacks/jenkins/jenkins.yml"

# =============================================================================
# 9. SPARK + JUPYTER (IDE e motor de processamento ETL)
# =============================================================================
compose_up "/stacks/spark-jupyter/spark_jupyter.yml"

log "Aguardando Jupyter ficar pronto..."
until docker exec jupyter jupyter kernelspec list &>/dev/null; do
  sleep 3
done
ok "Jupyter pronto."

log "Instalando dependências Python no Jupyter..."
docker exec jupyter bash -c "
  set -e

  pip install psycopg2-binary --break-system-packages
  pip install papermill          --break-system-packages

  # Remove PySpark instalado pelo contêiner base e instala a versão
  # compatível com o Spark da stack (3.5.0)
  pip uninstall -y pyspark
  pip install pyspark==3.5.0 --break-system-packages

  # Fixa versões de bibliotecas com incompatibilidades conhecidas
  pip install --break-system-packages --force-reinstall \
    'numpy<2'          \
    'pyarrow==15.0.2'  \
    'pandas>=2.2.0'
"
ok "Dependências instaladas."

log "Reiniciando Jupyter para aplicar alterações..."
docker restart jupyter
ok "Jupyter reiniciado."

# =============================================================================
# 10. GRAFANA (monitoramento da infraestrutura)
# =============================================================================
compose_up "/stacks/grafana/grafana.yml"

# =============================================================================
# RESUMO
# =============================================================================
echo ""
echo "============================================================"
echo "  Lakehouse iniciado com sucesso!"
echo "============================================================"
echo "  Portainer  → http://localhost:9000"
echo "  MinIO      → http://localhost:9001"
echo "  DBeaver    → http://localhost:8978"
echo "  Trino UI   → http://localhost:8080"
echo "  Metabase   → http://localhost:3000"
echo "  Jenkins    → http://localhost:8082"
echo "  Jupyter    → http://localhost:8888"
echo "  Grafana    → http://localhost:3001"
echo "============================================================"