"""Tokenización determinística del número de tarjeta (cc_num).

POR QUÉ EXISTE ESTE MÓDULO
--------------------------
`Documentation/reglas_calidad_neobanx.md` exige que `cc_num` nunca salga de la
capa transaccional en texto plano, y que su tokenización sea **HMAC-SHA256 con
una clave secreta fija guardada en Secret Manager**.

El generador del Sprint 1 no cumplía eso:

    digest = hashlib.sha256(f"{SALT}{cc_num}".encode("utf-8")).hexdigest()
    return digest[:10]

Tres problemas:

1. **No es HMAC.** Concatenar `salt + mensaje` y pasarlo por SHA-256 es un
   patrón vulnerable a extensión de longitud y no es lo que piden las reglas
   de calidad. HMAC existe precisamente para combinar clave y mensaje bien.

2. **Truncaba a 10 caracteres hex** (40 bits). Con ~1000 tarjetas el riesgo de
   colisión todavía es bajo, pero truncar un token que es llave primaria de
   `cuentas` y llave foránea de `transacciones` no tiene ninguna ventaja y sí
   un riesgo real si el volumen crece.

3. **No normalizaba el valor de entrada**, y ahí estaba el defecto más grave.
   `Backend/generador/main.py` lee el CSV con `pd.read_csv(..., chunksize=N)`
   sin declarar `dtype` para `cc_num`, así que pandas **infiere el tipo bloque
   por bloque**. Un bloque puede inferir `int64` y otro `float64` (por un valor
   que no quepa en int64 o por un NaN), y entonces `f"{cc_num}"` produce
   `"4532015112830366"` en un caso y `"4532015112830366.0"` en el otro: dos
   hashes distintos para la misma tarjeta. El resultado es un join silenciosamente
   roto entre `cuentas` y `transacciones`, sin ningún error visible.

Por eso `hash_cc_num` normaliza SIEMPRE antes de hashear, y acepta `str`, `int`,
`float`, tipos de numpy y notación científica dando el mismo resultado para
todos.

ARREGLO COMPLEMENTARIO EN EL ORIGEN
-----------------------------------
Este módulo blinda el cálculo, pero lo correcto es además no dejar que pandas
adivine. Al leer el CSV conviene declarar el tipo explícitamente:

    pd.read_csv(ruta, dtype={"cc_num": "string"}, ...)

Así `cc_num` llega como texto en todos los bloques y la normalización de aquí
se vuelve una red de seguridad en lugar de la única defensa.

ADVERTENCIA OPERATIVA — ROTAR LA CLAVE INVALIDA TODOS LOS HASHES
----------------------------------------------------------------
El token es determinístico *para una clave dada*. Si se rota la clave del
secreto, todos los `cc_num_hash` ya almacenados dejan de corresponder: habría
que recalcular `clientes`, `cuentas` y `transacciones` completos en la misma
operación. No es una clave que se rote por rutina; trátenla como parte del
esquema de datos, no como una credencial cualquiera.

USO
---
    from hmac_util import hash_cc_num

    token = hash_cc_num("4532015112830366")   # 64 caracteres hex

Resolución de la clave, en orden de precedencia:

1. Variable de entorno `NEOBANX_HMAC_KEY` — solo para desarrollo local y
   pruebas. Si se usa en un entorno real, los hashes NO van a coincidir con
   los de producción.
2. Secret Manager: secreto `NEOBANX_HMAC_SECRET_ID` (por defecto
   `neobanx-hmac-cc-num`) del proyecto `GOOGLE_CLOUD_PROJECT` o `PROJECT_ID`.

La clave se lee una sola vez y queda en caché en memoria: el generador hashea
miles de filas y una llamada a Secret Manager por fila sería inviable.
"""

from __future__ import annotations

import hmac
import hashlib
import os
import re
import threading
from decimal import Decimal, InvalidOperation
from typing import Iterable, Iterator

__all__ = [
    "hash_cc_num",
    "hash_cc_nums",
    "normalizar_cc_num",
    "obtener_clave",
    "limpiar_cache_clave",
    "LONGITUD_HASH_HEX",
]

# HMAC-SHA256 en hexadecimal: 32 bytes -> 64 caracteres. Sin truncar.
LONGITUD_HASH_HEX = 64

# Nombre por defecto del secreto en Secret Manager.
SECRETO_POR_DEFECTO = "neobanx-hmac-cc-num"

# Variables de entorno reconocidas.
ENV_CLAVE_DIRECTA = "NEOBANX_HMAC_KEY"
ENV_SECRETO_ID = "NEOBANX_HMAC_SECRET_ID"
ENV_SECRETO_VERSION = "NEOBANX_HMAC_SECRET_VERSION"
ENV_PROYECTOS = ("GOOGLE_CLOUD_PROJECT", "PROJECT_ID", "GCP_PROJECT_ID")

# Rango admisible de dígitos. Las tarjetas reales tienen entre 12 y 19; se deja
# un margen para no rechazar datos sintéticos razonables, pero sí atrapar
# basura evidente (cadenas vacías, texto, identificadores de otra cosa).
MIN_DIGITOS = 8
MAX_DIGITOS = 24

_SOLO_DIGITOS = re.compile(r"\A\d+\Z")
# Solo espacios y guiones: son los únicos separadores plausibles en un número
# de tarjeta escrito a mano ("4532 0151 1283 0366"). El punto NO va aquí a
# propósito: quitarlo convertiría el "0" decimal de "4532015112830366.0" en un
# dígito más del número, produciendo un token equivocado en silencio.
_SEPARADORES = re.compile(r"[\s\-]+")

_clave_cache: bytes | None = None
_candado = threading.Lock()


# ---------------------------------------------------------------------------
# Normalización
# ---------------------------------------------------------------------------

def normalizar_cc_num(cc_num: object) -> str:
    """Devuelve el `cc_num` como cadena canónica de solo dígitos.

    Garantiza que entradas equivalentes produzcan la MISMA cadena, sin
    importar de qué tipo vengan:

        "4532015112830366"      -> "4532015112830366"
        4532015112830366        -> "4532015112830366"   (int / numpy.int64)
        4532015112830366.0      -> "4532015112830366"   (float / numpy.float64)
        "4.532015112830366e+15" -> "4532015112830366"   (notación científica)
        "4532 0151 1283 0366"   -> "4532015112830366"   (con separadores)

    Lanza `ValueError` ante cualquier entrada que no represente un número de
    tarjeta plausible. Fallar aquí es deliberado: un `cc_num` ilegible que se
    hashee de todas formas produce una cuenta fantasma que rompe el join sin
    dar ninguna señal.
    """
    if cc_num is None:
        raise ValueError("cc_num es None: no se puede tokenizar")

    texto = str(cc_num).strip()
    if not texto:
        raise ValueError("cc_num vacío: no se puede tokenizar")

    if texto.lower() in {"nan", "none", "null", "<na>"}:
        raise ValueError(f"cc_num no es un número válido: {texto!r}")

    # --- Paso 1: caso rápido, ya es una cadena de solo dígitos.
    # Va primero porque es también el único camino que preserva los ceros a la
    # izquierda: "0123..." debe seguir siendo "0123...", y cualquier
    # interpretación numérica los perdería.
    if _SOLO_DIGITOS.match(texto):
        return _validar_longitud(texto, cc_num)

    # --- Paso 2: valor numérico (float, notación científica, con signo).
    # Este paso va ANTES de quitar separadores. El orden es esencial: si se
    # quitaran primero, el punto de "4532015112830366.0" desaparecería y el "0"
    # decimal pasaría a ser un dígito del número, y el signo de un negativo se
    # perdería sin que nadie lo note.
    # Decimal (y no float) para evitar el redondeo binario, y format(..., "f")
    # para no reintroducir notación científica al convertir de vuelta a texto.
    try:
        numero = Decimal(texto)
    except InvalidOperation:
        numero = None

    if numero is not None:
        if not numero.is_finite():
            raise ValueError(f"cc_num no es finito: {cc_num!r}")

        # La comparación con 0 debe ir después de is_finite(): comparar un NaN
        # de Decimal lanza InvalidOperation.
        if numero < 0:
            raise ValueError(f"cc_num negativo: {cc_num!r}")

        entero = numero.to_integral_value()
        if numero != entero:
            # Un número de tarjeta no tiene parte decimal. Si llegó una, algo
            # se corrompió antes y es mejor detenerse que inventar un token.
            raise ValueError(
                f"cc_num tiene parte decimal, no es un número de tarjeta: {cc_num!r}"
            )

        canonico = format(entero, "f")
        if canonico.endswith("."):
            canonico = canonico[:-1]

        if not _SOLO_DIGITOS.match(canonico):
            raise ValueError(f"cc_num no normalizable: {cc_num!r}")

        return _validar_longitud(canonico, cc_num)

    # --- Paso 3: tarjeta escrita con separadores ("4532 0151 1283 0366").
    # Solo se llega aquí si Decimal no pudo interpretarlo, así que no hay riesgo
    # de estar mutilando un decimal o un signo.
    sin_separadores = _SEPARADORES.sub("", texto)
    if _SOLO_DIGITOS.match(sin_separadores):
        return _validar_longitud(sin_separadores, cc_num)

    raise ValueError(f"cc_num no es un número válido: {cc_num!r}")


def _validar_longitud(digitos: str, original: object) -> str:
    # Los ceros a la izquierda son significativos en un cc_num, así que no se
    # eliminan: "0123..." y "123..." son tarjetas distintas.
    if not (MIN_DIGITOS <= len(digitos) <= MAX_DIGITOS):
        raise ValueError(
            f"cc_num con {len(digitos)} dígitos, fuera del rango "
            f"[{MIN_DIGITOS}, {MAX_DIGITOS}]: {original!r}"
        )
    return digitos


# ---------------------------------------------------------------------------
# Clave
# ---------------------------------------------------------------------------

def obtener_clave(forzar_recarga: bool = False) -> bytes:
    """Devuelve la clave HMAC, leyéndola una sola vez y dejándola en caché.

    Con `forzar_recarga=True` descarta la caché y vuelve a resolverla (útil en
    pruebas; en producción no debería hacer falta).
    """
    global _clave_cache

    if _clave_cache is not None and not forzar_recarga:
        return _clave_cache

    with _candado:
        # Otro hilo pudo haberla cargado mientras esperábamos el candado.
        if _clave_cache is not None and not forzar_recarga:
            return _clave_cache

        clave = _resolver_clave()
        if not clave:
            raise RuntimeError("La clave HMAC resolvió a un valor vacío")

        _clave_cache = clave
        return _clave_cache


def _resolver_clave() -> bytes:
    directa = os.environ.get(ENV_CLAVE_DIRECTA)
    if directa:
        # Camino de desarrollo local y pruebas. No se usa en GCP.
        return directa.encode("utf-8")

    secreto_id = os.environ.get(ENV_SECRETO_ID, SECRETO_POR_DEFECTO)
    version = os.environ.get(ENV_SECRETO_VERSION, "latest")
    proyecto = _resolver_proyecto()

    try:
        from google.cloud import secretmanager
    except ImportError as exc:
        raise RuntimeError(
            "Falta la dependencia google-cloud-secret-manager. "
            f"Instálala, o define {ENV_CLAVE_DIRECTA} si estás en local."
        ) from exc

    cliente = secretmanager.SecretManagerServiceClient()
    nombre = f"projects/{proyecto}/secrets/{secreto_id}/versions/{version}"
    try:
        respuesta = cliente.access_secret_version(request={"name": nombre})
    except Exception as exc:
        raise RuntimeError(
            f"No se pudo leer la clave HMAC de Secret Manager ({nombre}). "
            "Verifica que el secreto exista y que la cuenta de servicio tenga "
            "roles/secretmanager.secretAccessor sobre él."
        ) from exc

    return respuesta.payload.data


def _resolver_proyecto() -> str:
    for variable in ENV_PROYECTOS:
        valor = os.environ.get(variable)
        if valor:
            return valor
    raise RuntimeError(
        "No se pudo determinar el proyecto de GCP para leer la clave HMAC. "
        f"Define una de: {', '.join(ENV_PROYECTOS)}, "
        f"o usa {ENV_CLAVE_DIRECTA} en local."
    )


def limpiar_cache_clave() -> None:
    """Olvida la clave en caché. Pensado para pruebas."""
    global _clave_cache
    with _candado:
        _clave_cache = None


# ---------------------------------------------------------------------------
# Tokenización
# ---------------------------------------------------------------------------

def hash_cc_num(cc_num: object) -> str:
    """Tokeniza un `cc_num` con HMAC-SHA256 y lo devuelve en hex (64 chars).

    Determinístico: la misma tarjeta y la misma clave dan siempre el mismo
    token, que es lo que permite unir `cuentas` con `transacciones`.
    """
    normalizado = normalizar_cc_num(cc_num)
    clave = obtener_clave()
    return hmac.new(clave, normalizado.encode("utf-8"), hashlib.sha256).hexdigest()


def hash_cc_nums(cc_nums: Iterable[object]) -> Iterator[str]:
    """Versión perezosa para lotes (carga de `clientes` y `cuentas`).

    Resuelve la clave una sola vez para todo el lote en lugar de consultar la
    caché en cada elemento.
    """
    clave = obtener_clave()
    for cc_num in cc_nums:
        normalizado = normalizar_cc_num(cc_num)
        yield hmac.new(clave, normalizado.encode("utf-8"), hashlib.sha256).hexdigest()
