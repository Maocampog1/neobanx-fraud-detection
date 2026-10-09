#!/usr/bin/env bash
# ============================================================================
# generar_datos.sh — carga transacciones REALES (fraudTest.csv) al flujo
# transaccional desplegado en la nube, para tener datos de demo y dashboard.
# ============================================================================
#
# Corre el generador de Juanes (Backend/generador/main.py) SIN modificarlo,
# pero autenticado con la cuenta de la persona (gcloud auth
# print-identity-token, igual que scripts/test_nube.sh), porque el generador
# por defecto espera la identidad de una cuenta de servicio.
#
# Se corre dentro de la imagen de herramientas:
#   docker run -it --rm -v neobanx-gcloud-config:/root/.config/gcloud \
#     -v ${PWD}:/workspace neobanx-deploy \
#     -c "cd /workspace && bash ./scripts/generar_datos.sh"
#
# Variables opcionales: MAX_FILAS (500), TX_POR_SEGUNDO (5),
# GEN_FECHA_INICIO / GEN_FECHA_FIN (deben caer dentro de fraudTest.csv:
# 2020-06-21 a 2020-12-31).
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
REGION="${REGION:-us-central1}"

echo "==> Instalando dependencias del generador (solo dentro de este contenedor)"
apt-get update -qq >/dev/null
apt-get install -y -qq python3-pip >/dev/null
pip3 install --quiet --break-system-packages -r Backend/generador/requirements.txt

REGISTRO_URL="$(gcloud run services describe registro --region="$REGION" --project="$PROJECT_ID" --format='value(status.url)')"
echo "==> registro: ${REGISTRO_URL}"

export REGISTRO_URL
export USAR_AUTH_IAM=true
export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export ID_TOKEN="$(gcloud auth print-identity-token)"
export MAX_FILAS="${MAX_FILAS:-500}"
export TX_POR_SEGUNDO="${TX_POR_SEGUNDO:-5}"
export FECHA_INICIO="${GEN_FECHA_INICIO:-2020-06-21}"
export FECHA_FIN="${GEN_FECHA_FIN:-2020-06-23}"
# El CSV se descarga dentro del contenedor, no en la carpeta del repo.
export CSV_PATH=/tmp/fraudTest.csv

echo "==> Enviando ${MAX_FILAS} transacciones a ${TX_POR_SEGUNDO} tx/s"
python3 - <<'PY'
import os
import sys

sys.path.insert(0, "Backend/generador")
import main

token = os.environ["ID_TOKEN"]
main._obtener_id_token = lambda audiencia: token
main.main()
PY

echo "==> Generación terminada."