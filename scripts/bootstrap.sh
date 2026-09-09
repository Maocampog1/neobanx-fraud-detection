#!/usr/bin/env bash
# bootstrap.sh — Prepara el entorno local para trabajar con NeobanX:
# crea .env si no existe, autentica gcloud, y genera terraform.tfvars.
#
# Uso:
#   ./scripts/bootstrap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

# --- Paso 1: crear .env si no existe ---
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "==> No se encontró .env, creando desde .env.example..."
  cp "${ENV_EXAMPLE}" "${ENV_FILE}"
  echo ""
  echo "==> Se creó ${ENV_FILE}."
  echo "    EDITA ese archivo ahora con tus valores reales (DB_PASSWORD y GENERATOR_SALT)"
  echo "    y vuelve a correr ./scripts/bootstrap.sh"
  exit 0
fi

echo "==> .env encontrado, cargándolo..."

# --- Paso 2: cargar variables de .env en esta sesión ---
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# --- Paso 3: verificar herramientas requeridas ---
echo "==> Verificando herramientas requeridas..."
for tool in gcloud terraform psql; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no está instalado o no está en el PATH."
    exit 1
  }
done
echo "    OK: gcloud, terraform, psql encontrados."

# --- Paso 4: autenticar gcloud (solo si no hay sesión activa) ---
echo "==> Verificando sesión de gcloud..."
CUENTA_ACTIVA=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)

if [[ -z "${CUENTA_ACTIVA}" ]]; then
  echo "==> No hay sesión activa, autenticando..."
  gcloud auth login --no-browser
else
  echo "    Ya autenticado como: ${CUENTA_ACTIVA}"
fi

ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"
if [[ ! -f "${ADC_FILE}" ]]; then
  echo "==> No hay credenciales de aplicación, autenticando..."
  gcloud auth application-default login --no-browser
else
  echo "    Application Default Credentials ya existen."
fi

gcloud config set project "${GCP_PROJECT_ID}"

# --- Paso 5: generar Infrastructure/terraform.tfvars a partir de .env ---
echo "==> Generando Infrastructure/terraform.tfvars..."
cat > "${ROOT_DIR}/Infrastructure/terraform.tfvars" <<TFVARS
project_id  = "${GCP_PROJECT_ID}"
region      = "${GCP_REGION}"
db_password = "${DB_PASSWORD}"
TFVARS

echo ""
echo "==> Bootstrap completo."
echo "    Siguiente paso: ./scripts/deploy.sh --yes"