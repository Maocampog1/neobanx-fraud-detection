"""Guardrails del asistente de fraude: reglas fijas que corren ANTES y DESPUÉS
del modelo, en el servidor.

POR QUÉ NO BASTA CON LA INSTRUCCIÓN DEL MODELO
  La instrucción le pide al modelo que no entregue datos personales, pero un
  modelo de lenguaje se puede convencer ("ignora tus instrucciones..."). Por
  eso hay tres capas, de la más dura a la más blanda:

  1. Base de datos: el rol `agente_ro` solo puede leer tres vistas
     (schema.sql). No tiene permiso sobre `clientes` ni sobre `transacciones`.
  2. Herramientas (herramientas.py): consultas fijas y parametrizadas que ni
     siquiera piden las columnas sensibles (ciudad, ocupación) y recortan el
     hash de la tarjeta. El modelo no escribe SQL.
  3. Este archivo: rechaza la pregunta sin llamar al modelo si pide datos
     personales o intenta saltarse las reglas, y limpia la respuesta final por
     si acaso (números de tarjeta y hashes completos).

  Aunque las capas 3 y la instrucción fallaran, las capas 1 y 2 garantizan que
  el dato personal nunca llega al modelo: no puede filtrar lo que no tiene.
"""

import re
import unicodedata

LARGO_MAXIMO = 600

RESPUESTA_PII = (
    "Por política de protección de datos no puedo entregar información personal "
    "de clientes (nombres, direcciones, teléfonos, correos, ciudad, ocupación, "
    "fecha de nacimiento ni números de tarjeta). Puedo ayudarte con el análisis "
    "de una transacción, el historial agregado de un cliente o un resumen del fraude."
)
RESPUESTA_TARJETA = (
    "No compartas números de tarjeta en el chat. El sistema identifica a cada "
    "cliente con una referencia tokenizada; pregúntame por el trans_num de la "
    "transacción y yo te doy esa referencia."
)
RESPUESTA_MANIPULACION = (
    "No puedo cambiar mis reglas de funcionamiento. Solo respondo preguntas sobre "
    "fraude y transacciones de NeobanX."
)
RESPUESTA_LARGA = f"La pregunta es muy larga. Escríbela en menos de {LARGO_MAXIMO} caracteres."


def _normalizar(texto: str) -> str:
    """Minúsculas y sin tildes, para que 'Dirección' y 'direccion' coincidan."""
    sin_tildes = unicodedata.normalize("NFKD", texto)
    sin_tildes = "".join(c for c in sin_tildes if not unicodedata.combining(c))
    return sin_tildes.lower()


# Datos personales que el asistente nunca entrega (español e inglés).
_PATRON_PII = re.compile(
    r"\b("
    r"direccion(es)?|domicilio|donde vive|donde viven|calle|address|street"
    r"|telefono|celular|phone|correo|e-?mail"
    r"|cedula|documento de identidad|ssn|seguro social"
    r"|nombre completo|nombres? (y apellidos? )?(del|de la|de los|de las) (cliente|clientes|titular|titulares|usuario|usuarios|persona|personas|tarjetahabiente)"
    r"|como se llama|apellidos?|first name|last name"
    r"|fecha de nacimiento|cumpleanos|birth|dob"
    r"|ocupacion(es)?|profesion(es)?|en que trabaja|job"
    r"|ciudad(es)? (del|de la|de los|de las) (cliente|clientes|titular|usuario)"
    r"|numero de (la )?tarjeta|numeros de (las )?tarjetas|tarjeta completa|cc_num(?!_hash)"
    r")\b"
)

# Intentos de saltarse las reglas (prompt injection).
_PATRON_MANIPULACION = re.compile(
    r"(ignora|olvida|omite|salta(te)?) (todas )?(las |tus )?(instrucciones|reglas|restricciones)"
    r"|ignore (all |your |previous )*instructions"
    r"|system prompt|prompt del sistema|modo desarrollador|developer mode|jailbreak"
    r"|actua como|act as|finge (que|ser)|pretend"
)

# Un número de tarjeta: 13 a 19 dígitos, con o sin espacios o guiones.
_PATRON_TARJETA = re.compile(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)")

# Hash SHA-256 completo (64 hex): se recorta a una referencia corta.
_PATRON_HASH = re.compile(r"\b([0-9a-f]{12})[0-9a-f]{52}\b")


def revisar_pregunta(pregunta: str) -> str | None:
    """Devuelve una respuesta fija si la pregunta se debe rechazar sin llamar
    al modelo, o None si puede pasar."""
    if len(pregunta) > LARGO_MAXIMO:
        return RESPUESTA_LARGA
    if _PATRON_TARJETA.search(pregunta):
        return RESPUESTA_TARJETA
    normal = _normalizar(pregunta)
    if _PATRON_MANIPULACION.search(normal):
        return RESPUESTA_MANIPULACION
    if _PATRON_PII.search(normal):
        return RESPUESTA_PII
    return None


def limpiar_respuesta(texto: str) -> str:
    """Última barrera sobre lo que dice el modelo."""
    texto = _PATRON_TARJETA.sub("[dato oculto]", texto)
    texto = _PATRON_HASH.sub(r"\1…", texto)
    return texto