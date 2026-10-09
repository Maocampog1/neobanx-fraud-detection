"""Servicio de registro: recibe el POST del generador, inserta la transaccion
como 'recibida' y decide si se preselecciona para analisis.

Flujo (ver Backend/contrato_datos_generador.md):
  1. INSERT ... ON CONFLICT (trans_num) DO NOTHING -- idempotente, el
     generador puede reintentar sin crear filas duplicadas.
  2. Si la fila ya existia (conflicto) o la insertada no quedo en 'recibida'
     por otra razon, no se decide preseleccion de nuevo -- ya se decidio la
     primera vez que llego este trans_num.
  3. Si la fila es nueva: se decide preseleccion por muestreo aleatorio o por
     umbral de monto, y se hace un solo UPDATE a 'sin_analizar' o
     'pendiente_analisis' (+ deadline_at). Si quedo pendiente, se publica en
     tx-preseleccionadas.

cc_num_hash es FK a cuentas: la cuenta debe existir de antemano (cargada por
cargar_maestros.py desde fraudTrain.csv). Si no existe, el INSERT falla con
una violacion de FK -- se traduce a 422, no es un error del servicio.
"""

import json
import os
import random
import sys
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, HTTPException
from psycopg2 import errors as pg_errors

_REPO_ROOT_COMMON = os.path.join(os.path.dirname(__file__), "..", "common")
sys.path.insert(0, os.path.abspath(_REPO_ROOT_COMMON))
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

from db_conexion import conectar  # noqa: E402
from contracts import TransaccionEvento  # noqa: E402

PROBABILIDAD_MUESTREO = float(os.environ.get("PROBABILIDAD_MUESTREO", "0.15"))
UMBRAL_MONTO_PRESELECCION = float(os.environ.get("UMBRAL_MONTO_PRESELECCION", "200"))
TIMEOUT_VEREDICTO_SEGUNDOS = int(os.environ.get("TIMEOUT_VEREDICTO_SEGUNDOS", "30"))

# Nombre del topico real en la nube; en local, con PUBSUB_EMULATOR_HOST sin
# definir, se omite la publicacion por completo (ver `_publicar_preseleccion`).
TOPIC_PRESELECCIONADAS = os.environ.get("TOPIC_PRESELECCIONADAS", "tx-preseleccionadas")
GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT")

os.environ.setdefault("DB_USER", "app_registro")

app = FastAPI(title="neobanx-registro")

_publisher_cache = {"cliente": None}


@contextmanager
def _conexion():
    conn = conectar()
    try:
        yield conn
    finally:
        conn.close()


def _decidir_preseleccion(monto: float) -> str | None:
    """Devuelve el motivo de preseleccion, o None si no se preselecciona."""
    if monto > UMBRAL_MONTO_PRESELECCION:
        return "umbral_monto"
    if random.random() < PROBABILIDAD_MUESTREO:
        return "muestreo_aleatorio"
    return None


def _publicar_preseleccion(evento: TransaccionEvento) -> None:
    """Publica en tx-preseleccionadas. No-op si no hay Pub/Sub configurado
    (ni `PUBSUB_EMULATOR_HOST` ni `GOOGLE_CLOUD_PROJECT`) -- permite probar
    la logica de preseleccion/DB en local sin levantar el emulador todavia.
    """
    if not GOOGLE_CLOUD_PROJECT:
        return

    from google.cloud import pubsub_v1

    if _publisher_cache["cliente"] is None:
        _publisher_cache["cliente"] = pubsub_v1.PublisherClient()
    cliente = _publisher_cache["cliente"]

    topic_path = cliente.topic_path(GOOGLE_CLOUD_PROJECT, TOPIC_PRESELECCIONADAS)
    payload = json.dumps(evento.model_dump(mode="json")).encode("utf-8")
    cliente.publish(topic_path, payload).result(timeout=10)


@app.get("/salud")
def salud():
    return {"estado": "ok"}


@app.post("/transacciones", status_code=201)
def recibir_transaccion(evento: TransaccionEvento):
    with _conexion() as conn:
        cur = conn.cursor()
        try:
            cur.execute(
                """
                INSERT INTO transacciones
                    (trans_num, cc_num_hash, comercio, categoria, monto,
                     fecha_hora_transaccion, lat_comercio, long_comercio, is_fraud_real)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (trans_num) DO NOTHING
                """,
                (
                    evento.trans_num,
                    evento.cc_num_hash,
                    evento.comercio,
                    evento.categoria,
                    evento.monto,
                    evento.fecha_hora_transaccion,
                    evento.lat_comercio,
                    evento.long_comercio,
                    evento.is_fraud_real,
                ),
            )
        except pg_errors.ForeignKeyViolation:
            conn.rollback()
            raise HTTPException(
                status_code=422,
                detail=f"cc_num_hash desconocido, no existe cuenta cargada para {evento.cc_num_hash[:8]}...",
            )

        if cur.rowcount == 0:
            # Ya existia -- la decision de preseleccion se tomo la primera vez.
            conn.commit()
            return {"trans_num": evento.trans_num, "duplicado": True}

        motivo = _decidir_preseleccion(evento.monto)
        if motivo is None:
            cur.execute(
                """
                UPDATE transacciones
                SET estado = 'sin_analizar', motivo_preseleccion = 'no_preseleccionada',
                    finalizada_at = now()
                WHERE trans_num = %s
                """,
                (evento.trans_num,),
            )
        else:
            deadline = datetime.now(timezone.utc) + timedelta(seconds=TIMEOUT_VEREDICTO_SEGUNDOS)
            cur.execute(
                """
                UPDATE transacciones
                SET estado = 'pendiente_analisis', motivo_preseleccion = %s, deadline_at = %s
                WHERE trans_num = %s
                """,
                (motivo, deadline, evento.trans_num),
            )

        conn.commit()

    if motivo is not None:
        _publicar_preseleccion(evento)

    return {
        "trans_num": evento.trans_num,
        "duplicado": False,
        "preseleccionada": motivo is not None,
        "motivo_preseleccion": motivo,
    }
