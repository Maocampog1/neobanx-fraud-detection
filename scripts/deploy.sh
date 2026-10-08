#!/usr/bin/env bash
# deploy.sh — Despliega toda la infraestructura de NeobanX en GCP.
#
# Requisitos previos:
#   - gcloud CLI instalado y autenticado (gcloud auth application-default login)
#   - terraform >= 1.7 instalado
#   - psql y cloud-sql-proxy instalados (los usa Terraform para aplicar
#     schema.sql y cargar los datos maestros; la imagen Docker del repo ya los
#     trae, ver GUIA_DESPLIEGUE.md)
#   - python3 (lo usa la carga de clientes y cuentas; también viene en la imagen)
#   - Infrastructure/terraform.tfvars generado por ./scripts/bootstrap.sh
#     (NO se escribe a mano)
#
# NOTA — ya no hay secretos en terraform.tfvars.
#   Hasta el Sprint 1 había que poner ahí `db_password` y `generator_salt`,
#   pedidos por un canal privado. Desde el Sprint 2 Terraform GENERA la
#   contraseña de postgres, las de los 5 roles de aplicación y la clave HMAC, y
#   las guarda en Secret Manager. El tfvars solo lleva project_id, region y la
#   configuración de alertas.
#
#   Para consultar un secreto cuando haga falta:
#     gcloud secrets versions access latest --secret=neobanx-db-postgres
#
# NOTA — el estado de Terraform es REMOTO (bucket de GCS, ver
#   Infrastructure/backend.tf). Si vienes del Sprint 1, borra tus
#   terraform.tfstate* y .terraform/ locales ANTES del primer init, y si
#   Terraform ofrece copiar tu estado local al backend, responde NO.
#
# Uso:
#   ./deploy.sh            # muestra el plan y pide confirmación antes de aplicar
#   ./deploy.sh --yes      # aplica sin pedir confirmación (uso en CI/CD)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/../Infrastructure" && pwd)"
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
