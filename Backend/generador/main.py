"""Generador de streaming: publica fraudTrain.csv a Pub/Sub respetando la
cadencia temporal original (ver Backend/contrato_datos_generador.md)."""

import hashlib
import json
import os
import time

import pandas as pd
from google.cloud import pubsub_v1

from holidays import es_festivo

PROJECT_ID = os.environ.get("PROJECT_ID", "neobanx-fraud-detection")
TOPIC_ID = os.environ.get("TOPIC_ID", "transacciones-neobanx")
CSV_PATH = os.environ.get(
    "CSV_PATH", os.path.join(os.path.dirname(__file__), "data", "fraudTrain.csv")
)
INTERVALO_SEGUNDOS = float(os.environ.get("INTERVALO_SEGUNDOS", "4"))
SALT = os.environ["GENERATOR_SALT"]

# Acotar la corrida es opcional -- el CSV completo (~1.3M filas) tomaria
# ~60 dias a 4s/mensaje, asi que para pruebas se usa un subconjunto.
MAX_FILAS = os.environ.get("MAX_FILAS")
FECHA_INICIO = os.environ.get("FECHA_INICIO")  # ej. "2019-01-01"
FECHA_FIN = os.environ.get("FECHA_FIN")  # ej. "2019-01-02"

COLUMNAS_CONTRATO = [
    "trans_num",
    "cc_num",
    "merchant",
    "category",
    "amt",
    "trans_date_trans_time",
    "merch_lat",
    "merch_long",
    "is_fraud",
]

_publisher = None
_topic_path = None


def _get_publisher():
    global _publisher, _topic_path
    if _publisher is None:
        _publisher = pubsub_v1.PublisherClient()
        _topic_path = _publisher.topic_path(PROJECT_ID, TOPIC_ID)
    return _publisher, _topic_path


def hash_cc_num(cc_num) -> str:
    digest = hashlib.sha256(f"{SALT}{cc_num}".encode("utf-8")).hexdigest()
    return digest[:10]


def construir_payload(fila: pd.Series) -> dict:
    return {
        "trans_num": fila["trans_num"],
        "cc_num_hash": hash_cc_num(fila["cc_num"]),
        "merchant": fila["merchant"],
        "category": fila["category"],
        "amt": float(fila["amt"]),
        "trans_date_trans_time": fila["trans_date_trans_time"].isoformat(),
        "merch_lat": float(fila["merch_lat"]),
        "merch_long": float(fila["merch_long"]),
        "is_fraud": int(fila["is_fraud"]),
    }


def publicar_transaccion(payload: dict) -> str:
    publisher, topic_path = _get_publisher()
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    future = publisher.publish(topic_path, data)
    return future.result()  # espera confirmacion de Pub/Sub


def limpiar_datos(df: pd.DataFrame) -> pd.DataFrame:
    total_original = len(df)

    sin_nulos = df.dropna(subset=COLUMNAS_CONTRATO)
    descartadas_nulos = total_original - len(sin_nulos)

    sin_duplicados = sin_nulos.drop_duplicates(subset="trans_num", keep="first")
    descartadas_duplicados = len(sin_nulos) - len(sin_duplicados)

    if descartadas_nulos or descartadas_duplicados:
        print(
            f"Limpieza: {descartadas_nulos} filas con nulos y "
            f"{descartadas_duplicados} con trans_num duplicado descartadas "
            f"({total_original} -> {len(sin_duplicados)})"
        )

    return sin_duplicados


def acotar_rango(df: pd.DataFrame) -> pd.DataFrame:
    if FECHA_INICIO:
        df = df[df["trans_date_trans_time"] >= pd.Timestamp(FECHA_INICIO)]
    if FECHA_FIN:
        df = df[df["trans_date_trans_time"] < pd.Timestamp(FECHA_FIN)]
    if MAX_FILAS:
        df = df.head(int(MAX_FILAS))
    return df.reset_index(drop=True)


def main():
    df = pd.read_csv(CSV_PATH, parse_dates=["trans_date_trans_time"])
    df = limpiar_datos(df)
    df = df.sort_values("trans_date_trans_time").reset_index(drop=True)
    df = acotar_rango(df)
    print(f"{len(df)} transacciones a publicar desde {CSV_PATH}, ordenadas por trans_date_trans_time")

    for _, fila in df.iterrows():
        payload = construir_payload(fila)
        message_id = publicar_transaccion(payload)
        festivo = es_festivo(fila["trans_date_trans_time"].date())
        print(f"[{message_id}] {payload['trans_num']} amt={payload['amt']} festivo={festivo}")
        time.sleep(INTERVALO_SEGUNDOS)


if __name__ == "__main__":
    main()
