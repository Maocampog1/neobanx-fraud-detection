"""Stub de veredicto: regla baseline (monto + categoria) que simula a Flink
mientras el job real no esta listo. Consume `sub-stub-preseleccionadas`
(un evento de transaccion, el mismo que publica el registro) y publica un
veredicto a `tx-veredictos`, con el mismo contrato que usara Flink despues
-- para el servicio de cierre son indistinguibles.

NO usa Redis ni hace enriquecimiento (eso es lo que Flink agrega despues con
Async I/O): la regla solo mira los campos que ya vienen en el evento de
transaccion. `version_reglas` siempre es "stub-v1", nunca se hace pasar por
Flink -- queda clarisimo en la base quien evaluo cada transaccion.

RETRASO_SEGUNDOS simula la latencia real de evaluacion: subirlo por encima
de `timeout_veredicto_segundos` es como se prueban los casos de "tardio" y
"timeout puro" del test.sh sin esperar a que Flink este listo.
"""

import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

from fastapi import FastAPI

_REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, os.path.abspath(_REPO_ROOT))

from contracts import TransaccionEvento, VeredictoEvento  # noqa: E402

SUBSCRIPTION_PRESELECCIONADAS = os.environ.get("SUBSCRIPTION_PRESELECCIONADAS", "sub-stub-preseleccionadas")
TOPIC_VEREDICTOS = os.environ.get("TOPIC_VEREDICTOS", "tx-veredictos")
GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT")
RETRASO_SEGUNDOS = float(os.environ.get("RETRASO_SEGUNDOS", "0"))

# Regla baseline: sin estado, sin perfil -- solo lo que ya trae el evento.
UMBRAL_MONTO_ALTO = float(os.environ.get("UMBRAL_MONTO_ALTO", "500"))
CATEGORIAS_RIESGO = set(os.environ.get("CATEGORIAS_RIESGO", "shopping_net,misc_net").split(","))
UMBRAL_MONTO_CATEGORIA_RIESGO = float(os.environ.get("UMBRAL_MONTO_CATEGORIA_RIESGO", "100"))
VERSION_REGLAS = "stub-v1"

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("stub_veredicto")

app = FastAPI(title="neobanx-stub-veredicto")

_publisher_cache = {"cliente": None}
_streaming_pull_future = None


def evaluar(evento: TransaccionEvento) -> VeredictoEvento:
    """Regla baseline: monto alto, o categoria de riesgo con monto moderado.

    Deliberadamente simple -- es el reemplazo temporal de Flink, no una
    version reducida de sus reglas reales (esas si necesitan el perfil de
    Redis y el estado de rafagas, que el stub no tiene).
    """
    reglas = []
    if evento.monto > UMBRAL_MONTO_ALTO:
        reglas.append("monto_alto")
    if evento.categoria in CATEGORIAS_RIESGO and evento.monto > UMBRAL_MONTO_CATEGORIA_RIESGO:
        reglas.append("categoria_riesgo")

    resultado = "bloqueada" if reglas else "aprobada"
    return VeredictoEvento(
        trans_num=evento.trans_num,
        resultado=resultado,
        reglas_disparadas=reglas,
        evaluado_at=datetime.now(timezone.utc),
        version_reglas=VERSION_REGLAS,
    )


def _publicar_veredicto(veredicto: VeredictoEvento) -> None:
    """Publica en tx-veredictos. En local, sin GOOGLE_CLOUD_PROJECT, solo
    loguea el veredicto que se habria publicado -- permite probar la regla
    sin el emulador de Pub/Sub."""
    if not GOOGLE_CLOUD_PROJECT:
        log.info(json.dumps({"evento": "veredicto_omitido_sin_pubsub", **veredicto.model_dump(mode="json")}))
        return

    from google.cloud import pubsub_v1

    if _publisher_cache["cliente"] is None:
        _publisher_cache["cliente"] = pubsub_v1.PublisherClient()
    cliente = _publisher_cache["cliente"]

    topic_path = cliente.topic_path(GOOGLE_CLOUD_PROJECT, TOPIC_VEREDICTOS)
    payload = json.dumps(veredicto.model_dump(mode="json")).encode("utf-8")
    cliente.publish(topic_path, payload).result(timeout=10)


def _callback_pubsub(message) -> None:
    try:
        evento = TransaccionEvento.model_validate_json(message.data)
        if RETRASO_SEGUNDOS:
            time.sleep(RETRASO_SEGUNDOS)
        veredicto = evaluar(evento)
        _publicar_veredicto(veredicto)
        log.info(json.dumps({
            "evento": "veredicto_emitido",
            "trans_num": veredicto.trans_num,
            "resultado": veredicto.resultado,
            "reglas_disparadas": veredicto.reglas_disparadas,
        }))
        message.ack()
    except Exception:
        log.exception("Fallo evaluando transaccion, se reintentara (nack)")
        message.nack()


def _iniciar_consumidor() -> None:
    global _streaming_pull_future
    if not GOOGLE_CLOUD_PROJECT:
        log.info(
            "GOOGLE_CLOUD_PROJECT no definido: el pull loop no se inicia "
            "(modo local sin Pub/Sub)."
        )
        return

    from google.cloud import pubsub_v1

    cliente = pubsub_v1.SubscriberClient()
    subscription_path = cliente.subscription_path(GOOGLE_CLOUD_PROJECT, SUBSCRIPTION_PRESELECCIONADAS)
    _streaming_pull_future = cliente.subscribe(subscription_path, callback=_callback_pubsub)
    log.info(f"Escuchando transacciones preseleccionadas en {subscription_path}")


@app.on_event("startup")
def _startup() -> None:
    _iniciar_consumidor()


@app.on_event("shutdown")
def _shutdown() -> None:
    if _streaming_pull_future is not None:
        _streaming_pull_future.cancel()


@app.get("/salud")
def salud():
    return {"estado": "ok"}
