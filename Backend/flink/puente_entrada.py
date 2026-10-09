"""Puente Pub/Sub -> archivos: lee `sub-flink-preseleccionadas` y escribe
los mensajes como lineas JSON en archivos nuevos dentro de `entrada/`, para
que el `FileSource` de Flink (conector real, con bindings de Python -- ver
Backend/flink/README.md para por que hace falta este puente) los recoja en
su monitoreo continuo.

POR QUE ARCHIVOS NUEVOS, NO UNO SOLO CRECIENDO
-----------------------------------------------
Flink's FileSource descubre archivos NUEVOS; agregarle lineas a un archivo
que ya proceso no hace que las vuelva a leer. Por eso este puente acumula
mensajes en memoria y los vacia a un archivo con nombre unico cada
`INTERVALO_FLUSH_SEGUNDOS` o cada `TAMANO_LOTE` mensajes, lo que pase
primero -- un micro-batching clasico.

Corre como un *worker* persistente (mismo patron que Backend/cierre/ y
Backend/stub_veredicto/): un pull loop de Pub/Sub de toda la vida del
proceso. En la nube corre en el nodo master de Dataproc junto al job de
Flink, no como un Cloud Run aparte.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid

GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT")
SUBSCRIPTION_PRESELECCIONADAS = os.environ.get(
    "SUBSCRIPTION_PRESELECCIONADAS", "sub-flink-preseleccionadas"
)
# file:///ruta/local para pruebas, gs://bucket/entrada para la nube real.
DIRECTORIO_ENTRADA = os.environ.get("DIRECTORIO_ENTRADA", "./puente_local/entrada")

INTERVALO_FLUSH_SEGUNDOS = float(os.environ.get("INTERVALO_FLUSH_SEGUNDOS", "3"))
TAMANO_LOTE = int(os.environ.get("TAMANO_LOTE", "50"))

_buffer: list[str] = []
_candado = threading.Lock()
_detener = threading.Event()


def _es_ruta_local(ruta: str) -> bool:
    return not ruta.startswith("gs://")


def _escribir_archivo(contenido: str) -> None:
    nombre = f"preseleccionadas-{int(time.time() * 1000)}-{uuid.uuid4().hex[:8]}.jsonl"

    if _es_ruta_local(DIRECTORIO_ENTRADA):
        os.makedirs(DIRECTORIO_ENTRADA, exist_ok=True)
        destino = os.path.join(DIRECTORIO_ENTRADA, nombre)
        tmp = destino + ".part"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(contenido)
        os.replace(tmp, destino)  # escritura atomica: Flink nunca ve un archivo a medias
        return

    from google.cloud import storage

    bucket_nombre, _, prefijo = DIRECTORIO_ENTRADA[len("gs://"):].partition("/")
    cliente = storage.Client()
    blob = cliente.bucket(bucket_nombre).blob(f"{prefijo.rstrip('/')}/{nombre}")
    blob.upload_from_string(contenido, content_type="application/x-ndjson")


def _volcar_si_hace_falta(forzar: bool = False) -> None:
    with _candado:
        if not _buffer:
            return
        if not forzar and len(_buffer) < TAMANO_LOTE:
            return
        contenido = "\n".join(_buffer) + "\n"
        _buffer.clear()
    _escribir_archivo(contenido)


def _bucle_flush_periodico() -> None:
    while not _detener.is_set():
        _detener.wait(INTERVALO_FLUSH_SEGUNDOS)
        _volcar_si_hace_falta(forzar=True)


def _callback_pubsub(message) -> None:
    try:
        # Se valida que sea JSON parseable, pero se reenvia tal cual --
        # Flink es quien conoce el contrato real (contracts.TransaccionEvento).
        json.loads(message.data)
        linea = message.data.decode("utf-8")
        with _candado:
            _buffer.append(linea)
        _volcar_si_hace_falta()
        message.ack()
    except Exception:
        import logging
        logging.exception("Fallo encolando mensaje, se reintentara (nack)")
        message.nack()


def main() -> None:
    threading.Thread(target=_bucle_flush_periodico, daemon=True).start()

    if not GOOGLE_CLOUD_PROJECT:
        print("GOOGLE_CLOUD_PROJECT no definido: no se inicia el pull loop (modo local sin Pub/Sub).")
        return

    from google.cloud import pubsub_v1

    cliente = pubsub_v1.SubscriberClient()
    subscription_path = cliente.subscription_path(GOOGLE_CLOUD_PROJECT, SUBSCRIPTION_PRESELECCIONADAS)
    future = cliente.subscribe(subscription_path, callback=_callback_pubsub)
    print(f"[puente_entrada] escuchando {subscription_path} -> {DIRECTORIO_ENTRADA}")

    try:
        future.result()
    except KeyboardInterrupt:
        _detener.set()
        future.cancel()
        _volcar_si_hace_falta(forzar=True)


if __name__ == "__main__":
    main()
