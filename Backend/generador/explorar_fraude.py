"""Encuentra ventanas de tiempo con mayor densidad de fraude en fraudTrain.csv,
utiles para pruebas cortas del generador (correr el CSV completo a 4s/mensaje
tomaria ~60 dias, y el fraude es solo ~0.58% de las filas en promedio)."""

import os

import pandas as pd

CSV_PATH = os.environ.get(
    "CSV_PATH", os.path.join(os.path.dirname(__file__), "data", "fraudTrain.csv")
)


def top_dias(df: pd.DataFrame, n: int = 10) -> pd.DataFrame:
    por_dia = df.groupby(df["trans_date_trans_time"].dt.date).agg(
        total=("is_fraud", "size"), fraudes=("is_fraud", "sum")
    )
    return por_dia.sort_values("fraudes", ascending=False).head(n)


def top_bloques_2h(df: pd.DataFrame, dia: str, n: int = 5) -> pd.DataFrame:
    del_dia = df[
        (df["trans_date_trans_time"] >= dia)
        & (df["trans_date_trans_time"] < pd.Timestamp(dia) + pd.Timedelta(days=1))
    ].copy()
    por_hora = del_dia.groupby(del_dia["trans_date_trans_time"].dt.hour).agg(
        total=("is_fraud", "size"), fraudes=("is_fraud", "sum")
    )
    por_hora["fraudes_2h"] = por_hora["fraudes"].rolling(2).sum()
    return por_hora.sort_values("fraudes_2h", ascending=False).head(n)


def main():
    df = pd.read_csv(CSV_PATH, usecols=["trans_date_trans_time", "is_fraud"], parse_dates=["trans_date_trans_time"])

    dias = top_dias(df)
    print("=== Top 10 dias con mas fraudes ===")
    print(dias)

    mejor_dia = str(dias.index[0])
    print(f"\n=== Bloques de 2h con mas fraudes en {mejor_dia} ===")
    print(top_bloques_2h(df, mejor_dia))
    print(
        f"\nSugerencia: correr con FECHA_INICIO/FECHA_FIN acotado al mejor bloque "
        f"de {mejor_dia} para ver varios fraudes reales en pocos minutos."
    )


if __name__ == "__main__":
    main()
