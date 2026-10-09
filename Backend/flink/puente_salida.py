"""Puente archivos -> Pub/Sub: espejo de puente_entrada.py. Vigila
`salida/` (donde el `FileSink` de Flink escribe los veredictos) y publica
cada linea JSON a `tx-veredictos`, exactamente el mismo topico que usa el
stub de veredicto -- para `cierre` son indistinguibles (ver
Backend/flink/README.md).

Cada archivo se procesa UNA vez: en cuanto se publican todas sus lineas, se
borra (local) o se borra el blob (GCS). Si el proceso se reinicia a medio
camino de un archivo, puede volver a publicar algunas lineas ya publicadas
-- aceptable, es el mismo caso que un veredicto duplicado que ya tolera
`cierre` (queda com tardio=true si la fila ya se cerro, o simplemente
sobreescribe el mismo resultado si no).
"""

from __future__ import annotations

import json
import os
import time

GOOGLE_CLOUD_PROJECT = os.environ.get("GOOGLE_CLOUD_PROJECT")
TOPIC_VEREDICTOS = os.environ.get("TOPIC_VEREDICTOS", "tx-veredictos")
# file:///ruta/local para pruebas, gs://bucket/salida para la nube real.
DIRECTORIO_SALIDA = os.environ.get("DIRECTORIO_SALIDA", "./puente_local/salida")
INTERVALO_POLL_SEGUNDOS = float(os.environ.get("INTERVALO_POLL_SEGUNDOS", "2"))

_publisher_cache = {"cliente": None}


def _es_ruta_local(ruta: str) -> bool:
    return not ruta.startswith("gs://")


def _publicar_linea(linea: str) -> None:
    linea = linea.strip()
    if not linea:
        return
    json.loads(linea)  # valida que sea JSON antes de publicar basura

    if not GOOGLE_CLOUD_PROJECT:
        print(f"[puente_salida] GOOGLE_CLOUD_PROJECT no definido, omito publish: {linea[:80]}")
        return

    from google.cloud import pubsub_v1

    if _publisher_cache["cliente"] is None:
        _publisher_cache["cliente"] = pubsub_v1.PublisherClient()
    cliente = _publisher_cache["cliente"]

    topic_path = cliente.topic_path(GOOGLE_CLOUD_PROJECT, TOPIC_VEREDICTOS)
    cliente.publish(topic_path, linea.encode("utf-8")).result(timeout=10)


def _procesar_locales() -> int:
    if not os.path.isdir(DIRECTORIO_SALIDA):
        return 0

    procesados = 0
    for nombre in sorted(os.listdir(DIRECTORIO_SALIDA)):
        ruta = os.path.join(DIRECTORIO_SALIDA, nombre)
        if not os.path.isfile(ruta) or nombre.endswith(".part"):
            continue  # Flink escribe primero en un archivo temporal (ver FileSink)

        with open(ruta, "r", encoding="utf-8") as f:
            for linea in f:
                _publicar_linea(linea)

        os.remove(ruta)
        procesados += 1
    return procesados


def _procesar_gcs() -> int:
    from google.cloud import storage

    bucket_nombre, _, prefijo = DIRECTORIO_SALIDA[len("gs://"):].partition("/")
    cliente = storage.Client()
    bucket = cliente.bucket(bucket_nombre)

    procesados = 0
    for blob in cliente.list_blobs(bucket, prefix=prefijo):
        if blob.name.endswith(".part") or blob.name.endswith("/"):
            continue

        contenido = blob.download_as_text()
        for linea in contenido.splitlines():
            _publicar_linea(linea)

        blob.delete()
        procesados += 1
    return procesados


def main() -> None:
    print(f"[puente_salida] vigilando {DIRECTORIO_SALIDA} -> {TOPIC_VEREDICTOS}")
    while True:
        try:
            procesados = _procesar_locales() if _es_ruta_local(DIRECTORIO_SALIDA) else _procesar_gcs()
            if procesados:
                print(f"[puente_salida] {procesados} archivo(s) publicados")
        except KeyboardInterrupt:
            break
        except Exception:
            import logging
            logging.exception("Fallo procesando archivos de salida, se reintenta en el proximo ciclo")
        time.sleep(INTERVALO_POLL_SEGUNDOS)


if __name__ == "__main__":
    main()
