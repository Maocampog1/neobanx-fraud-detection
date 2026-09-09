#!/usr/bin/env bash
# deploy.sh — Despliega toda la infraestructura de NeobanX (Sprint 1) en GCP.
#
# Requisitos previos:
#   - gcloud CLI instalado y autenticado (gcloud auth application-default login)
#   - terraform >= 1.7 instalado
#   - psql instalado (usado internamente por Terraform para aplicar schema.sql)
#   - Infrastructure/terraform.tfvars creado localmente (NO versionado) con:
#       project_id  = "neobanx-fraud-detection"
#       region      = "us-central1"
#       db_password = "<contraseña real de postgres, ver documento privado del equipo>"
#
# Uso:
#   ./deploy.sh            # muestra el plan y pide confirmación antes de aplicar
#   ./deploy.sh --yes      # aplica sin pedir confirmación (uso en CI/CD)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/Infrastructure"
AUTO_APPROVE=""

if [[ "${1:-}" == "--yes" ]]; then
  AUTO_APPROVE="-auto-approve"
fi

if [[ ! -f "${INFRA_DIR}/terraform.tfvars" ]]; then
  echo "ERROR: No se encontró ${INFRA_DIR}/terraform.tfvars"
  echo "Crea ese archivo con project_id, region y db_password antes de continuar."
  echo "Este archivo NUNCA se versiona (ver .gitignore)."
  exit 1
fi

echo "==> Verificando autenticación de gcloud..."
gcloud auth application-default print-access-token >/dev/null 2>&1 || {
  echo "ERROR: No hay credenciales activas de gcloud."
  echo "Corre: gcloud auth application-default login"
  exit 1
}

echo "==> Entrando a ${INFRA_DIR}"
cd "${INFRA_DIR}"

echo "==> terraform init"
terraform init -upgrade

echo "==> terraform plan"
terraform plan -out=tfplan

if [[ -z "${AUTO_APPROVE}" ]]; then
  read -rp "¿Aplicar este plan? Escribe 'yes' para continuar: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Cancelado por el usuario."
    exit 0
  fi
fi

echo "==> terraform apply"
terraform apply tfplan

echo ""
echo "==> Despliegue completo."
echo "URL del frontend de demo:"
terraform output -raw frontend_url 2>/dev/null || echo "(no disponible aún, revisa 'terraform output')"
