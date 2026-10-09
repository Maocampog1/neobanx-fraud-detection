#!/usr/bin/env bash
# ============================================================================
# desplegar_job.sh — sube el codigo y somete el job de Flink a Dataproc
# ============================================================================
#
# Corre DESDE la raiz del repo (o ajusta las rutas), dentro de la imagen de
# herramientas (necesita gcloud; gsutil viene con el SDK). Asume que la
# infraestructura ya esta desplegada (terraform apply corrido, Redis y el
# cluster neobanx-flink existen).
#
# Uso: ./Backend/flink/desplegar_job.sh
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-neobanx-flink}"
MASTER="${CLUSTER}-m"
# Las imagenes de Compute Engine deshabilitan el login SSH directo de
# "root" -- gcloud lo usaria por defecto porque el contenedor de
# herramientas corre como root. Con un usuario normal, GCE crea la cuenta
# automaticamente (con sudo) al propagar la llave.
SSH_USER="${SSH_USER:-neobanx}"
MASTER_SSH="${SSH_USER}@${MASTER}"

STAGING_BUCKET="gs://${PROJECT_ID}-dataproc-staging/flink-job"
PUENTE_BUCKET="gs://${PROJECT_ID}-flink-puente"

echo "==> 1/5 Verificando venv.zip (paquete de Python para los TaskManagers)"
# venv.zip NO se genera aqui -- es pesado (~350MB) y necesita Docker, que
# este script no asume disponible. Se construye aparte con
# empaquetar_venv.sh, UNA vez (o cada vez que cambien las dependencias de
# Backend/flink/), y se sube tal cual. Ver Backend/flink/README.md,
# seccion "Bloqueador actual", para por que hace falta.
if [[ ! -f Backend/flink/venv.zip ]]; then
  echo "ERROR: falta Backend/flink/venv.zip. Generarlo primero con:" >&2
  echo "  bash Backend/flink/empaquetar_venv.sh" >&2
  exit 1
fi

echo "==> 2/5 Subiendo codigo + venv.zip a ${STAGING_BUCKET}"
# Solo lo que el job necesita -- NO todo Backend/ (eso incluiria
# Backend/generador/data/fraudTrain.csv, 351 MB, y los __pycache__).
TMP_PAQUETE="$(mktemp -d)"
mkdir -p "${TMP_PAQUETE}/Backend/flink" "${TMP_PAQUETE}/Backend/common" "${TMP_PAQUETE}/contracts"
find Backend/flink -maxdepth 1 -name "*.py" -o -name "*.sh" | xargs -I{} cp {} "${TMP_PAQUETE}/Backend/flink/"
find Backend/common -maxdepth 1 -name "*.py" | xargs -I{} cp {} "${TMP_PAQUETE}/Backend/common/"
find contracts -maxdepth 1 -name "*.py" | xargs -I{} cp {} "${TMP_PAQUETE}/contracts/"

gsutil -m rm -r "${STAGING_BUCKET}" 2>/dev/null || true
gsutil -m cp -r "${TMP_PAQUETE}/Backend" "${TMP_PAQUETE}/contracts" "${STAGING_BUCKET}/"
gsutil -m cp Backend/flink/venv.zip "${STAGING_BUCKET}/venv.zip"
rm -rf "${TMP_PAQUETE}"

echo "==> 3/5 Leyendo credenciales de Redis (Secret Manager + terraform output)"
REDIS_HOST="$(terraform -chdir=Infrastructure output -json redis 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["host"])')"
REDIS_PORT="$(terraform -chdir=Infrastructure output -json redis 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["puerto"])')"
REDIS_PASSWORD="$(gcloud secrets versions access latest --secret=neobanx-redis-auth --project="${PROJECT_ID}")"

if [[ -z "${REDIS_HOST}" || -z "${REDIS_PORT}" ]]; then
  echo "ERROR: no se pudo leer host/puerto de Redis desde 'terraform output'. ¿Esta aplicada la infraestructura?" >&2
  exit 1
fi
echo "    Redis: ${REDIS_HOST}:${REDIS_PORT}"

echo "==> 4/5 Copiando run_en_master.sh al nodo master (tunel IAP)"
gcloud compute scp Backend/flink/run_en_master.sh "${MASTER_SSH}:~/run_en_master.sh" \
  --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap

echo "==> 5/5 Ejecutando run_en_master.sh en el master"
gcloud compute ssh "${MASTER_SSH}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --command="
  export GOOGLE_CLOUD_PROJECT='${PROJECT_ID}'
  export STAGING_BUCKET='${STAGING_BUCKET}'
  export PUENTE_BUCKET='${PUENTE_BUCKET}'
  export REDIS_HOST='${REDIS_HOST}'
  export REDIS_PORT='${REDIS_PORT}'
  export REDIS_PASSWORD='${REDIS_PASSWORD}'
  bash ~/run_en_master.sh
"

echo ""
echo "==> Hecho. El job corre en modo detached -- sigue vivo aunque esta sesion SSH termine."
echo "Verificar: gcloud compute ssh ${MASTER_SSH} --project=${PROJECT_ID} --zone=${ZONE} --tunnel-through-iap --command='yarn application -list'"
