"""KeyedProcessFunction que conecta las 4 reglas puras (reglas.py) con
estado REAL de Flink (ValueState/ListState, RocksDB en la nube).

Entrada esperada (una tupla por evento, ya enriquecido -- el enriquecimiento
contra Redis/Nager.Date, Backend/flink/enriquecimiento.py, se agrega despues,
en una capa previa a esta; aqui se asume que ya llego el perfil y el flag de
festivo):

    (trans_num, cc_num_hash, monto, lat, long, timestamp_epoch_segundos,
     perfil_dict_o_None, es_festivo)

Salida: (trans_num, resultado, reglas_disparadas) -- el mismo shape que
necesita contracts.VeredictoEvento, sin tocar Pub/Sub todavia.

Por que PICKLED_BYTE_ARRAY para el estado: es el tipo generico que PyFlink
ofrece para guardar objetos Python arbitrarios (tuplas, listas) sin tener que
describir su estructura campo por campo con los tipos nativos de Flink. Para
un volumen de un par de valores por tarjeta, la sobrecarga de pickle no
importa; la alternativa (serializar a mano con Types.ROW) no agrega nada
aqui.
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone

from pyflink.common.typeinfo import Types
from pyflink.datastream import KeyedProcessFunction, StreamExecutionEnvironment
from pyflink.datastream.state import ListStateDescriptor, ValueStateDescriptor

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
from reglas import (  # noqa: E402
    regla_festivo_monto_alto,
    regla_monto_vs_promedio,
    regla_rafaga,
    regla_ubicacion_imposible,
)


class EvaluarReglas(KeyedProcessFunction):
    """Una instancia de este estado existe POR CADA cc_num_hash (es lo que
    hace keyBy): `ultima_ubicacion` y `recientes` nunca se mezclan entre
    tarjetas distintas."""

    def open(self, runtime_context):
        self.ultima_ubicacion = runtime_context.get_state(
            ValueStateDescriptor("ultima_ubicacion", Types.PICKLED_BYTE_ARRAY())
        )
        self.recientes = runtime_context.get_list_state(
            ListStateDescriptor("transacciones_recientes", Types.PICKLED_BYTE_ARRAY())
        )

    def process_element(self, value, ctx):
        trans_num, _cc_hash, monto, lat, long, ts_epoch, perfil, es_festivo = value
        ahora = datetime.fromtimestamp(ts_epoch, tz=timezone.utc)

        reglas_disparadas = []

        r1 = regla_monto_vs_promedio(monto, perfil)
        if r1:
            reglas_disparadas.append(r1)

        recientes_guardados = list(self.recientes.get() or [])
        r2, recientes_nuevos = regla_rafaga(recientes_guardados, ahora)
        self.recientes.update(recientes_nuevos)
        if r2:
            reglas_disparadas.append(r2)

        ubicacion_guardada = self.ultima_ubicacion.value()
        r3, ubicacion_nueva = regla_ubicacion_imposible(lat, long, ahora, ubicacion_guardada)
        self.ultima_ubicacion.update(ubicacion_nueva)
        if r3:
            reglas_disparadas.append(r3)

        r4 = regla_festivo_monto_alto(es_festivo, monto)
        if r4:
            reglas_disparadas.append(r4)

        resultado = "bloqueada" if reglas_disparadas else "aprobada"
        yield (trans_num, resultado, reglas_disparadas)


def construir_pipeline(env: StreamExecutionEnvironment, eventos: list[tuple]):
    """Pipeline SIN enriquecimiento -- recibe eventos ya enriquecidos
    (perfil + festivo resueltos de antemano). Util para probar las reglas
    en aislamiento, sin depender de Redis ni de Nager.Date."""
    tipo_salida = Types.TUPLE(
        [Types.STRING(), Types.STRING(), Types.LIST(Types.STRING())]
    )
    return (
        env.from_collection(eventos)
        .key_by(lambda e: e[1])  # cc_num_hash
        .process(EvaluarReglas(), output_type=tipo_salida)
    )


def construir_pipeline_completo(
    env: StreamExecutionEnvironment,
    eventos_crudos: list[tuple],
    redis_host: str,
    redis_port: int,
    redis_password: str | None = None,
    redis_ssl: bool = False,
):
    """Pipeline completo: eventos crudos -> enriquecimiento (perfil de Redis
    + festivo, sincrono -- ver enriquecimiento.py) -> reglas con estado real.

    `eventos_crudos`: (trans_num, cc_num_hash, monto, lat, long, ts_epoch) --
    SIN perfil ni festivo, los agrega el enriquecimiento.
    """
    from enriquecimiento import EnriquecerFestivo, EnriquecerPerfilRedis

    tipo_con_perfil = Types.TUPLE([
        Types.STRING(), Types.STRING(), Types.DOUBLE(), Types.DOUBLE(),
        Types.DOUBLE(), Types.DOUBLE(), Types.PICKLED_BYTE_ARRAY(),
    ])
    tipo_con_festivo = Types.TUPLE([
        Types.STRING(), Types.STRING(), Types.DOUBLE(), Types.DOUBLE(),
        Types.DOUBLE(), Types.DOUBLE(), Types.PICKLED_BYTE_ARRAY(), Types.BOOLEAN(),
    ])
    tipo_salida = Types.TUPLE(
        [Types.STRING(), Types.STRING(), Types.LIST(Types.STRING())]
    )

    crudo = env.from_collection(eventos_crudos)

    con_perfil = crudo.map(
        EnriquecerPerfilRedis(redis_host, redis_port, redis_password, redis_ssl),
        output_type=tipo_con_perfil,
    )

    con_festivo = con_perfil.map(EnriquecerFestivo(), output_type=tipo_con_festivo)

    return con_festivo.key_by(lambda e: e[1]).process(EvaluarReglas(), output_type=tipo_salida)
