"""Evento de transaccion -- generador -> servicio de registro (HTTP POST).

Reemplaza el contrato v1 (publicacion directa a Pub/Sub, ver
Backend/contrato_datos_generador.md). Los nombres de campo ya coinciden con
las columnas de `transacciones` en schema.sql, para que el servicio de
registro pueda insertar casi sin traducir nombres.
"""

import re
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator

_HEX_64 = re.compile(r"^[0-9a-f]{64}$")


class TransaccionEvento(BaseModel):
    trans_num: str = Field(min_length=1, max_length=64)
    cc_num_hash: str = Field(
        description="HMAC-SHA256 de 64 hex, producido por Backend/common/hmac_util.hash_cc_num"
    )
    comercio: str = Field(min_length=1)
    categoria: str = Field(min_length=1)
    monto: float = Field(gt=0)
    fecha_hora_transaccion: datetime
    lat_comercio: float = Field(ge=-90, le=90)
    long_comercio: float = Field(ge=-180, le=180)
    is_fraud_real: Literal[0, 1] = Field(
        description="Solo para medir falsos positivos despues. NUNCA se usa como entrada de una regla de deteccion."
    )

    @field_validator("cc_num_hash")
    @classmethod
    def _validar_hash(cls, v: str) -> str:
        if not _HEX_64.match(v):
            raise ValueError("cc_num_hash debe ser HMAC-SHA256 hex de 64 caracteres sin truncar")
        return v
