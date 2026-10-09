# Imagen de herramientas de despliegue para NeobanX.
#
# Contiene terraform, gcloud CLI, psql, cloud-sql-proxy y python3 ya
# instalados, para que desplegar el proyecto en un proyecto GCP nuevo NO
# requiera instalar nada de esto en la máquina de cada persona -- solo Docker.
#
# python3 se incluye solo con la librería estándar (sin pandas ni pip): la
# carga de datos maestros lee los CSV por streaming con el módulo `csv` y
# tokeniza con `hmac`, ambos de la stdlib. Evitar pandas aquí mantiene la
# imagen liviana y el despliegue sin dependencias que compilar.
#
# Esta imagen NO contiene código de la aplicación ni credenciales de ningún
# tipo. El código (Backend/, Frontend/, Infrastructure/) y las credenciales
# de gcloud se montan como volúmenes al correr el contenedor -- ver
# GUIA_DESPLIEGUE.md para los comandos exactos.

FROM debian:12-slim

ARG TERRAFORM_VERSION=1.9.8
# Cloud SQL Auth Proxy: necesario desde el Sprint 2. Al cerrar el acceso
# 0.0.0.0/0 de Cloud SQL, aplicar el esquema ya no se puede hacer conectando
# psql a la IP pública -- ahora va por un túnel local autenticado con IAM
# (ver Infrastructure/aplicar_schema.sh).
ARG CLOUD_SQL_PROXY_VERSION=2.14.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        unzip \
        gnupg \
        lsb-release \
        postgresql-client \
        ca-certificates \
        python3-minimal \
        python3-distutils \
        openssh-client \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        google-cloud-cli \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
        -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && curl -fsSL \
        "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v${CLOUD_SQL_PROXY_VERSION}/cloud-sql-proxy.linux.amd64" \
        -o /usr/local/bin/cloud-sql-proxy \
    && chmod +x /usr/local/bin/cloud-sql-proxy \
    && apt-get purge -y unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
