"""Carga de datos maestros: `clientes` y `cuentas`.

QUÉ HACE Y POR QUÉ EXISTE
-------------------------
Lee los CSV de Sparkov, extrae el perfil de cada titular y sus tarjetas, y
emite un TSV listo para que `psql` lo cargue con COPY.

Esta carga es OBLIGATORIA antes de que el flujo pueda procesar una sola
transacción, por dos razones:

1. INTEGRIDAD REFERENCIAL. El esquema define
   `transacciones.cc_num_hash -> cuentas.cc_num_hash` como llave foránea. Con
   `cuentas` vacía, el servicio de registro no puede insertar NINGUNA
   transacción: PostgreSQL las rechaza todas con
   "violates foreign key constraint".

2. EL CONTRATO DE STREAMING NO TRAE EL PERFIL. Según
   `Backend/contrato_datos_generador.md`, los campos de identidad del cliente
   (`first`, `last`, `gender`, `city`, `zip`, `job`, `dob`, ...) NO viajan en el
   mensaje de Pub/Sub porque son PII. Esa información solo puede llegar por
   esta carga en lote.

Es el patrón habitual: las DIMENSIONES se cargan en lote, los HECHOS llegan por
el stream. Las transacciones, los veredictos y el historial de estados NO se
precargan nunca: entran solo por el flujo.

POR QUÉ SIN PANDAS
------------------
Solo usa librería estándar (`csv`, `hmac`, `urllib`). Así la imagen de
herramientas del despliegue no necesita pandas ni pip, y el script corre en
cualquier parte con Python 3. Los CSV se leen por streaming desde la URL
pública del bucket, sin descargarlos a disco: son ~480 MB entre los dos y solo
interesan 13 columnas de unos ~1000 titulares únicos.

TRATAMIENTO DE PII
------------------
- `cc_num` nunca se emite en claro: solo su HMAC-SHA256.
- El nombre y el apellido se enmascaran (primera letra + asteriscos).
- `street` del dataset se descarta por completo, no se emite ni se almacena
  (decisión de `Documentation/reglas_calidad_neobanx.md`).
- La identidad de la persona se representa con `cliente_hash`, un HMAC de
  (nombre|apellido|fecha_nacimiento), que permite deduplicar sin guardar la
  identidad real.

USO
---
    NEOBANX_HMAC_KEY=... python3 cargar_maestros.py --salida-clientes c.tsv --salida-cuentas q.tsv

O emitiendo a stdout para encadenar con psql (ver cargar_maestros.sh).
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
import urllib.request
from typing import Iterator, TextIO

# El módulo de tokenización vive en Backend/common.
sys.path.insert(
    0,
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "common"),
)

from hmac_util import hash_cc_num, normalizar_cc_num, obtener_clave  # noqa: E402
import hashlib  # noqa: E402
import hmac as _hmac  # noqa: E402

URL_TRAIN_DEFECTO = "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTrain.csv"
URL_TEST_DEFECTO = "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTest.csv"

# Columnas del CSV que se usan. `street` NO está aquí a propósito.
COLUMNAS_PERFIL = (
    "cc_num",
    "first",
    "last",
    "gender",
    "city",
    "state",
    "zip",
    "city_pop",
    "job",
    "dob",
    "lat",
    "long",
)

# Valor que psql interpreta como NULL en un COPY de texto.
NULO = r"\N"


def enmascarar(texto: str) -> str:
    """Deja la primera letra y sustituye el resto por asteriscos.

    'John' -> 'J***'. Conserva una pizca de legibilidad para la demo sin
    revelar el nombre real.
    """
    limpio = (texto or "").strip()
    if not limpio:
        return "?"
    return limpio[0].upper() + "*" * max(len(limpio) - 1, 1)


def hash_identidad(nombre: str, apellido: str, nacimiento: str) -> str:
    """HMAC de la identidad de la persona, para deduplicar sin guardarla.

    Usa la misma clave que `hash_cc_num`, pero sobre un mensaje con prefijo
    distinto: así el token de una persona nunca puede coincidir con el de una
    tarjeta, aunque los datos de entrada fueran iguales.
    """
    mensaje = f"cliente|{nombre.strip().lower()}|{apellido.strip().lower()}|{nacimiento.strip()}"
    return _hmac.new(obtener_clave(), mensaje.encode("utf-8"), hashlib.sha256).hexdigest()


def filas_csv(url: str) -> Iterator[dict]:
    """Lee un CSV remoto por streaming, sin descargarlo a disco."""
    peticion = urllib.request.Request(url, headers={"User-Agent": "neobanx-carga/1.0"})
    with urllib.request.urlopen(peticion) as respuesta:
        # Decodificación incremental: el archivo nunca se carga completo.
        flujo = (linea.decode("utf-8", errors="replace") for linea in respuesta)
        yield from csv.DictReader(flujo)


def normalizar_zip(valor: str) -> str:
    """El perfilamiento detectó que `zip` perdió los ceros a la izquierda.

    Se restituyen a 5 dígitos, que es la regla de calidad documentada.
    """
    limpio = (valor or "").strip()
    if not limpio:
        return NULO
    return limpio.zfill(5)


def numero_o_nulo(valor: str) -> str:
    limpio = (valor or "").strip()
    if not limpio:
        return NULO
    try:
        float(limpio)
    except ValueError:
        return NULO
    return limpio


def texto_o_nulo(valor: str) -> str:
    limpio = (valor or "").strip()
    if not limpio:
        return NULO
    # El COPY en formato texto usa tabulador como separador: hay que neutralizar
    # cualquier tabulador o salto de línea que venga en los datos.
    return limpio.replace("\t", " ").replace("\n", " ").replace("\r", " ").replace("\\", "\\\\")


def procesar(urls: list[str], sal_clientes: TextIO, sal_cuentas: TextIO) -> tuple[int, int, int]:
    """Recorre los CSV y emite los dos TSV. Devuelve (clientes, cuentas, descartadas)."""
    clientes_vistos: dict[str, None] = {}
    cuentas_vistas: dict[str, None] = {}
    descartadas = 0

    escritor_clientes = csv.writer(sal_clientes, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, escapechar=None)
    escritor_cuentas = csv.writer(sal_cuentas, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, escapechar=None)

    for url in urls:
        print(f"[carga] leyendo {url}", file=sys.stderr)
        for fila in filas_csv(url):
            cc_num_bruto = fila.get("cc_num", "")
            nacimiento = (fila.get("dob") or "").strip()
            nombre = (fila.get("first") or "").strip()
            apellido = (fila.get("last") or "").strip()

            # Una fila sin tarjeta o sin identidad no sirve para datos maestros.
            if not cc_num_bruto or not nombre or not apellido or not nacimiento:
                descartadas += 1
                continue

            try:
                normalizar_cc_num(cc_num_bruto)
                cc_hash = hash_cc_num(cc_num_bruto)
            except ValueError:
                # cc_num ilegible: descartar es mejor que inventar una cuenta
                # fantasma que rompería el join sin dar señal.
                descartadas += 1
                continue

            cliente_hash = hash_identidad(nombre, apellido, nacimiento)

            if cliente_hash not in clientes_vistos:
                clientes_vistos[cliente_hash] = None
                genero = (fila.get("gender") or "").strip().upper()
                escritor_clientes.writerow([
                    cliente_hash,
                    enmascarar(nombre),
                    enmascarar(apellido),
                    genero if genero in ("M", "F") else NULO,
                    texto_o_nulo(fila.get("city")),
                    texto_o_nulo(fila.get("state")),
                    normalizar_zip(fila.get("zip")),
                    numero_o_nulo(fila.get("city_pop")),
                    texto_o_nulo(fila.get("job")),
                    nacimiento,
                    numero_o_nulo(fila.get("lat")),
                    numero_o_nulo(fila.get("long")),
                ])

            if cc_hash not in cuentas_vistas:
                cuentas_vistas[cc_hash] = None
                escritor_cuentas.writerow([cc_hash, cliente_hash])

    return len(clientes_vistos), len(cuentas_vistas), descartadas


def main() -> int:
    parser = argparse.ArgumentParser(description="Genera los TSV de clientes y cuentas desde los CSV de Sparkov.")
    parser.add_argument("--url-train", default=os.environ.get("DATASET_URL", URL_TRAIN_DEFECTO))
    parser.add_argument("--url-test", default=os.environ.get("DATASET_TEST_URL", URL_TEST_DEFECTO))
    parser.add_argument("--salida-clientes", required=True)
    parser.add_argument("--salida-cuentas", required=True)
    args = parser.parse_args()

    # Se leen LOS DOS archivos. Si solo se cargaran las cuentas de fraudTrain y
    # el generador emite desde fraudTest, cualquier tarjeta que exista solo en
    # test chocaría con la llave foránea y su transacción sería rechazada.
    urls = [args.url_train, args.url_test]

    with open(args.salida_clientes, "w", encoding="utf-8", newline="") as fc, \
         open(args.salida_cuentas, "w", encoding="utf-8", newline="") as fq:
        clientes, cuentas, descartadas = procesar(urls, fc, fq)

    print(
        f"[carga] {clientes} titulares únicos, {cuentas} tarjetas únicas, "
        f"{descartadas} filas descartadas por datos incompletos o ilegibles",
        file=sys.stderr,
    )

    if clientes == 0 or cuentas == 0:
        print("[carga] ERROR: no se extrajo ningún dato maestro.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
