import base64
import json
import os
from datetime import datetime, timezone

import functions_framework
from google.cloud import bigquery

PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
DATASET = os.environ.get("BQ_DATASET", "raw")
TABLE = os.environ.get("BQ_TABLE", "transacciones_raw")
UMBRAL_MONTO = float(os.environ.get("UMBRAL_MONTO", "200"))

CATEGORIAS_ALTO_RIESGO = {"shopping_net", "misc_net", "grocery_pos"}

bq_client = bigquery.Client()
TABLE_REF = f"{PROJECT_ID}.{DATASET}.{TABLE}"


def calcular_veredicto(amt: float, category: str) -> str:
    """Regla baseline simple (no ML entrenado) para demo del MVP."""
    if amt > UMBRAL_MONTO and category in CATEGORIAS_ALTO_RIESGO:
        return "alerta"
    if amt > UMBRAL_MONTO * 2:
        return "alerta"
    return "aprobada"


@functions_framework.cloud_event
def consumidor(cloud_event):
    """Triggered por Pub/Sub; inserta cada transaccion en BigQuery Raw."""
    message = cloud_event.data.get("message", {})
    encoded = message.get("data")
    if not encoded:
        raise ValueError("Mensaje de Pub/Sub sin data")

    payload = json.loads(base64.b64decode(encoded).decode("utf-8"))
    amt = float(payload.get("amt", 0))
    category = payload.get("category", "")

    row = {
        "trans_num": payload.get("trans_num"),
        "cc_num_hash": payload.get("cc_num_hash"),
        "merchant": payload.get("merchant"),
        "category": category,
        "amt": amt,
        "trans_date_trans_time": payload.get("trans_date_trans_time"),
        "merch_lat": payload.get("merch_lat"),
        "merch_long": payload.get("merch_long"),
        "is_fraud": payload.get("is_fraud"),
        "veredicto": calcular_veredicto(amt, category),
        "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
        "pubsub_message_id": message.get("messageId"),
    }

    errors = bq_client.insert_rows_json(TABLE_REF, [row])
    if errors:
        raise RuntimeError(f"Error insertando en BigQuery: {errors}")

    print(f"Insertada transaccion {row['trans_num']} -> {row['veredicto']}")