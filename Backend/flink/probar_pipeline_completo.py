"""Prueba del pipeline COMPLETO: Async I/O (Redis real + Nager.Date real)
+ reglas con estado real, todo sobre el MiniCluster.

Requiere un Redis accesible por red desde el contenedor (ver
Backend/flink/README.md para como se levanta el de prueba local) y salida a
internet para Nager.Date (API publica, sin autenticacion).

Variables de entorno: REDIS_HOST, REDIS_PORT (default 6379).
"""

import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")

from pyflink.datastream import StreamExecutionEnvironment

from job import construir_pipeline_completo

MEDELLIN = (6.2442, -75.5812)
NUEVA_YORK = (40.7128, -74.0060)

# Mismo hash que se sembro en Redis con un perfil de prueba
# (monto_promedio=50.00, monto_desviacion=10.00).
TARJETA_CON_PERFIL = "8ba59ba86c32aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"


def epoch(año, mes, dia, hora, minuto=0, segundo=0):
    return datetime(año, mes, dia, hora, minuto, segundo, tzinfo=timezone.utc).timestamp()


def main():
    redis_host = os.environ.get("REDIS_HOST", "127.0.0.1")
    redis_port = int(os.environ.get("REDIS_PORT", "6379"))

    eventos = [
        # Perfil real de Redis: monto 900 contra promedio=50/desv=10 -> dispara.
        ("tx-perfil-1", TARJETA_CON_PERFIL, 900.0, *MEDELLIN, epoch(2024, 6, 1, 10, 0, 0)),
        # Misma tarjeta, monto normal -> no dispara esta regla.
        ("tx-perfil-2", TARJETA_CON_PERFIL, 55.0, *MEDELLIN, epoch(2024, 6, 1, 10, 5, 0)),

        # Sin perfil en Redis (cuenta no sembrada) -> la regla 1 no se evalua.
        ("tx-sin-perfil", "tarjeta-sin-perfil-xyz", 9999.0, *MEDELLIN, epoch(2024, 6, 1, 11, 0, 0)),

        # Festivo REAL: 4 de julio de 2024 (Independence Day, EEUU) + monto alto.
        ("tx-festivo", "tarjeta-festivo", 500.0, *MEDELLIN, epoch(2024, 7, 4, 12, 0, 0)),
        # Mismo dia, pero NO es festivo (3 de julio) + monto alto -> no dispara festivo.
        ("tx-no-festivo", "tarjeta-festivo-2", 500.0, *MEDELLIN, epoch(2024, 7, 3, 12, 0, 0)),

        # Ubicacion imposible, igual que la prueba sin enriquecimiento.
        ("tx-ubic-1", "tarjeta-ubicacion", 15.0, *MEDELLIN, epoch(2024, 6, 1, 9, 0, 0)),
        ("tx-ubic-2", "tarjeta-ubicacion", 15.0, *NUEVA_YORK, epoch(2024, 6, 1, 9, 2, 0)),
    ]

    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    resultado = construir_pipeline_completo(env, eventos, redis_host, redis_port)
    resultado.print()
    env.execute("prueba-pipeline-completo")


if __name__ == "__main__":
    main()
