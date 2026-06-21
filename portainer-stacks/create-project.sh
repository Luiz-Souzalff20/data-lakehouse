# Criacao de conexao para as stacks
docker network create lakehouse

# Sobe a aplicacao do Portainer
docker compose -f "portainer.yml" up -d

# Sobe o banco de dados
docker compose -f "/stacks/postgres/postgres.yml" up -d
# Cria o banco de dados para a camada ouro do data lakehouse
docker exec -it postgres psql -U dba_admin -c "CREATE DATABASE db_ecommerce;"

# Sobe o Minio para o data lake
docker compose -f "/stacks/minio/minio.yml" up -d

# Sobe o Dbeaver para acessar os dados do banco de dados e do Trino (dados brutos como tabelas)
docker compose -f "/stacks/dbaver/dbaver.yml" up -d

docker compose -f "/stacks/trino/trino.yml" up -d

# Sobe o metabase para acessar os graficos e tabelas tanto do postgres e Trino
docker compose -f "/stacks/metabase/metabase.yml" up -d

# Sobe o orquestrador dos noteboobs, responsavel por executar cada etapa ETL. Carregando tanto o data lake e popula o banco de dados.
docker compose -f "/stacks/jenkins/jenkins.yml" up -d

# Sobe tanto a IDE e motor para a etapa ETL do data lakehouse 
docker compose -f "/stacks/spark-jupyter/spark_jupyter.yml" up -d
# Configuracao da IDE
docker exec -it jupyter bash
pip install psycopg2-binary --break-system-packages
pip install papermill
pip uninstall -y pyspark
pip install pyspark==3.5.0
pip install --force-reinstall \
"numpy<2" \
"pyarrow==15.0.2" \
"pandas>=2.2.0"
# Reinicia a IDE
docker restart jupyter

# Sobe o servico de monitamento da aplicacao
docker compose -f "/stacks/grafana/grafana.yml" up -d