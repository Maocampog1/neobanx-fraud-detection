#!/usr/bin/env bash
# ============================================================================
# cargar_festivos.sh — festivos de EE. UU. desde Nager.Date a BigQuery
# ============================================================================
#
# Carga analitica.festivos_us, que usa dim_tiempo para la bandera de festivo.
#
# País: EE. UU., no Colombia, por la misma razón que Backend/common/holidays.py:
# el dataset Sparkov modela transacciones en EE. UU. Así el dashboard usa
# exactamente el mismo calendario que la regla "monto alto en festivo" de Flink.
#
# Lo invoca Terraform (analitica.tf). Variables requeridas: PROJECT_ID, DATASET.
set -euo pipefail

: "${PROJECT_ID:?falta PROJECT_ID}"
: "${DATASET:?falta DATASET}"

ARCHIVO="$(mktemp)"
trap 'rm -f "${ARCHIVO}"' EXIT

for anio in 2019 2020 2021; do
  echo "[cargar_festivos] Nager.Date ${anio}/US"
  curl -fsS --retry 3 "https://date.nager.at/api/v3/PublicHolidays/${anio}/US" \
    | python3 -c '
import json, sys
for h in json.load(sys.stdin):
    print(json.dumps({
        "fecha": h["date"],
        "nombre": h["name"],
        "nombre_local": h["localName"],
        "global": h["global"],
    }))
' >> "${ARCHIVO}"
done

echo "[cargar_festivos] $(wc -l < "${ARCHIVO}") festivos -> ${DATASET}.festivos_us"
bq --project_id="${PROJECT_ID}" load \
  --replace \
  --source_format=NEWLINE_DELIMITED_JSON \
  "${DATASET}.festivos_us" \
  "${ARCHIVO}" \
  fecha:DATE,nombre:STRING,nombre_local:STRING,global:BOOLEAN

echo "[cargar_festivos] Listo."