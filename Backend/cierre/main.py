"""Servicio de cierre: aplica veredictos y cierra por timeout las que no
llegan a tiempo. No es un servicio por request -- es un *worker* persistente
(en la nube corre con min_instance_count=1), con dos tareas en paralelo:

  1. Pull loop sobre `sub-cierre-veredictos`: por cada veredicto, UPDATE
     condicional (gana el primero que llegue) + INSERT en `veredictos`.
  2. Monitor de timeouts: cada `MONITOR_INTERVALO_SEGUNDOS`, cierra las
     pendientes vencidas con `SKIP LOCKED` y loguea
     `{"evento": "pendientes_vencidas", "cantidad": N}` -- la metrica de
     monitoreo de Camilo (`monitoring.tf`) espera exactamente ese formato.

`GET /salud` existe solo para que Cloud Run considere el contenedor sano; el
trabajo real no depende de recibir requests.
"""

import json
import logging
import os
import sys
import threading

from fastapi import FastAPI

_REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.abspath(os.path.join(_REPO_ROOT, "Backend", "common")))
sys.path.insert(0, os.path.abspath(_REPO_ROOT))

from db_conexion import conectar  # noqa: E402
from contracts import VeredictoEvento  # noqa: E402

os.environ.setdefault("DB_USER", "app_cierre")

SUBSCRIPTION_VEREDICTOS = os.environ.get("SUBSCRIPTION_VEREDICTOS", "sub-cierre-veredictos")
GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT")
MONITOR_INTERVALO_SEGUNDOS = float(os.environ.get("MONITOR_INTERVALO_SEGUNDOS", "5"))
MONITOR_LOTE = int(os.environ.get("MONITOR_LOTE", "100"))

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("cierre")

app = FastAPI(title="neobanx-cierre")

_detener = threading.Event()
_streaming_pull_future = None


def _conexion():
    return conectar()


def procesar_veredicto(evento: VeredictoEvento, conn) -> dict:
    """Aplica un veredicto: UPDATE condicional + INSERT en `veredictos`.

    Gana el primero que llegue (veredicto o timeout): el UPDATE solo afecta
    la fila si todavia esta 'pendiente_analisis'. Si no (ya vencio por
    timeout, o es un veredicto duplicado -- Flink y el stub corriendo a la
    vez, por ejemplo), el veredicto se guarda igual pero con tardio=true y
    NO cambia el estado: queda evidencia para calibrar el timeout sin romper
    la maquina de estados.
    """
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE transacciones
        SET estado = %s, finalizada_at = now()
        WHERE trans_num = %s AND estado = 'pendiente_analisis'
        """,
        (evento.resultado, evento.trans_num),
    )
    a_tiempo = cur.rowcount == 1

    cur.execute(
        """
        INSERT INTO veredictos
            (trans_num, resultado, reglas_disparadas, version_reglas, evaluado_at, tardio)
        VALUES (%s, %s, %s, %s, %s, %s)
        """,
        (
            evento.trans_num,
            evento.resultado,
            json.dumps(evento.reglas_disparadas),
            evento.version_reglas,
            evento.evaluado_at,
            not a_tiempo,
        ),
    )
    conn.commit()
    return {"trans_num": evento.trans_num, "tardio": not a_tiempo}


def cerrar_pendientes_vencidas(conn) -> int:
    """Cierra como `no_preseleccionada_timeout` las que vencieron su deadline.

    `SKIP LOCKED`: si otra instancia de cierre ya esta trabajando la misma
    fila, esta corrida la omite en vez de esperar el lock -- dos monitores
    corriendo a la vez no se bloquean entre si, cada uno procesa lo que esta
    libre.
    """
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE transacciones
        SET estado = 'no_preseleccionada_timeout', finalizada_at = now()
        WHERE trans_num IN (
            SELECT trans_num FROM transacciones
            WHERE estado = 'pendiente_analisis' AND deadline_at < now()
            ORDER BY deadline_at
            LIMIT %s
            FOR UPDATE SKIP LOCKED
        )
        RETURNING trans_num
        """,
        (MONITOR_LOTE,),
    )
    cantidad = cur.rowcount
    conn.commit()
    return cantidad


def _bucle_monitor() -> None:
    while not _detener.is_set():
        try:
            conn = _conexion()
            try:
                cantidad = cerrar_pendientes_vencidas(conn)
            finally:
                conn.close()
            log.info(json.dumps({"evento": "pendientes_vencidas", "cantidad": cantidad}))
        except Exception:
            log.exception("Fallo en el monitor de timeouts")
        _detener.wait(MONITOR_INTERVALO_SEGUNDOS)


def _callback_pubsub(message) -> None:
    try:
        evento = VeredictoEvento.model_validate_json(message.data)
        conn = _conexion()
        try:
            resultado = procesar_veredicto(evento, conn)
        finally:
            conn.close()
        log.info(json.dumps({"evento": "veredicto_procesado", **resultado}))
        message.ack()
    except Exception:
        log.exception("Fallo procesando veredicto, se reintentara (nack)")
        message.nack()


def _iniciar_consumidor_veredictos() -> None:
    global _streaming_pull_future
    if not GOOGLE_CLOUD_PROJECT:
        log.info(
            "GOOGLE_CLOUD_PROJECT no definido: el pull loop de veredictos no "
            "se inicia (modo local sin Pub/Sub)."
        )
        return

    from google.cloud import pubsub_v1

    cliente = pubsub_v1.SubscriberClient()
    subscription_path = cliente.subscription_path(GOOGLE_CLOUD_PROJECT, SUBSCRIPTION_VEREDICTOS)
    _streaming_pull_future = cliente.subscribe(subscription_path, callback=_callback_pubsub)
    log.info(f"Escuchando veredictos en {subscription_path}")


@app.on_event("startup")
def _startup() -> None:
    _iniciar_consumidor_veredictos()
    threading.Thread(target=_bucle_monitor, daemon=True).start()


@app.on_event("shutdown")
def _shutdown() -> None:
    _detener.set()
    if _streaming_pull_future is not None:
        _streaming_pull_future.cancel()


@app.get("/salud")
def salud():
    return {"estado": "ok"}
