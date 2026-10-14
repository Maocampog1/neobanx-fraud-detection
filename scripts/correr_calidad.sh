#!/usr/bin/env bash
# ============================================================================
# correr_calidad.sh — ejecuta las reglas de calidad AHORA y muestra el resultado
# ============================================================================
#
# Lanza la consulta programada de calidad (la misma que corre cada 15 min,
# ver Infrastructure/calidad.tf), espera a que termine y muestra la última
# corrida desde analitica.dq_ultima_corrida.
#
#   docker run --rm -v neobanx-gcloud-config:/root/.config/gcloud \
#     -v ${PWD}:/workspace neobanx-deploy \
#     -c "cd /workspace && bash ./scripts/correr_calidad.sh"
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONFIG="$(terraform -chdir=Infrastructure output -json calidad \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["consulta_programada"])')"

echo "==> 1/3 Lanzando las reglas de calidad ahora (corre como sa-analitica)"
bq --project_id="${PROJECT_ID}" mk --transfer_run \
  --run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CONFIG}"

echo "==> 2/3 Esperando a que termine"
for _ in $(seq 1 30); do
  sleep 10
  ESTADO="$(bq --project_id="${PROJECT_ID}" ls --format=json --transfer_run \
      --run_attempt=LATEST --max_results=1 "${CONFIG}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("state","") if d else "")')"
  echo "    estado: ${ESTADO:-sin datos aún}"
  case "${ESTADO}" in
    SUCCEEDED) break ;;
    FAILED|CANCELLED)
      echo "ERROR: la corrida terminó en ${ESTADO}. Revisa el detalle en la consola: BigQuery > Consultas programadas." >&2
      exit 1 ;;
  esac
done

echo "==> 3/3 Resultado de la última corrida"
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --format=pretty \
  'SELECT regla, dimension, filas_evaluadas, filas_fallidas, resultado
   FROM analitica.dq_ultima_corrida
   ORDER BY regla'