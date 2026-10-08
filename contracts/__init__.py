"""Contratos de datos compartidos del flujo transaccional (Sprint 2).

Estos modelos son la fuente de verdad del formato de los mensajes que viajan
entre los servicios (generador -> registro por HTTP, y registro/flink/stub ->
cierre por Pub/Sub). Cualquier servicio que arme o lea uno de estos mensajes
debe importar el modelo de aqui, no redefinir los campos a mano.
"""

from .transaccion import TransaccionEvento
from .veredicto import VeredictoEvento

__all__ = ["TransaccionEvento", "VeredictoEvento"]
