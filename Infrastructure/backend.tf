# Estado remoto de Terraform en Google Cloud Storage.
#
# Por qué existe este archivo:
#   Hasta el Sprint 1 el estado (terraform.tfstate) vivía en el disco de cada
#   integrante. Eso producía dos problemas recurrentes: errores "409 Already
#   Exists" cuando alguien aplicaba desde otra máquina, y tener que pasarse el
#   archivo a mano (con el riesgo de trabajar sobre una copia desactualizada).
#
# Qué resuelve:
#   - Una sola fuente de verdad del estado, compartida por todo el equipo.
#   - Bloqueo automático: si alguien está aplicando, los demás esperan en vez
#     de corromper el estado.
#   - Versionado del bucket: se puede volver a un estado anterior.
#   - Los secretos que Terraform guarda en el estado (db_password, etc.) nunca
#     pasan por git. El bucket tiene acceso público bloqueado y UBLA activo.
#
# El bucket NO se crea desde este Terraform (problema del huevo y la gallina:
# el backend tiene que existir antes de que Terraform pueda inicializarse).
# Se creó una sola vez con:
#
#   gcloud storage buckets create gs://neobanx-fraud-detection-tfstate \
#     --project=neobanx-fraud-detection --location=us-central1 \
#     --uniform-bucket-level-access --public-access-prevention
#   gcloud storage buckets update gs://neobanx-fraud-detection-tfstate \
#     --versioning --project=neobanx-fraud-detection
#
# Si alguien despliega en un proyecto GCP nuevo, debe crear su propio bucket
# con esos dos comandos y ajustar el nombre de abajo.

terraform {
  backend "gcs" {
    bucket = "neobanx-fraud-detection-tfstate"
    prefix = "terraform/state"
  }
}
