#!/usr/bin/env bash
# ============================================================================
# aplicar_schema.sh — aplica schema.sql a Cloud SQL a través del Auth Proxy
# ============================================================================
#
# POR QUÉ EXISTE ESTE SCRIPT
#
# En el Sprint 1 el esquema se aplicaba con un provisioner inline:
#
#   psql -h <IP_PUBLICA> -U postgres -d neobanx -f schema.sql
#
# Eso exigía tener `authorized_networks = 0.0.0.0/0` en la instancia, es decir,
# la base de datos aceptaba conexiones desde cualquier IP del mundo. Al cerrar
# esa red (Sprint 2), ese comando dejó de poder conectarse.
#
# La solución es el Cloud SQL Auth Proxy: abre un túnel local autenticado con
# las credenciales de gcloud y expone la instancia en 127.0.0.1, sin necesidad
# de autorizar ninguna IP. `psql` se conecta al proxy, no a la instancia.
#
# Además, el esquema v2 necesita recibir las contraseñas de los roles de
# aplicación como variables de psql (`-v`). Esas contraseñas las genera
# Terraform y viven en Secret Manager; aquí llegan por variables de entorno y
# nunca se escriben a disco ni aparecen en los logs.
#
# VARIABLES DE ENTORNO REQUERIDAS (las pasa Terraform):
#   INSTANCE_CONNECTION_NAME   proyecto:region:instancia
#   DB_NAME                    nombre de la base lógica
#   PGPASSWORD                 contraseña del usuario postgres
#   PWD_APP_REGISTRO, PWD_APP_CIERRE, PWD_DATASTREAM,
#   PWD_AGENTE_RO, PWD_FRONTEND_RO
#   SCHEMA_FILE                ruta a schema.sql
#
set -euo pipefail

PUERTO="${PUERTO_PROXY:-5433}" # 5433 para no chocar con un PostgreSQL local
PROXY_PID=""

log() { echo "[aplicar_schema] $*"; }

limpiar() {
  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
    log "Cerrando el Auth Proxy (pid ${PROXY_PID})"
    kill "${PROXY_PID}" 2>/dev/null || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi
}
# El proxy se cierra pase lo que pase, incluso si psql falla.
trap limpiar EXIT

# --- Validación de entradas -------------------------------------------------
requeridas=(
  INSTANCE_CONNECTION_NAME DB_NAME PGPASSWORD SCHEMA_FILE
  PWD_APP_REGISTRO PWD_APP_CIERRE PWD_DATASTREAM PWD_AGENTE_RO PWD_FRONTEND_RO
)
for v in "${requeridas[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: falta la variable de entorno ${v}" >&2
    exit 1
  fi
done

if ! command -v cloud-sql-proxy >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: no se encontró 'cloud-sql-proxy' en el PATH.

Si estás usando la imagen de herramientas del repo, reconstrúyela:
    docker build -t neobanx-deploy -f Infrastructure/Dockerfile .

Si trabajas con instalación local, descárgalo de:
    https://cloud.google.com/sql/docs/postgres/connect-auth-proxy
EOF
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "ERROR: no se encontró 'psql' en el PATH." >&2
  exit 1
fi

# --- Levantar el proxy ------------------------------------------------------
log "Levantando Auth Proxy hacia ${INSTANCE_CONNECTION_NAME} en 127.0.0.1:${PUERTO}"
cloud-sql-proxy --address 127.0.0.1 --port "${PUERTO}" "${INSTANCE_CONNECTION_NAME}" &
PROXY_PID=$!

# --- Esperar a que acepte conexiones ----------------------------------------
# No basta con que el proceso exista: hay que esperar a que el túnel esté
# aceptando conexiones, o psql falla con "connection refused".
log "Esperando a que el proxy acepte conexiones..."
listo=0
for intento in $(seq 1 30); do
  if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo "ERROR: el Auth Proxy terminó inesperadamente." >&2
    echo "Causa habitual: la cuenta activa no tiene roles/cloudsql.client," >&2
    echo "o la instancia aún está aprovisionándose." >&2
    exit 1
  fi
  if pg_isready -h 127.0.0.1 -p "${PUERTO}" -U postgres >/dev/null 2>&1; then
    listo=1
    log "Proxy listo (intento ${intento})"
    break
  fi
  sleep 2
done

if [[ "${listo}" -ne 1 ]]; then
  echo "ERROR: el proxy no aceptó conexiones tras 60 segundos." >&2
  exit 1
fi

# --- Aplicar el esquema -----------------------------------------------------
# Las contraseñas van como variables de psql. schema.sql falla de forma
# explícita si alguna falta (ver su sección de guardas).
log "Aplicando ${SCHEMA_FILE}"
psql \
  -h 127.0.0.1 \
  -p "${PUERTO}" \
  -U postgres \
  -d "${DB_NAME}" \
  --no-password \
  -v ON_ERROR_STOP=1 \
  -v pwd_app_registro="${PWD_APP_REGISTRO}" \
  -v pwd_app_cierre="${PWD_APP_CIERRE}" \
  -v pwd_datastream="${PWD_DATASTREAM}" \
  -v pwd_agente_ro="${PWD_AGENTE_RO}" \
  -v pwd_frontend_ro="${PWD_FRONTEND_RO}" \
  -f "${SCHEMA_FILE}"

log "Esquema aplicado correctamente."

# --- Slot de replicación para Datastream ------------------------------------
#
# Va en un paso aparte y con OTRO usuario a propósito.
# `pg_create_logical_replication_slot` exige el atributo REPLICATION del rol, y
# en Cloud SQL el usuario `postgres` tiene `cloudsqlsuperuser` pero NO ese
# atributo: intentarlo como postgres falla con
# "must be superuser or replication role to use replication slots".
#
# `datastream_user` sí lo recibe (schema.sql hace ALTER ROLE ... WITH
# REPLICATION), así que el slot se crea conectándose como él.
#
# El slot no se borra ni se recrea si ya existe: borrarlo mientras Datastream
# está conectado falla, y conservarlo evita perder la posición de lectura
# del WAL.
log "Creando el slot de replicación como datastream_user"
PGPASSWORD="${PWD_DATASTREAM}" psql \
  -h 127.0.0.1 \
  -p "${PUERTO}" \
  -U datastream_user \
  -d "${DB_NAME}" \
  --no-password \
  -v ON_ERROR_STOP=1 \
  -t -A \
  -c "SELECT CASE
        WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'neobanx_datastream_slot')
          THEN 'Slot neobanx_datastream_slot ya existe, se conserva.'
        ELSE (
          SELECT 'Slot creado: ' || slot_name
          FROM pg_create_logical_replication_slot('neobanx_datastream_slot', 'pgoutput')
        )
      END;"

log "Listo: esquema y slot de replicación en su lugar."
