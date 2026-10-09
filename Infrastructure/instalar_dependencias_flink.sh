#!/usr/bin/env bash
# ============================================================================
# instalar_dependencias_flink.sh — accion de inicializacion de Dataproc
# ============================================================================
#
# Instala las dependencias de Python que necesitan el job de perfiles
# (PySpark, Backend/carga/perfiles_redis.py) y el job de Flink
# (Backend/flink/), en TODOS los nodos (master + workers) al crear el
# cluster.
#
# POR QUE ESTO Y NO `dataproc:pip.packages`
# ------------------------------------------
# Se intento primero con la propiedad nativa `dataproc:pip.packages` (mas
# simple, declarativa). No funciono: la imagen 2.2-debian12 usa Python con
# la proteccion PEP 668 ("externally-managed-environment"), y el mecanismo
# de Dataproc para esa propiedad no pasa `--break-system-packages` (ni usa
# un venv). Confirmado por SSH al master real: ningun paquete quedaba
# instalado, ni con `pip3 show` ni buscando en el filesystem. Esta accion
# de inicializacion llama a pip directamente con el flag que hace falta.
#
# POR QUE `/usr/bin/python3 -m pip`, NO `pip3` A SECAS
# -----------------------------------------------------
# Con solo `pip3 install`, el `pip3` que esta accion de inicializacion
# resuelve por PATH termina siendo el de CONDA (/opt/conda/miniconda3), no
# el de sistema -- confirmado leyendo el log real de la instalacion
# (quedo instalado en site-packages de conda). El problema: Flink necesita
# justo el OTRO (el de sistema, /usr/bin/python3) para el job de
# Backend/flink/ -- es el unico que resuelve `pyflink` correctamente (vive
# en un .zip bundleado dentro de Flink, y solo el python por defecto de
# Flink lo encuentra). Pedir el interprete por ruta absoluta evita
# depender del PATH, sea cual sea en el contexto de esta accion.
set -euo pipefail

/usr/bin/python3 -m pip install --break-system-packages \
  redis==5.0.1 \
  google-cloud-secret-manager==2.20.2 \
  requests==2.32.3 \
  pydantic==2.9.2 \
  google-cloud-pubsub==2.21.1 \
  google-cloud-storage==2.18.2 \
  cloudpickle
