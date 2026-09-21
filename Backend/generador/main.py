"""Generador de streaming: publica fraudTrain.csv a Pub/Sub respetando la
cadencia temporal original (ver Backend/contrato_datos_generador.md)."""

import hashlib
import json
import os
import time

import pandas as pd
import requests
from google.cloud import pubsub_v1

from holidays import es_festivo

PROJECT_ID = os.environ.get("PROJECT_ID", "neobanx-fraud-detection")
TOPIC_ID = os.environ.get("TOPIC_ID", "transacciones-neobanx")
CSV_PATH = os.environ.get(
    "CSV_PATH", os.path.join(os.path.dirname(__file__), "data", "fraudTrain.csv")
)
# CSV publicado una sola vez por el equipo en un bucket publico -- asi
# cualquiera que reproduzca el repo (incluso en un proyecto GCP nuevo) no
# necesita descargarlo a mano de Kaggle.
DATASET_URL = os.environ.get(
    "DATASET_URL",
    "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTrain.csv",
)
INTERVALO_SEGUNDOS = float(os.environ.get("INTERVALO_SEGUNDOS", "4"))
SALT = os.environ["GENERATOR_SALT"]

# Acotar la corrida es opcional -- el CSV completo (~1.3M filas) tomaria
# ~60 dias a 4s/mensaje, asi que para pruebas se usa un subconjunto.
MAX_FILAS = os.environ.get("MAX_FILAS")
FECHA_INICIO = os.environ.get("FECHA_INICIO")  # ej. "2019-01-01"
FECHA_FIN = os.environ.get("FECHA_FIN")  # ej. "2019-01-02"

# Filas por bloque al leer el CSV -- evita cargar el archivo completo
# (~350MB) en memoria de una sola vez.
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "50000"))

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


def cargar_transacciones(csv_path: str) -> pd.DataFrame:
    """Lee el CSV por bloques en vez de cargarlo completo en memoria.

    Si FECHA_INICIO/FECHA_FIN estan definidas, cada bloque se filtra antes
    de acumularlo -- la memoria pico depende del tamano de un bloque
    (CHUNK_SIZE filas), no del archivo completo (1.29M filas / 350MB).
    Sin fechas definidas esto termina acumulando el dataset completo de
    todas formas -- correr sin acotar solo tiene sentido en local, nunca en
    el Cloud Run Job (ver Infrastructure/README.md).
    """
    fecha_inicio_ts = pd.Timestamp(FECHA_INICIO) if FECHA_INICIO else None
    fecha_fin_ts = pd.Timestamp(FECHA_FIN) if FECHA_FIN else None

    bloques = []
    lector = pd.read_csv(csv_path, parse_dates=["trans_date_trans_time"], chunksize=CHUNK_SIZE)
    for bloque in lector:
        if fecha_inicio_ts is not None:
            bloque = bloque[bloque["trans_date_trans_time"] >= fecha_inicio_ts]
        if fecha_fin_ts is not None:
            bloque = bloque[bloque["trans_date_trans_time"] < fecha_fin_ts]
        if not bloque.empty:
            bloques.append(bloque)

    if not bloques:
        return pd.read_csv(csv_path, nrows=0)
    return pd.concat(bloques, ignore_index=True)


def descargar_csv_si_falta(url: str, destino: str) -> None:
    """Descarga el CSV publico a `destino` si aun no existe localmente.

    Streaming (no carga el archivo completo en memoria) y escritura atomica
    (descarga a un archivo temporal y lo renombra al final) para que una
    descarga interrumpida a medias no quede confundida con un archivo valido
    en el proximo arranque.
    """
    if os.path.exists(destino):
        print(f"CSV ya presente en {destino}, se omite la descarga")
        return

    os.makedirs(os.path.dirname(destino) or ".", exist_ok=True)
    tmp_destino = f"{destino}.part"
    print(f"CSV no encontrado en {destino}; descargando desde {url}...")

    with requests.get(url, stream=True, timeout=30) as resp:
        resp.raise_for_status()
        with open(tmp_destino, "wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)

    os.replace(tmp_destino, destino)
    print(f"Descarga completa: {destino}")


def main():
    descargar_csv_si_falta(DATASET_URL, CSV_PATH)
    df = cargar_transacciones(CSV_PATH)
    df = limpiar_datos(df)
    df = df.sort_values("trans_date_trans_time").reset_index(drop=True)
    if MAX_FILAS:
        df = df.head(int(MAX_FILAS)).reset_index(drop=True)
    print(f"{len(df)} transacciones a publicar desde {CSV_PATH}, ordenadas por trans_date_trans_time")

    for _, fila in df.iterrows():
        payload = construir_payload(fila)
        message_id = publicar_transaccion(payload)
        festivo = es_festivo(fila["trans_date_trans_time"].date())
        print(f"[{message_id}] {payload['trans_num']} amt={payload['amt']} festivo={festivo}")
        time.sleep(INTERVALO_SEGUNDOS)


if __name__ == "__main__":
    main()
