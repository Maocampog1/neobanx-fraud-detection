#!/usr/bin/env bash
# ============================================================================
# aplicar_policy_tags.sh — etiqueta las columnas de PII de raw.public_clientes
# ============================================================================
#
# La tabla la crea Datastream (no Terraform), así que las etiquetas se pegan
# aquí, después de que existe. Es idempotente: correrlo de nuevo no cambia
# nada. Las etiquetas vienen de `terraform output gobernanza` (gobernanza.tf).
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GOBERNANZA="$(terraform -chdir=Infrastructure output -json gobernanza)"
TAG_PII="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["policy_tag_pii_alta"])' <<<"${GOBERNANZA}")"
TAG_CUASI="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["policy_tag_cuasi"])' <<<"${GOBERNANZA}")"

ESQUEMA="$(mktemp)"
trap 'rm -f "${ESQUEMA}"' EXIT

echo "[policy_tags] Leyendo el esquema de raw.public_clientes"
bq --project_id="${PROJECT_ID}" show --schema --format=json raw.public_clientes > "${ESQUEMA}"

python3 - "${ESQUEMA}" "${TAG_PII}" "${TAG_CUASI}" <<'PY'
import json
import sys

ruta, tag_pii, tag_cuasi = sys.argv[1:4]

PII_ALTA = {"nombre_enmascarado", "apellido_enmascarado", "genero", "ocupacion",
            "fecha_nacimiento", "lat_hogar", "long_hogar"}
CUASI = {"ciudad", "codigo_postal"}

with open(ruta) as f:
    esquema = json.load(f)

etiquetadas = []
for campo in esquema:
    if campo["name"] in PII_ALTA:
        campo["policyTags"] = {"names": [tag_pii]}
        etiquetadas.append(f'{campo["name"]} -> PII_alta')
    elif campo["name"] in CUASI:
        campo["policyTags"] = {"names": [tag_cuasi]}
        etiquetadas.append(f'{campo["name"]} -> Cuasi_identificador')

faltan = (PII_ALTA | CUASI) - {c["name"] for c in esquema}
if faltan:
    sys.exit(f"[policy_tags] ERROR: columnas no encontradas: {sorted(faltan)}")

with open(ruta, "w") as f:
    json.dump(esquema, f)

for linea in etiquetadas:
    print(f"[policy_tags]   {linea}")
PY

bq --project_id="${PROJECT_ID}" update raw.public_clientes "${ESQUEMA}"
echo "[policy_tags] Listo."