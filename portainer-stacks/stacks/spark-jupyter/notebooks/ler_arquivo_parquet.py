import pandas as pd

arquivo = "20260614_020354_00012_g3msq-eb2b6478-11a2-4d5e-9640-75ffd6dffa58.parquet"

df = pd.read_parquet(arquivo)

print(df.head())
print(df.columns)
print(df.shape)