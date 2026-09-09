#!/usr/bin/env bash
# destroy.sh — Elimina TODA la infraestructura de NeobanX desplegada en GCP.
# Úsalo para no dejar recursos huérfanos consumiendo créditos educativos.
#
# Uso:
#   ./destroy.sh            # muestra qué se va a destruir y pide confirmación
#   ./destroy.sh --yes      # destruye sin pedir confirmación (uso en CI/CD)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/Infrastructure"
AUTO_APPROVE=""

if [[ "${1:-}" == "--yes" ]]; then
  AUTO_APPROVE="-auto-approve"
fi

if [[ ! -f "${INFRA_DIR}/terraform.tfvars" ]]; then
  echo "ERROR: No se encontró ${INFRA_DIR}/terraform.tfvars"
  echo "Terraform necesita este archivo para saber qué proyecto/credenciales usar."
  exit 1
fi

echo "==> Entrando a ${INFRA_DIR}"
cd "${INFRA_DIR}"

if [[ -z "${AUTO_APPROVE}" ]]; then
  echo "==> Recursos que se van a destruir:"
  terraform plan -destroy
  read -rp "¿Confirmas destruir TODA la infraestructura? Escribe 'yes' para continuar: " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Cancelado por el usuario."
    exit 0
  fi
fi

echo "==> terraform destroy"
terraform destroy ${AUTO_APPROVE}

echo ""
echo "==> Infraestructura destruida. No deberían quedar recursos facturables."
echo "Verifica manualmente en la consola de GCP si tienes dudas."
