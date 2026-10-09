"""Consulta de festivos en EEUU via Nager.Date, cacheada por anio.

Vivia en Backend/generador/ (v1), pero el generador v2 no lo usa -- el
enriquecimiento con festivo es una regla de DETECCION, no algo que el
generador necesite saber. Se movio aqui, a Backend/common/, porque el job de
Flink (Backend/flink/) es quien realmente lo consume.

PAIS: EEUU, no Colombia (la version original). El dataset Sparkov es
sintetico pero modela transacciones de EEUU -- comercios, direcciones y
coordenadas (merch_lat/merch_long) caen todas en territorio estadounidense.
Evaluar "festivo" contra el calendario de Colombia no tendria sentido para
estos datos. Ver Backend/flink/README.md para el detalle de esta decision.
"""

from datetime import date

import requests

NAGER_URL = "https://date.nager.at/api/v3/PublicHolidays/{anio}/US"

_cache: dict[int, set[date]] = {}


def _festivos_del_anio(anio: int) -> set[date]:
    if anio not in _cache:
        resp = requests.get(NAGER_URL.format(anio=anio), timeout=10)
        resp.raise_for_status()
        _cache[anio] = {date.fromisoformat(item["date"]) for item in resp.json()}
    return _cache[anio]


def es_festivo(fecha: date) -> bool:
    return fecha in _festivos_del_anio(fecha.year)


if __name__ == "__main__":
    prueba = date(2019, 1, 1)
    print(f"{prueba} es festivo en EEUU: {es_festivo(prueba)}")
