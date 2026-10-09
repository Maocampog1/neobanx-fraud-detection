"""Logica PURA de las 4 reglas de deteccion -- sin Flink, sin estado, sin
I/O. Cada funcion recibe exactamente los datos que necesita y devuelve el
nombre de la regla si dispara, o None si no. Separarlas asi (en vez de
meterlas directo en el KeyedProcessFunction) permite probarlas con
Python normal, sin MiniCluster -- el `KeyedProcessFunction` en job.py solo
se encarga de mantener el estado y llamar a estas funciones.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta

UMBRAL_DESVIACIONES = 3.0
FACTOR_SIN_DESVIACION = 5.0

VENTANA_RAFAGA_SEGUNDOS = 300  # 5 minutos
UMBRAL_RAFAGA_CANTIDAD = 5

VELOCIDAD_MAXIMA_KMH = 900.0  # mas rapido que un avion comercial

UMBRAL_MONTO_FESTIVO = 300.0


def regla_monto_vs_promedio(monto: float, perfil: dict | None) -> str | None:
    """Z-score del monto contra el perfil historico de Redis.

    Sin perfil (cuenta no vista en fraudTrain, o sin num_transacciones
    suficientes), la regla no se evalua -- no hay linea base con la que
    comparar, y no evaluarla NO es lo mismo que aprobar: las demas reglas
    (festivo, rafaga, ubicacion) siguen aplicando igual.
    """
    if not perfil:
        return None

    promedio = float(perfil.get("monto_promedio") or 0)
    desviacion = float(perfil.get("monto_desviacion") or 0)

    if desviacion > 0:
        z = (monto - promedio) / desviacion
        return "monto_sobre_promedio" if z > UMBRAL_DESVIACIONES else None

    # Tarjeta con una sola transaccion en fraudTrain: desviacion=0 no
    # significa "cualquier monto distinto es sospechoso", significa que no
    # hay suficiente muestra para un z-score. Se cae a un factor simple.
    if promedio > 0 and monto > promedio * FACTOR_SIN_DESVIACION:
        return "monto_sobre_promedio"
    return None


def regla_rafaga(
    timestamps_recientes: list[datetime], ahora: datetime
) -> tuple[str | None, list[datetime]]:
    """Cuenta transacciones de la misma tarjeta en la ventana deslizante.

    Devuelve (regla_disparada_o_None, lista_purgada_con_el_evento_actual) --
    el caller (el KeyedProcessFunction) es quien decide que hacer con la
    lista purgada (guardarla de vuelta en el ListState).
    """
    limite = ahora - timedelta(seconds=VENTANA_RAFAGA_SEGUNDOS)
    purgados = [t for t in timestamps_recientes if t >= limite]
    purgados.append(ahora)
    disparo = "rafaga" if len(purgados) > UMBRAL_RAFAGA_CANTIDAD else None
    return disparo, purgados


def haversine_km(lat1: float, long1: float, lat2: float, long2: float) -> float:
    """Distancia entre dos puntos sobre la superficie terrestre, en km."""
    radio_tierra_km = 6371.0
    lat1_r, long1_r, lat2_r, long2_r = map(math.radians, (lat1, long1, lat2, long2))
    delta_lat = lat2_r - lat1_r
    delta_long = long2_r - long1_r
    a = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1_r) * math.cos(lat2_r) * math.sin(delta_long / 2) ** 2
    )
    return 2 * radio_tierra_km * math.asin(math.sqrt(a))


def regla_ubicacion_imposible(
    lat: float,
    long: float,
    ahora: datetime,
    ultima_ubicacion: tuple[float, float, datetime] | None,
) -> tuple[str | None, tuple[float, float, datetime]]:
    """Velocidad implicita (Haversine / tiempo) contra la transaccion
    anterior de la misma tarjeta.

    Devuelve (regla_disparada_o_None, nueva_ubicacion_a_guardar) -- la
    ubicacion se actualiza SIEMPRE, dispare o no la regla: lo que importa
    para la proxima evaluacion es "donde fue la ULTIMA transaccion", no
    "donde fue la ultima transaccion legitima".
    """
    nueva_ubicacion = (lat, long, ahora)

    if ultima_ubicacion is None:
        return None, nueva_ubicacion

    lat0, long0, t0 = ultima_ubicacion
    distancia_km = haversine_km(lat0, long0, lat, long)
    horas = max((ahora - t0).total_seconds() / 3600.0, 1e-9)
    velocidad_kmh = distancia_km / horas

    disparo = "ubicacion_imposible" if velocidad_kmh > VELOCIDAD_MAXIMA_KMH else None
    return disparo, nueva_ubicacion


def regla_festivo_monto_alto(es_festivo: bool, monto: float) -> str | None:
    if es_festivo and monto > UMBRAL_MONTO_FESTIVO:
        return "festivo_monto_alto"
    return None
