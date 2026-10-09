#!/usr/bin/env bash
# ============================================================================
# construir_imagen.sh — construye y publica la imagen de un servicio
# ============================================================================
#
# Por que existe: `gcloud builds submit --tag=IMAGEN` exige un Dockerfile en
# la RAIZ del directorio que se sube como fuente. Nuestros servicios (
# registro/cierre/stub_veredicto) necesitan la raiz del repo como build
# context -- importan codigo compartido de Backend/common/ y contracts/,
# que viven fuera de su propia carpeta -- pero su Dockerfile vive en una
# subcarpeta (Backend/<servicio>/Dockerfile). La unica forma de combinar
# "contexto = raiz del repo" con "Dockerfile en otra ruta" es un
# cloudbuild.yaml explicito con el paso de `docker build -f <ruta>`.
#
# Lo invoca Terraform (run.tf) via null_resource + local-exec, una vez por
# servicio.
#
# Uso: construir_imagen.sh <servicio> <dockerfile_relativo_a_la_raiz> <imagen>
set -euo pipefail

SERVICIO="$1"
DOCKERFILE="$2"
IMAGEN="$3"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_CONFIG="$(mktemp)"
trap 'rm -f "${TMP_CONFIG}"' EXIT

cat > "${TMP_CONFIG}" <<EOF
steps:
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', '${IMAGEN}', '-f', '${DOCKERFILE}', '.']
images: ['${IMAGEN}']
EOF

echo "[construir_imagen] ${SERVICIO}: gcloud builds submit (contexto=raiz del repo, dockerfile=${DOCKERFILE})"
gcloud builds submit "${REPO_ROOT}" --config="${TMP_CONFIG}"
