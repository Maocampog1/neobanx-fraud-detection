"""Consulta de festivos en Colombia via Nager.Date, cacheada por anio."""

from datetime import date

import requests

NAGER_URL = "https://date.nager.at/api/v3/PublicHolidays/{anio}/CO"

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
    print(f"{prueba} es festivo en Colombia: {es_festivo(prueba)}")
