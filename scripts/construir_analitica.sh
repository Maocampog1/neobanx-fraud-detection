#!/usr/bin/env bash
# ============================================================================
# construir_analitica.sh — reconstruye el modelo en estrella AHORA
# ============================================================================
#
# Ejecuta el mismo SQL que la consulta programada (cada 15 min), pero al
# instante. Útil en la demo, justo después de correr el generador.
#
#   docker run --rm -v neobanx-gcloud-config:/root/.config/gcloud \
#     -v ${PWD}:/workspace neobanx-deploy \
#     -c "cd /workspace && bash ./scripts/construir_analitica.sh"
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> Reconstruyendo el modelo en estrella"
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false < Infrastructure/sql/modelo_estrella.sql

echo "==> Tablas en analitica:"
bq --project_id="${PROJECT_ID}" ls analitica