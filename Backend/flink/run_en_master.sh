#!/usr/bin/env bash
# ============================================================================
# run_en_master.sh — corre DENTRO del nodo master de Dataproc
# ============================================================================
#
# Lo invoca desplegar_job.sh por SSH (tunel IAP). Espera estas variables de
# entorno ya exportadas por quien lo llama:
#   GOOGLE_CLOUD_PROJECT, STAGING_BUCKET, PUENTE_BUCKET,
#   REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
set -euo pipefail

for v in GOOGLE_CLOUD_PROJECT STAGING_BUCKET PUENTE_BUCKET REDIS_HOST REDIS_PORT REDIS_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: falta la variable de entorno ${v}" >&2
    exit 1
  fi
done

echo "==> Descargando codigo + venv.zip del bucket de staging"
rm -rf ~/neobanx-flink-job
mkdir -p ~/neobanx-flink-job
gsutil -m cp -r "${STAGING_BUCKET}/Backend" "${STAGING_BUCKET}/contracts" ~/neobanx-flink-job/
gsutil cp "${STAGING_BUCKET}/venv.zip" ~/neobanx-flink-job/venv.zip
cd ~/neobanx-flink-job

echo "==> Preparando entorno de Hadoop/Flink"
export HADOOP_CLASSPATH=$(hadoop classpath)

# El python3 del SISTEMA (/usr/bin/python3, el de toda la vida) sigue
# siendo el que usan los PUENTES (puente_entrada.py/puente_salida.py, que
# NO corren como workers de Flink, son procesos Python normales) -- para
# eso instalar_dependencias_flink.sh instala las dependencias ahi.
SYSTEM_PYTHON="/usr/bin/python3"

# El job de FLINK en si ya NO usa el python de sistema ni conda para sus
# workers -- usa un venv EMPAQUETADO (venv.zip, ver
# Backend/flink/empaquetar_venv.sh), subido junto con el codigo. Flink lo
# distribuye el mismo a cada TaskManager.
#
# POR QUE: los TaskManagers reales (donde corre el enriquecimiento)
# necesitan que `pyflink` sea un paquete `pip` real (con un `bin/` de
# verdad), no solo el .zip bundleado que alcanza para el lado cliente --
# confirmado con el error "ModuleNotFoundError: No module named 'pyflink'"
# en la primera corrida real. Instalar `apache-flink==1.17.0` de verdad en
# el Python de sistema del cluster (3.11) esta bloqueado por `numpy<1.22`
# sin wheels para 3.11+. El venv empaquetado resuelve esto sin tocar el
# Python de sistema: valida de punta a punta en local, contra un cluster
# standalone real (no MiniCluster), antes de intentarlo aqui -- ver
# Backend/flink/README.md, seccion "Bloqueador de pyflink en los
# TaskManagers", para el detalle y las fuentes oficiales de Flink.
VENV_ZIP="venv.zip"

export GOOGLE_CLOUD_PROJECT
export REDIS_HOST REDIS_PORT REDIS_PASSWORD
export REDIS_SSL=true
export SUBSCRIPTION_PRESELECCIONADAS=sub-flink-preseleccionadas
export TOPIC_PRESELECCIONADAS=tx-preseleccionadas
export TOPIC_VEREDICTOS=tx-veredictos
export DIRECTORIO_ENTRADA="${PUENTE_BUCKET}/entrada"
export DIRECTORIO_SALIDA="${PUENTE_BUCKET}/salida"

echo "==> Deteniendo puentes de una corrida anterior, si quedaron vivos"
pkill -f puente_entrada.py 2>/dev/null || true
pkill -f puente_salida.py 2>/dev/null || true
sleep 1

echo "==> Creando marcadores en entrada/ y salida/ (GCS no tiene carpetas reales)"
# Sin esto, el primer arranque falla: el FileSource de Flink enumera el
# prefijo gs://.../entrada al iniciar, y si NUNCA se escribio ningun objeto
# ahi, el conector GCS de Hadoop lo reporta como
# "FileNotFoundException: File not found" -- sin reintentar lo suficiente,
# el job agota sus reintentos y termina en FAILED antes de que
# puente_entrada.py llegue a escribir el primer archivo real. Confirmado en
# la primera corrida real contra el cluster.
gsutil -q cp /dev/null "${PUENTE_BUCKET}/entrada/.keep"
gsutil -q cp /dev/null "${PUENTE_BUCKET}/salida/.keep"

echo "==> Iniciando puente_entrada.py y puente_salida.py (background, persistentes)"
nohup "${SYSTEM_PYTHON}" Backend/flink/puente_entrada.py > ~/puente_entrada.log 2>&1 &
nohup "${SYSTEM_PYTHON}" Backend/flink/puente_salida.py > ~/puente_salida.log 2>&1 &
sleep 3
echo "puente_entrada.py:" && tail -5 ~/puente_entrada.log || true
echo "puente_salida.py:"  && tail -5 ~/puente_salida.log  || true

echo "==> Sometiendo el job de Flink (modo per-job, detached)"
# Rutas ABSOLUTAS para -py/-pyfs: con -pyarch presente, Flink resuelve esos
# dos relativos a un directorio de staging interno ("python-archives") que
# NO es este directorio de trabajo -- confirmado con
# "can't open file '.../python-archives/Backend/flink/main.py'" al usar
# rutas relativas. -pyarch/-pyclientexec/-pyexec si deben quedar relativos
# (asi los resuelve el propio venv.zip una vez extraido).
AQUI_ABS="$(pwd)"
flink run -d -m yarn-cluster \
  -pyarch "${VENV_ZIP}" \
  -pyclientexec "${VENV_ZIP}/venv/bin/python3" \
  -pyexec "${VENV_ZIP}/venv/bin/python3" \
  -pyfs "${AQUI_ABS}/Backend/flink,${AQUI_ABS}/Backend/common,${AQUI_ABS}/contracts" \
  -py "${AQUI_ABS}/Backend/flink/main.py"

echo "==> Listo. Verificar con: yarn application -list"
