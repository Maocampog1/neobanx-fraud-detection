#!/usr/bin/env bash
# test.sh — Prueba funcional end-to-end: ejecuta el generador (ventana acotada)
# como Cloud Run Job y verifica que las filas llegaron a BigQuery con veredicto.
#
# Uso:
#   ./scripts/test.sh
#
# Variables opcionales para ajustar la ventana de prueba (si no se definen,
# usa valores rápidos por defecto y el rango de fechas de tu .env):
#   TEST_MAX_FILAS, TEST_INTERVALO_SEGUNDOS, TEST_FECHA_INICIO, TEST_FECHA_FIN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: falta .env, corre ./scripts/bootstrap.sh primero"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

JOB_NAME="neobanx-generador"

# Ventana y cadencia de prueba: acotada para que la ejecucion tome ~30-60s,
# no los ~60 dias que tomaria el CSV completo.
TEST_MAX_FILAS="${TEST_MAX_FILAS:-30}"
TEST_INTERVALO_SEGUNDOS="${TEST_INTERVALO_SEGUNDOS:-1}"
TEST_FECHA_INICIO="${TEST_FECHA_INICIO:-${FECHA_INICIO:-2019-02-25 22:00:00}}"
TEST_FECHA_FIN="${TEST_FECHA_FIN:-${FECHA_FIN:-2019-02-26 00:00:00}}"

START_ISO="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "==> Ejecutando ${JOB_NAME} (MAX_FILAS=${TEST_MAX_FILAS}, INTERVALO_SEGUNDOS=${TEST_INTERVALO_SEGUNDOS})..."
if ! gcloud run jobs execute "${JOB_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --region="${GCP_REGION}" \
  --wait \
  --update-env-vars="MAX_FILAS=${TEST_MAX_FILAS},INTERVALO_SEGUNDOS=${TEST_INTERVALO_SEGUNDOS},FECHA_INICIO=${TEST_FECHA_INICIO},FECHA_FIN=${TEST_FECHA_FIN}"; then
  echo "FALLO: la ejecucion del Cloud Run Job no completo exitosamente."
  exit 1
fi

echo "==> Verificando filas en BigQuery (raw.transacciones_raw, ingestion_timestamp >= ${START_ISO})..."

INTENTOS=12
ESPERA_SEGUNDOS=5
for i in $(seq 1 "${INTENTOS}"); do
  RESULT="$(bq query --project_id="${GCP_PROJECT_ID}" --use_legacy_sql=false --format=csv --quiet "
    SELECT COUNT(*) AS total, COUNTIF(veredicto IS NOT NULL) AS con_veredicto
    FROM \`${GCP_PROJECT_ID}.raw.transacciones_raw\`
    WHERE ingestion_timestamp >= TIMESTAMP('${START_ISO}')
  " | tail -n1)"

  TOTAL="$(echo "${RESULT}" | cut -d',' -f1)"
  CON_VEREDICTO="$(echo "${RESULT}" | cut -d',' -f2)"

  if [[ "${TOTAL}" -ge "${TEST_MAX_FILAS}" && "${TOTAL}" == "${CON_VEREDICTO}" ]]; then
    echo "OK: ${TOTAL} filas insertadas, todas con veredicto (esperado >= ${TEST_MAX_FILAS})."
    exit 0
  fi

  echo "    Intento ${i}/${INTENTOS}: total=${TOTAL} con_veredicto=${CON_VEREDICTO} (esperando propagacion Pub/Sub -> BigQuery)..."
  sleep "${ESPERA_SEGUNDOS}"
done

echo "FALLO: no se alcanzaron ${TEST_MAX_FILAS} filas con veredicto en BigQuery tras $((INTENTOS * ESPERA_SEGUNDOS))s."
exit 1
