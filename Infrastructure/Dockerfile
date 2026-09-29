# Imagen de herramientas de despliegue para NeobanX.
#
# Contiene terraform, gcloud CLI y psql ya instalados, para que desplegar
# el proyecto en un proyecto GCP nuevo NO requiera instalar nada de esto
# en la máquina de cada persona -- solo Docker.
#
# Esta imagen NO contiene código de la aplicación ni credenciales de ningún
# tipo. El código (Backend/, Frontend/, Infrastructure/) y las credenciales
# de gcloud se montan como volúmenes al correr el contenedor -- ver
# GUIA_DESPLIEGUE.md para los comandos exactos.

FROM debian:12-slim

ARG TERRAFORM_VERSION=1.9.8

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        unzip \
        gnupg \
        lsb-release \
        postgresql-client \
        ca-certificates \
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
    && apt-get purge -y unzip \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["/bin/bash"]
