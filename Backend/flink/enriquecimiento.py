"""Enriquecimiento: perfil de Redis + festivo del dia.

SINCRONO, no Async I/O -- el clúster real corre Flink 1.17 (ver
Infrastructure/dataproc.tf, image_version="2.2-debian12"), y
`AsyncDataStream`/`AsyncFunction` en Python no existen en esa version (se
confirmo leyendo el `pyflink.zip` bundleado del clúster real: solo aparecen
menciones de "async" en docstrings de conectores Kinesis, nada mas). Esa API
se agrego en una version de PyFlink mucho mas reciente -- la que trae
`pip install apache-flink` por defecto (2.3.0), que es lo que probamos
originalmente en local SIN fijar version, sin darnos cuenta de que no
coincidia con el clúster real.

Esto NO vuelve sincrono el flujo de deteccion completo -- esa asincronia es
a nivel de todo el sistema (Pub/Sub desacopla registro de Flink de cierre) y
no depende de esto. Lo unico que cambia es que, DENTRO de este paso del job,
cada llamada a Redis/Nager.Date se hace una a la vez en vez de varias en
vuelo -- un detalle de rendimiento interno, no de arquitectura. A nuestra
escala (pocas transacciones por segundo) no es un cuello de botella: Flink
sigue paralelizando entre instancias (`flink:taskmanager.numberOfTaskSlots`).

Dos MapFunction separadas (no una sola) por la misma razon que antes: cada
una enriquece UN dato, se pueden probar y razonar por separado.

Forma de la tupla que fluye por el pipeline (cada etapa le agrega un campo):
    cruda:           (trans_num, cc_num_hash, monto, lat, long, ts_epoch)
    + perfil:         ... , perfil_dict_o_None
    + festivo:         ... , es_festivo_bool
Esta ultima forma es exactamente la que espera `job.EvaluarReglas`.
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

from pyflink.datastream.functions import MapFunction

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
sys.path.insert(0, (__file__.rsplit("/", 2)[0] if "/" in __file__ else "..") + "/common")

from holidays import es_festivo  # noqa: E402


class EnriquecerPerfilRedis(MapFunction):
    """Agrega el perfil historico (linea base) de `perfil:{cc_num_hash}`.

    Solo lectura -- ver Backend/carga/perfiles_redis.py para por que Flink
    nunca debe escribir aqui (envenenamiento de la linea base).
    """

    def __init__(self, host: str, port: int, password: str | None = None, ssl: bool = False):
        self._host = host
        self._port = port
        self._password = password
        self._ssl = ssl

    def open(self, runtime_context):
        import redis

        self.cliente = redis.Redis(
            host=self._host,
            port=self._port,
            password=self._password,
            ssl=self._ssl,
            ssl_cert_reqs=None,
            decode_responses=True,
            socket_timeout=5,
        )

    def map(self, value):
        trans_num, cc_hash, monto, lat, long, ts_epoch = value
        perfil = self.cliente.hgetall(f"perfil:{cc_hash}")
        return (trans_num, cc_hash, monto, lat, long, ts_epoch, perfil or None)

    def close(self):
        self.cliente.close()


class EnriquecerFestivo(MapFunction):
    """Agrega si la fecha de la transaccion es festivo en EEUU (Nager.Date).

    `es_festivo` (Backend/common/holidays.py) cachea por anio con un
    diccionario en memoria del proceso -- solo la PRIMERA transaccion de
    cada anio paga la llamada HTTP real, el resto es instantaneo.
    """

    def map(self, value):
        trans_num, cc_hash, monto, lat, long, ts_epoch, perfil = value
        fecha = datetime.fromtimestamp(ts_epoch, tz=timezone.utc).date()
        festivo = es_festivo(fecha)
        return (trans_num, cc_hash, monto, lat, long, ts_epoch, perfil, festivo)
