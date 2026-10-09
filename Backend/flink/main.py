"""Punto de entrada real del job de Flink: FileSource (puente de entrada)
-> parseo -> enriquecimiento (sincrono, ver enriquecimiento.py) -> reglas
con estado -> formateo -> FileSink (puente de salida).

Por que FileSource/FileSink y no Pub/Sub directo: ver
Backend/flink/README.md -- PyFlink no permite implementar un Source/Sink de
Pub/Sub en Python puro, asi que dos procesos aparte (puente_entrada.py,
puente_salida.py) traducen Pub/Sub <-> archivos, y este job solo habla con
archivos (que si tiene un conector real con bindings de Python).

Variables de entorno:
    DIRECTORIO_ENTRADA   ruta base para FileSource (file:///... o gs://...)
    DIRECTORIO_SALIDA    ruta base para FileSink
    REDIS_HOST / REDIS_PORT / REDIS_PASSWORD / REDIS_SSL
    INTERVALO_DESCUBRIMIENTO_MS   cada cuanto FileSource revisa archivos nuevos
    INTERVALO_CHECKPOINT_MS       cada cuanto Flink hace checkpoint (tambien
                                  es cuando FileSink "cierra" sus archivos
                                  pending -> finished, visibles para
                                  puente_salida.py)
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

_aqui = os.path.dirname(os.path.abspath(__file__))
_raiz_repo = os.path.dirname(os.path.dirname(_aqui))  # Backend/flink -> Backend -> raiz
sys.path.insert(0, _aqui)
sys.path.insert(0, os.path.join(_raiz_repo, "Backend", "common"))
sys.path.insert(0, _raiz_repo)

from pyflink.common import Duration
from pyflink.common.typeinfo import Types
from pyflink.common.watermark_strategy import WatermarkStrategy
from pyflink.datastream import MapFunction, StreamExecutionEnvironment
from pyflink.datastream.connectors.file_system import (
    BucketAssigner,
    Encoder,
    FileSink,
    FileSource,
    StreamFormat,
)

# Import PLANO, no "from contracts import ..." -- -pyfs embarca el
# directorio contracts/ tal cual (su CONTENIDO queda importable, no su
# nombre como paquete), el mismo patron que ya usan job.py/holidays.py.
# Confirmado con "ModuleNotFoundError: No module named 'contracts'" en los
# TaskManagers reales, pese a que "from job import ..." (mismo patron de
# -pyfs) si funciona -- ver Backend/flink/README.md.
from transaccion import TransaccionEvento  # noqa: E402
from veredicto import VeredictoEvento  # noqa: E402
from enriquecimiento import EnriquecerFestivo, EnriquecerPerfilRedis  # noqa: E402
from job import EvaluarReglas  # noqa: E402

DIRECTORIO_ENTRADA = os.environ.get("DIRECTORIO_ENTRADA", "./puente_local/entrada")
DIRECTORIO_SALIDA = os.environ.get("DIRECTORIO_SALIDA", "./puente_local/salida")

REDIS_HOST = os.environ.get("REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD") or None
REDIS_SSL = os.environ.get("REDIS_SSL", "false").lower() == "true"

INTERVALO_DESCUBRIMIENTO_MS = int(os.environ.get("INTERVALO_DESCUBRIMIENTO_MS", "2000"))
INTERVALO_CHECKPOINT_MS = int(os.environ.get("INTERVALO_CHECKPOINT_MS", "10000"))

VERSION_REGLAS = "flink-v1"


class ParsearTransaccion(MapFunction):
    """JSON de contracts.TransaccionEvento -> tupla cruda de 6 campos que
    espera el pipeline de enriquecimiento (ver enriquecimiento.py)."""

    def map(self, linea: str):
        evento = TransaccionEvento.model_validate_json(linea)
        ts_epoch = evento.fecha_hora_transaccion.timestamp()
        return (
            evento.trans_num,
            evento.cc_num_hash,
            float(evento.monto),
            float(evento.lat_comercio),
            float(evento.long_comercio),
            ts_epoch,
        )


class FormatearVeredicto(MapFunction):
    """Tupla de salida de EvaluarReglas -> JSON de contracts.VeredictoEvento,
    la linea que se escribe al FileSink."""

    def map(self, valor):
        trans_num, resultado, reglas_disparadas = valor
        veredicto = VeredictoEvento(
            trans_num=trans_num,
            resultado=resultado,
            reglas_disparadas=list(reglas_disparadas),
            evaluado_at=datetime.now(timezone.utc),
            version_reglas=VERSION_REGLAS,
        )
        return veredicto.model_dump_json()


def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.enable_checkpointing(INTERVALO_CHECKPOINT_MS)

    fuente = (
        FileSource.for_record_stream_format(StreamFormat.text_line_format(), DIRECTORIO_ENTRADA)
        .monitor_continuously(Duration.of_millis(INTERVALO_DESCUBRIMIENTO_MS))
        .build()
    )

    crudo = env.from_source(fuente, WatermarkStrategy.no_watermarks(), "preseleccionadas-archivo")

    parseado = crudo.map(ParsearTransaccion(), output_type=Types.TUPLE([
        Types.STRING(), Types.STRING(), Types.DOUBLE(), Types.DOUBLE(), Types.DOUBLE(), Types.DOUBLE(),
    ]))

    tipo_con_perfil = Types.TUPLE([
        Types.STRING(), Types.STRING(), Types.DOUBLE(), Types.DOUBLE(),
        Types.DOUBLE(), Types.DOUBLE(), Types.PICKLED_BYTE_ARRAY(),
    ])
    con_perfil = parseado.map(
        EnriquecerPerfilRedis(REDIS_HOST, REDIS_PORT, REDIS_PASSWORD, REDIS_SSL),
        output_type=tipo_con_perfil,
    )

    tipo_con_festivo = Types.TUPLE([
        Types.STRING(), Types.STRING(), Types.DOUBLE(), Types.DOUBLE(),
        Types.DOUBLE(), Types.DOUBLE(), Types.PICKLED_BYTE_ARRAY(), Types.BOOLEAN(),
    ])
    con_festivo = con_perfil.map(EnriquecerFestivo(), output_type=tipo_con_festivo)

    tipo_veredicto = Types.TUPLE([Types.STRING(), Types.STRING(), Types.LIST(Types.STRING())])
    veredictos = (
        con_festivo
        .key_by(lambda e: e[1])  # cc_num_hash
        .process(EvaluarReglas(), output_type=tipo_veredicto)
    )

    lineas_salida = veredictos.map(FormatearVeredicto(), output_type=Types.STRING())

    sumidero = (
        FileSink.for_row_format(DIRECTORIO_SALIDA, Encoder.simple_string_encoder())
        .with_bucket_assigner(BucketAssigner.base_path_bucket_assigner())
        .build()
    )
    lineas_salida.sink_to(sumidero)

    env.execute("neobanx-flink-deteccion")


if __name__ == "__main__":
    main()
