"""Prueba manual del KeyedProcessFunction contra el MiniCluster real de
PyFlink -- no es parte del job que se despliega, es la forma de confirmar
que el estado (ValueState/ListState) funciona de verdad, aislado por
tarjeta, antes de conectar Pub/Sub o Redis.

Correr dentro de la imagen de desarrollo (ver Backend/flink/README.md):

    docker run --rm -v <repo>:/workspace neobanx-flink-dev \
        python /workspace/Backend/flink/probar_job_local.py
"""

import sys
from datetime import datetime, timezone

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")

from pyflink.datastream import StreamExecutionEnvironment

from job import construir_pipeline

MEDELLIN = (6.2442, -75.5812)
NUEVA_YORK = (40.7128, -74.0060)


def epoch(año, mes, dia, hora, minuto=0, segundo=0):
    return datetime(año, mes, dia, hora, minuto, segundo, tzinfo=timezone.utc).timestamp()


def main():
    eventos = [
        # --- Tarjeta A: 6 transacciones en 5 minutos -> dispara rafaga ---
        ("tx-a1", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 0, 0), None, False),
        ("tx-a2", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 1, 0), None, False),
        ("tx-a3", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 2, 0), None, False),
        ("tx-a4", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 3, 0), None, False),
        ("tx-a5", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 4, 0), None, False),
        ("tx-a6", "tarjeta-A", 10.0, *MEDELLIN, epoch(2024, 1, 1, 12, 4, 30), None, False),

        # --- Tarjeta B: Medellin -> Nueva York en 2 min -> ubicacion imposible ---
        ("tx-b1", "tarjeta-B", 15.0, *MEDELLIN, epoch(2024, 1, 1, 9, 0, 0), None, False),
        ("tx-b2", "tarjeta-B", 15.0, *NUEVA_YORK, epoch(2024, 1, 1, 9, 2, 0), None, False),

        # --- Tarjeta C: monto muy por encima del promedio del perfil ---
        ("tx-c1", "tarjeta-C", 900.0, *MEDELLIN, epoch(2024, 1, 1, 10, 0, 0),
         {"monto_promedio": "50.00", "monto_desviacion": "10.00"}, False),

        # --- Tarjeta D: festivo (1 enero) + monto alto ---
        ("tx-d1", "tarjeta-D", 500.0, *MEDELLIN, epoch(2024, 1, 1, 11, 0, 0), None, True),

        # --- Tarjeta E: una sola transaccion normal -> aprobada, sin reglas ---
        ("tx-e1", "tarjeta-E", 20.0, *MEDELLIN, epoch(2024, 1, 1, 13, 0, 0), None, False),
    ]

    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)

    resultado = construir_pipeline(env, eventos)
    resultado.print()
    env.execute("prueba-reglas-local")


if __name__ == "__main__":
    main()
