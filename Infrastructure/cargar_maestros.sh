#!/usr/bin/env bash
# ============================================================================
# cargar_maestros.sh — carga `clientes` y `cuentas` en Cloud SQL
# ============================================================================
#
# Por qué esta carga es obligatoria y no opcional:
#
#   `transacciones.cc_num_hash` es llave foránea de `cuentas.cc_num_hash`. Con
#   `cuentas` vacía, el servicio de registro no puede insertar NINGUNA
#   transacción. Y el perfil del titular no puede llegar por el stream, porque
#   el contrato de datos excluye la PII a propósito.
#
#   Por eso corre como parte del despliegue (null_resource en cloudsql.tf) y no
#   como un paso manual: tras un `destroy` + `apply`, el entorno tiene que
#   quedar listo para recibir transacciones sin que nadie recuerde ejecutar
#   nada aparte.
#
# Flujo:
#   1. Lee la clave HMAC de Secret Manager y la pasa por variable de entorno
#      (así el script de Python no necesita la librería de Secret Manager).
#   2. Genera dos TSV con Python (solo stdlib, streaming desde el bucket).
#   3. Levanta el Auth Proxy.
#   4. Carga los TSV con COPY a tablas temporales y de ahí a las definitivas,
#      de forma idempotente.
#
# VARIABLES REQUERIDAS (las pasa Terraform):
#   INSTANCE_CONNECTION_NAME, DB_NAME, PGPASSWORD, PROJECT_ID,
#   HMAC_SECRET_ID, DATASET_URL, DATASET_TEST_URL, CARGA_DIR
#
set -euo pipefail

PUERTO="${PUERTO_PROXY:-5434}"   # distinto del de aplicar_schema.sh
PROXY_PID=""
TMP_DIR=""

log() { echo "[cargar_maestros] $*"; }

limpiar() {
  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
    kill "${PROXY_PID}" 2>/dev/null || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi
  # Los TSV contienen hashes, no PII en claro, pero igual se borran.
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap limpiar EXIT

for v in INSTANCE_CONNECTION_NAME DB_NAME PGPASSWORD PROJECT_ID HMAC_SECRET_ID CARGA_DIR; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: falta la variable de entorno ${v}" >&2
    exit 1
  fi
done

for cmd in python3 psql cloud-sql-proxy gcloud; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: falta '$cmd' en el PATH." >&2; exit 1; }
done

# --- 1. Clave HMAC -----------------------------------------------------------
# Se lee aquí y se pasa por entorno para que cargar_maestros.py funcione con
# solo la librería estándar de Python.
log "Leyendo la clave HMAC de Secret Manager"
NEOBANX_HMAC_KEY="$(gcloud secrets versions access latest \
  --secret="${HMAC_SECRET_ID}" --project="${PROJECT_ID}")"
export NEOBANX_HMAC_KEY

if [[ -z "${NEOBANX_HMAC_KEY}" ]]; then
  echo "ERROR: la clave HMAC resolvió vacía." >&2
  exit 1
fi

# --- 2. Generar los TSV ------------------------------------------------------
TMP_DIR="$(mktemp -d)"
TSV_CLIENTES="${TMP_DIR}/clientes.tsv"
TSV_CUENTAS="${TMP_DIR}/cuentas.tsv"

log "Extrayendo datos maestros de los CSV (streaming, sin descargar a disco)"
python3 "${CARGA_DIR}/cargar_maestros.py" \
  --url-train "${DATASET_URL}" \
  --url-test "${DATASET_TEST_URL}" \
  --salida-clientes "${TSV_CLIENTES}" \
  --salida-cuentas "${TSV_CUENTAS}"

log "TSV generados: $(wc -l < "${TSV_CLIENTES}") titulares, $(wc -l < "${TSV_CUENTAS}") tarjetas"

# --- 3. Auth Proxy -----------------------------------------------------------
log "Levantando Auth Proxy hacia ${INSTANCE_CONNECTION_NAME} en 127.0.0.1:${PUERTO}"
cloud-sql-proxy --address 127.0.0.1 --port "${PUERTO}" "${INSTANCE_CONNECTION_NAME}" &
PROXY_PID=$!

listo=0
for intento in $(seq 1 30); do
  if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    echo "ERROR: el Auth Proxy terminó inesperadamente." >&2
    exit 1
  fi
  if pg_isready -h 127.0.0.1 -p "${PUERTO}" -U postgres >/dev/null 2>&1; then
    listo=1; break
  fi
  sleep 2
done
[[ "${listo}" -eq 1 ]] || { echo "ERROR: el proxy no respondió en 60s." >&2; exit 1; }

# --- 4. Cargar ---------------------------------------------------------------
# Se usan tablas temporales + INSERT ... ON CONFLICT en vez de COPY directo a
# las tablas finales, por dos motivos:
#   - `clientes.cliente_id` es BIGSERIAL: el ID lo asigna PostgreSQL, así que
#     `cuentas` tiene que resolver su FK con un JOIN por `cliente_hash`.
#   - Idempotencia: el equipo recrea el entorno en cada sesión y esta carga
#     vuelve a correr; ON CONFLICT evita duplicados si la tabla ya tiene datos.
log "Cargando en Cloud SQL"
# NOTA SOBRE EL HEREDOC
#
# El delimitador va SIN comillas (`<<SQL`, no `<<'SQL'`) a propósito: así el
# shell expande ${TSV_CLIENTES} y ${TSV_CUENTAS} en las líneas de \copy.
#
# Hace falta porque `\copy` es un meta-comando de psql y NO interpola variables
# de psql: pasarle `:'tsv_clientes'` falla con ":: No such file or directory".
# Las sentencias SQL normales sí las interpolan, pero \copy no.
#
# Todo va en UNA sola sesión de psql porque las tablas son TEMP: se destruyen
# al cerrar la conexión, así que no se puede partir en varias invocaciones.
#
# Consecuencia a tener en cuenta si se edita este SQL: cualquier `$` quedaría
# expandido por el shell. Hoy no hay ninguno.
psql \
  -h 127.0.0.1 -p "${PUERTO}" -U postgres -d "${DB_NAME}" \
  --no-password -v ON_ERROR_STOP=1 <<SQL
BEGIN;

CREATE TEMP TABLE tmp_clientes (
    cliente_hash      TEXT,
    nombre            TEXT,
    apellido          TEXT,
    genero            CHAR(1),
    ciudad            TEXT,
    estado_geo        TEXT,
    codigo_postal     TEXT,
    poblacion_ciudad  INTEGER,
    ocupacion         TEXT,
    fecha_nacimiento  DATE,
    lat_hogar         NUMERIC(9,6),
    long_hogar        NUMERIC(9,6)
) ON COMMIT DROP;

CREATE TEMP TABLE tmp_cuentas (
    cc_num_hash   TEXT,
    cliente_hash  TEXT
) ON COMMIT DROP;

\copy tmp_clientes FROM '${TSV_CLIENTES}' WITH (FORMAT text, DELIMITER E'\t', NULL '\N')
\copy tmp_cuentas  FROM '${TSV_CUENTAS}'  WITH (FORMAT text, DELIMITER E'\t', NULL '\N')

INSERT INTO clientes (
    cliente_hash, nombre_enmascarado, apellido_enmascarado, genero,
    ciudad, estado_geo, codigo_postal, poblacion_ciudad, ocupacion,
    fecha_nacimiento, lat_hogar, long_hogar
)
SELECT
    cliente_hash, nombre, apellido, genero,
    ciudad, estado_geo, codigo_postal, poblacion_ciudad, ocupacion,
    fecha_nacimiento, lat_hogar, long_hogar
FROM tmp_clientes
ON CONFLICT (cliente_hash) DO NOTHING;

-- La FK se resuelve por JOIN: cliente_id lo asignó PostgreSQL al insertar.
INSERT INTO cuentas (cc_num_hash, cliente_id)
SELECT q.cc_num_hash, c.cliente_id
FROM tmp_cuentas q
JOIN clientes c ON c.cliente_hash = q.cliente_hash
ON CONFLICT (cc_num_hash) DO NOTHING;

COMMIT;

SELECT 'clientes cargados: ' || count(*) FROM clientes;
SELECT 'cuentas cargadas:  ' || count(*) FROM cuentas;

-- Verificación: ninguna cuenta puede quedar sin titular.
SELECT 'cuentas huerfanas: ' || count(*)
FROM cuentas q LEFT JOIN clientes c ON c.cliente_id = q.cliente_id
WHERE c.cliente_id IS NULL;
SQL

log "Datos maestros cargados."
