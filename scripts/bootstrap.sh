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
# cloud-sql-proxy se agregó en el Sprint 2: al cerrar el acceso 0.0.0.0/0 de
# Cloud SQL, el esquema ya no se aplica contra la IP pública sino por un túnel
# autenticado. Si falta, usa la imagen Docker del repo (ver GUIA_DESPLIEGUE.md).
echo "==> Verificando herramientas requeridas..."
for tool in gcloud terraform psql cloud-sql-proxy; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no está instalado o no está en el PATH."
    if [[ "${tool}" == "cloud-sql-proxy" ]]; then
      echo "       Reconstruye la imagen de herramientas:"
      echo "         docker build -t neobanx-deploy -f Infrastructure/Dockerfile ."
      echo "       O descárgalo de:"
      echo "         https://cloud.google.com/sql/docs/postgres/connect-auth-proxy"
    fi
    exit 1
  }
done
echo "    OK: gcloud, terraform, psql, cloud-sql-proxy encontrados."

# --- Paso 4: autenticar gcloud (solo si no hay sesión activa) ---
echo "==> Verificando sesión de gcloud..."
CUENTA_ACTIVA=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)

if [[ -z "${CUENTA_ACTIVA}" ]]; then
  echo "==> No hay sesión activa, autenticando..."
  gcloud auth login --no-browser
else
  echo "    Ya autenticado como: ${CUENTA_ACTIVA}"
fi

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "    Application Default Credentials ya existen."
else
  echo "==> No hay credenciales de aplicación, autenticando..."
  gcloud auth application-default login --no-browser
fi

gcloud config set project "${GCP_PROJECT_ID}"

# --- Paso 5: generar Infrastructure/terraform.tfvars a partir de .env ---
#
# Desde el Sprint 2 este archivo ya NO contiene secretos. Terraform genera la
# contraseña de postgres, las de los cinco roles de aplicación y la clave HMAC,
# y las guarda en Secret Manager (ver Infrastructure/secrets.tf). Nadie tiene
# que conocerlas ni compartirlas por chat, y desaparece el riesgo de que dos
# personas desplieguen con un salt distinto y rompan los hashes de cc_num.
echo "==> Generando Infrastructure/terraform.tfvars..."
cat > "${ROOT_DIR}/Infrastructure/terraform.tfvars" <<TFVARS
project_id = "${GCP_PROJECT_ID}"
region     = "${GCP_REGION}"
TFVARS

# El correo de alertas es por persona, no va fijo en el código: si estuviera
# hardcodeado, quien reproduzca el repo recibiría alertas de un despliegue
# ajeno o no recibiría ninguna. Se omite el valor de ejemplo de .env.example
# para que nadie despliegue apuntando a un correo inventado.
if [[ -n "${ALERT_EMAIL:-}" && "${ALERT_EMAIL}" != "tu-correo@ejemplo.com" ]]; then
  echo "correo_alertas = \"${ALERT_EMAIL}\"" >> "${ROOT_DIR}/Infrastructure/terraform.tfvars"
  echo "    Alertas de monitoreo -> ${ALERT_EMAIL}"
else
  echo "    ALERT_EMAIL sin definir: las alertas se crearán sin destinatario."
fi

# La cuenta de facturación también es por persona: cada quien puede estar
# usando una cuenta educativa distinta. El presupuesto es la red de seguridad
# contra dejar Dataproc o Redis encendidos, así que conviene configurarlo.
if [[ -n "${BILLING_ACCOUNT:-}" ]]; then
  echo "billing_account = \"${BILLING_ACCOUNT}\"" >> "${ROOT_DIR}/Infrastructure/terraform.tfvars"
  echo "presupuesto_mensual_usd = ${BUDGET_USD:-100}" >> "${ROOT_DIR}/Infrastructure/terraform.tfvars"
  echo "    Presupuesto -> ${BUDGET_USD:-100} USD/mes en la cuenta ${BILLING_ACCOUNT}"
else
  echo "    BILLING_ACCOUNT sin definir: NO se creará alerta de presupuesto."
  echo "      (obtén el ID con: gcloud billing accounts list)"
fi

echo "    Sin secretos: Terraform los genera y los guarda en Secret Manager."

if [[ -n "${DB_PASSWORD:-}" || -n "${GENERATOR_SALT:-}" ]]; then
  echo ""
  echo "    NOTA: DB_PASSWORD y GENERATOR_SALT en tu .env ya no se usan."
  echo "          Terraform genera esos valores y los guarda en Secret Manager."
  echo "          Puedes borrarlos del .env sin consecuencias."
fi

echo ""
echo "==> Bootstrap completo."
echo "    Siguiente paso: ./scripts/deploy.sh --yes"