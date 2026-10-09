#!/usr/bin/env bash
# ============================================================================
# construir_analitica.sh — reconstruye el modelo en estrella AHORA
# ============================================================================
#
# 1. Aplica los policy tags a raw.public_clientes (aplicar_policy_tags.sh).
# 2. Lanza YA la consulta programada (la misma que corre cada 15 minutos).
# 3. Espera a que termine.
#
# Por qué no ejecuta el SQL directamente con la cuenta de quien lo corre: con
# los policy tags, esa persona ve la fecha de nacimiento ENMASCARADA, y el
# rango de edad saldría mal. La consulta programada corre como sa-analitica,
# la única identidad con acceso a los datos reales (gobernanza.tf).
#
#   docker run --rm -v neobanx-gcloud-config:/root/.config/gcloud \
#     -v ${PWD}:/workspace neobanx-deploy \
#     -c "cd /workspace && bash ./scripts/construir_analitica.sh"
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> 1/3 Policy tags sobre raw.public_clientes"
bash scripts/aplicar_policy_tags.sh

CONFIG="$(terraform -chdir=Infrastructure output -json gobernanza \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["consulta_programada"])')"

echo "==> 2/3 Lanzando la consulta programada ahora (corre como sa-analitica)"
bq --project_id="${PROJECT_ID}" mk --transfer_run \
  --run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CONFIG}"

echo "==> 3/3 Esperando a que termine"
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

echo "==> Tablas en analitica:"
bq --project_id="${PROJECT_ID}" ls analitica