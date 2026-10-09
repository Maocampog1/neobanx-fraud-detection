"""Generador de streaming v2: lee fraudTest.csv y envia cada transaccion por
HTTP al servicio de registro, respetando la cadencia temporal original (ver
Backend/contrato_datos_generador.md).

Cambios frente a v1 (Sprint 1):
  - Lee fraudTest.csv, no fraudTrain.csv -- fraudTrain ya se uso para cargar
    los perfiles de Redis, y el generador no debe usar datos que el perfil
    "ya conoce" (ver Documentation/CONTEXTO_SPRINT2_NEOBANX.md).
  - Envia por HTTP POST al servicio de registro, no publica a Pub/Sub
    directo -- el registro es quien decide preseleccion y publica.
  - El hash de la tarjeta usa Backend/common/hmac_util (HMAC-SHA256 de 64
    caracteres, clave en Secret Manager), reemplaza el hash local v1 que
    truncaba a 10 caracteres y no era HMAC real.
"""

import os
import sys
import time
from pathlib import Path

import pandas as pd
import requests

_REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_REPO_ROOT / "Backend" / "common"))
sys.path.insert(0, str(_REPO_ROOT))

from hmac_util import hash_cc_num  # noqa: E402
from contracts import TransaccionEvento  # noqa: E402

REGISTRO_URL = os.environ.get("REGISTRO_URL", "http://localhost:8080")
# En local (contra un registro corriendo en localhost) el servicio no exige
# autenticacion de IAM. En la nube, el generador llama a un Cloud Run service
# privado y necesita un token de identidad de su propia cuenta (sa-generador,
# que ya tiene roles/run.invoker).
USAR_AUTH_IAM = os.environ.get("USAR_AUTH_IAM", "false").lower() == "true"

CSV_PATH = os.environ.get(
    "CSV_PATH", os.path.join(os.path.dirname(__file__), "data", "fraudTest.csv")
)
DATASET_URL = os.environ.get(
    "DATASET_URL",
    "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTest.csv",
)

# TX_POR_SEGUNDO reemplaza el INTERVALO_SEGUNDOS fijo de v1 -- mas facil de
# calibrar para la prueba de carga sostenida del nuevo test.sh.
TX_POR_SEGUNDO = float(os.environ.get("TX_POR_SEGUNDO", "1"))
INTERVALO_SEGUNDOS = 1.0 / TX_POR_SEGUNDO if TX_POR_SEGUNDO > 0 else 0.0

MAX_FILAS = os.environ.get("MAX_FILAS")
FECHA_INICIO = os.environ.get("FECHA_INICIO")
FECHA_FIN = os.environ.get("FECHA_FIN")
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "50000"))

MAX_REINTENTOS = int(os.environ.get("MAX_REINTENTOS", "5"))
BACKOFF_BASE_SEGUNDOS = float(os.environ.get("BACKOFF_BASE_SEGUNDOS", "1"))

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

_id_token_cache = {"token": None, "audiencia": None}


def _obtener_id_token(audiencia: str) -> str:
    """Token de identidad para llamar a un Cloud Run service privado.

    Importa google.auth solo cuando hace falta (USAR_AUTH_IAM=true) para que
    correr el generador en local, sin auth, no exija esa dependencia.
    """
    if _id_token_cache["audiencia"] != audiencia:
        from google.auth.transport.requests import Request
        from google.oauth2.id_token import fetch_id_token

        _id_token_cache["token"] = fetch_id_token(Request(), audiencia)
        _id_token_cache["audiencia"] = audiencia
    return _id_token_cache["token"]


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
    """Lee el CSV por bloques en vez de cargarlo completo en memoria."""
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
    """Descarga el CSV publico a `destino` si aun no existe localmente."""
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


def construir_evento(fila: pd.Series) -> TransaccionEvento:
    comercio = str(fila["merchant"])
    if comercio.startswith("fraud_"):
        comercio = comercio[len("fraud_"):]

    return TransaccionEvento(
        trans_num=fila["trans_num"],
        cc_num_hash=hash_cc_num(fila["cc_num"]),
        comercio=comercio,
        categoria=fila["category"],
        monto=float(fila["amt"]),
        fecha_hora_transaccion=fila["trans_date_trans_time"].isoformat(),
        lat_comercio=float(fila["merch_lat"]),
        long_comercio=float(fila["merch_long"]),
        is_fraud_real=int(fila["is_fraud"]),
    )


def enviar_transaccion(evento: TransaccionEvento) -> requests.Response:
    """POST al servicio de registro, con reintentos y backoff exponencial.

    Un 2xx es exito (incluye el caso "ya existia", el registro hace
    ON CONFLICT DO NOTHING). Un 4xx que no sea 429 es un error del payload,
    no tiene sentido reintentarlo -- se reporta y se sigue con la siguiente
    transaccion en vez de atascar el generador.
    """
    url = f"{REGISTRO_URL.rstrip('/')}/transacciones"
    headers = {}
    if USAR_AUTH_IAM:
        headers["Authorization"] = f"Bearer {_obtener_id_token(REGISTRO_URL)}"

    ultimo_error = None
    for intento in range(1, MAX_REINTENTOS + 1):
        try:
            resp = requests.post(url, json=evento.model_dump(mode="json"), headers=headers, timeout=10)
        except requests.RequestException as e:
            ultimo_error = e
        else:
            if resp.status_code < 300:
                return resp
            if resp.status_code != 429 and resp.status_code < 500:
                # Error del payload (4xx que no es "demasiadas peticiones") -- reintentar no va a arreglarlo.
                resp.raise_for_status()
            ultimo_error = requests.HTTPError(f"{resp.status_code}: {resp.text}")

        if intento < MAX_REINTENTOS:
            espera = BACKOFF_BASE_SEGUNDOS * (2 ** (intento - 1))
            print(f"  intento {intento}/{MAX_REINTENTOS} fallo ({ultimo_error}); reintentando en {espera:.1f}s")
            time.sleep(espera)

    raise RuntimeError(f"No se pudo enviar {evento.trans_num} tras {MAX_REINTENTOS} intentos: {ultimo_error}")


def main():
    descargar_csv_si_falta(DATASET_URL, CSV_PATH)
    df = cargar_transacciones(CSV_PATH)
    df = limpiar_datos(df)
    df = df.sort_values("trans_date_trans_time").reset_index(drop=True)
    if MAX_FILAS:
        df = df.head(int(MAX_FILAS)).reset_index(drop=True)
    print(
        f"{len(df)} transacciones a enviar desde {CSV_PATH} hacia {REGISTRO_URL}, "
        f"{TX_POR_SEGUNDO} tx/s, ordenadas por trans_date_trans_time"
    )

    for _, fila in df.iterrows():
        evento = construir_evento(fila)
        resp = enviar_transaccion(evento)
        print(f"[{resp.status_code}] {evento.trans_num} monto={evento.monto}")
        if INTERVALO_SEGUNDOS:
            time.sleep(INTERVALO_SEGUNDOS)


if __name__ == "__main__":
    main()
