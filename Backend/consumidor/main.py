import base64
import json
import os
from datetime import datetime, timezone

import functions_framework
from google.cloud import bigquery

PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
DATASET = os.environ.get("BQ_DATASET", "raw")
TABLE = os.environ.get("BQ_TABLE", "transacciones_raw")

bq_client = bigquery.Client()
TABLE_REF = f"{PROJECT_ID}.{DATASET}.{TABLE}"


@functions_framework.cloud_event
def consumidor(cloud_event):
    """Triggered por Pub/Sub; inserta cada transaccion en BigQuery Raw."""
    message = cloud_event.data.get("message", {})
    encoded = message.get("data")
    if not encoded:
        raise ValueError("Mensaje de Pub/Sub sin data")

    payload = json.loads(base64.b64decode(encoded).decode("utf-8"))

    row = {
        "trans_num": payload.get("trans_num"),
        "cc_num_hash": payload.get("cc_num_hash"),
        "merchant": payload.get("merchant"),
        "category": payload.get("category"),
        "amt": payload.get("amt"),
        "trans_date_trans_time": payload.get("trans_date_trans_time"),
        "merch_lat": payload.get("merch_lat"),
        "merch_long": payload.get("merch_long"),
        "is_fraud": payload.get("is_fraud"),
        "ingestion_timestamp": datetime.now(timezone.utc).isoformat(),
        "pubsub_message_id": message.get("messageId"),
    }

    errors = bq_client.insert_rows_json(TABLE_REF, [row])
    if errors:
        raise RuntimeError(f"Error insertando en BigQuery: {errors}")

    print(f"Insertada transaccion {row['trans_num']} en {TABLE_REF}")