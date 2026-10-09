"""Evento de veredicto -- publicado en el topico `tx-veredictos`.

Lo publican el stub (provisional) y, mas adelante, el job de Flink. Lo
consume el servicio de cierre (suscripcion `sub-cierre-veredictos`). Los
campos coinciden 1 a 1 con las columnas de `veredictos` en schema.sql --
`tardio` NO va aqui, lo calcula el propio servicio de cierre segun si la
transaccion seguia `pendiente_analisis` cuando el veredicto llego.
"""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class VeredictoEvento(BaseModel):
    trans_num: str = Field(min_length=1, max_length=64)
    resultado: Literal["aprobada", "bloqueada"]
    reglas_disparadas: list[str] = Field(
        default_factory=list,
        description="Identificadores de las reglas que dispararon el resultado, ej. ['monto_sobre_promedio', 'festivo_monto_alto']. Vacio si resultado='aprobada'.",
    )
    evaluado_at: datetime
    version_reglas: str = Field(
        min_length=1,
        description="Identifica que evaluo la transaccion, ej. 'stub-v1' o 'flink-v1'.",
    )
