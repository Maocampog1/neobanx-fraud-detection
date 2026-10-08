#!/usr/bin/env bash
# ============================================================================
# test.sh v2 -- flujo transaccional completo, contra el stack LOCAL
# ============================================================================
#
# Prueba generador -> registro -> stub_veredicto -> cierre juntos, con los 5
# casos de la maquina de estados (Backend/contrato_datos_generador.md) mas
# una version local (corta) de la carga sostenida. Ver
# Documentation/sprint2_progreso_juan.md para el estado del bloque.
#
# Requisitos, YA corriendo antes de invocar este script (no los levanta):
#   - Postgres local en 127.0.0.1:5555 (contenedor `neobanx-pg-local`), con
#     Infrastructure/schema.sql aplicado.
#   - Emulador de Pub/Sub en 127.0.0.1:8085 (`gcloud beta emulators pubsub
#     start --host-port=127.0.0.1:8085`), con los topicos/subs reales ya
#     creados: tx-preseleccionadas, tx-veredictos, sub-stub-preseleccionadas,
#     sub-cierre-veredictos.
#   - venv en .venv-local-test/ en la raiz del repo, con las dependencias de
#     los 4 servicios instaladas.
#   - clientes/cuentas cargados (ver scripts/fixtures/carga_local.csv).
#
# Este script SI levanta y apaga registro/cierre/stub_veredicto (puertos
# 8080/8081/8082) -- eso es su trabajo. Postgres y el emulador quedan vivos
# al terminar, para poder re-correr el script sin pagar el arranque otra vez.
#
# Contra la nube real: mismo script, pero las URLs/variables de entorno
# cambian (Cloud Run en vez de localhost, GOOGLE_CLOUD_PROJECT real). Eso se
# aborda cuando subamos run.tf -- este script es deliberadamente agnostico al
# "donde", y en la sesion de nube se reutiliza con otras variables.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_PY="$REPO_ROOT/.venv-local-test/Scripts/python.exe"

export PUBSUB_EMULATOR_HOST="${PUBSUB_EMULATOR_HOST:-127.0.0.1:8085}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-neobanx-local-test}"
export NEOBANX_HMAC_KEY="${NEOBANX_HMAC_KEY:-dev-local-test-key}"
DB_CONTAINER="${DB_CONTAINER:-neobanx-pg-local}"

FALLOS=0

log() { echo "[test.sh] $*"; }
fallo() { echo "[test.sh] FALLO: $*" >&2; FALLOS=$((FALLOS + 1)); }

# --- Utilidades de proceso (por puerto, no por job de bash -- mas confiable
# en Windows/Git Bash, donde $! no siempre mapea al PID real del hijo) -------

puerto_pid() {
  # El `|| true` final es necesario: bajo `set -e` + `pipefail`, que no haya
  # ningun proceso en el puerto (el caso normal antes del primer arranque)
  # hace que los `grep` sin match devuelvan 1 y aborten todo el script.
  netstat -ano | grep ":$1 " | grep LISTENING | awk '{print $NF}' | sort -u | head -1 || true
}

detener_puerto() {
  local pid
  pid="$(puerto_pid "$1")"
  [[ -n "$pid" ]] && taskkill //PID "$pid" //F >/dev/null 2>&1 || true
}

esperar_salud() {
  local puerto="$1" timeout_s="${2:-15}" inicio
  inicio=$(date +%s)
  while ! curl -s -o /dev/null "http://127.0.0.1:${puerto}/salud"; do
    if (( $(date +%s) - inicio > timeout_s )); then
      fallo "servicio en puerto ${puerto} no respondio /salud tras ${timeout_s}s"
      return 1
    fi
    sleep 0.5
  done
}

detener_todos() {
  detener_puerto 8080
  detener_puerto 8081
  detener_puerto 8082
}
trap detener_todos EXIT

# --- Servicios ---------------------------------------------------------------

iniciar_registro() {
  local timeout="$1"
  detener_puerto 8080
  ( cd "$REPO_ROOT/Backend/registro" && \
    DB_HOST=127.0.0.1 DB_PORT=5555 DB_NAME=neobanx \
    DB_USER=app_registro DB_PASSWORD_LOCAL=local-registro-pwd \
    TIMEOUT_VEREDICTO_SEGUNDOS="$timeout" \
    "$VENV_PY" -m uvicorn main:app --host 127.0.0.1 --port 8080 \
  ) > /tmp/test_registro.log 2>&1 &
  esperar_salud 8080
}

iniciar_stub() {
  local retraso="$1"
  detener_puerto 8082
  ( cd "$REPO_ROOT/Backend/stub_veredicto" && \
    RETRASO_SEGUNDOS="$retraso" \
    "$VENV_PY" -m uvicorn main:app --host 127.0.0.1 --port 8082 \
  ) > /tmp/test_stub.log 2>&1 &
  esperar_salud 8082
}

detener_stub() { detener_puerto 8082; }

iniciar_cierre() {
  detener_puerto 8081
  ( cd "$REPO_ROOT/Backend/cierre" && \
    DB_HOST=127.0.0.1 DB_PORT=5555 DB_NAME=neobanx \
    DB_USER=app_cierre DB_PASSWORD_LOCAL=local-cierre-pwd \
    MONITOR_INTERVALO_SEGUNDOS=1 \
    "$VENV_PY" -m uvicorn main:app --host 127.0.0.1 --port 8081 \
  ) > /tmp/test_cierre.log 2>&1 &
  esperar_salud 8081
}

# --- Base de datos / HTTP -----------------------------------------------------

psql_local() {
  docker exec -i "$DB_CONTAINER" psql -U postgres -d neobanx -t -A -c "$1"
}

estado_de() { psql_local "SELECT estado FROM transacciones WHERE trans_num='$1';" | tr -d '[:space:]'; }

esperar_estado() {
  local trans_num="$1" esperado="$2" timeout_s="$3" inicio actual
  inicio=$(date +%s)
  while true; do
    actual="$(estado_de "$trans_num")"
    [[ "$actual" == "$esperado" ]] && return 0
    if (( $(date +%s) - inicio > timeout_s )); then
      fallo "trans_num=$trans_num esperaba estado='$esperado', quedo en '$actual' tras ${timeout_s}s"
      return 1
    fi
    sleep 0.5
  done
}

enviar_transaccion() {
  # $1=trans_num $2=monto $3=cc_num_hash $4=categoria(opcional)
  curl -s -X POST http://127.0.0.1:8080/transacciones -H "Content-Type: application/json" -d "{
    \"trans_num\": \"$1\",
    \"cc_num_hash\": \"$3\",
    \"comercio\": \"Comercio Test\",
    \"categoria\": \"${4:-grocery_pos}\",
    \"monto\": $2,
    \"fecha_hora_transaccion\": \"$(date -u +%Y-%m-%dT%H:%M:%S)\",
    \"lat_comercio\": 6.25,
    \"long_comercio\": -75.56,
    \"is_fraud_real\": 0
  }"
}

CC_HASH="$(psql_local 'SELECT cc_num_hash FROM cuentas LIMIT 1;')"
[[ -n "$CC_HASH" ]] || { echo "No hay cuentas cargadas -- corre primero el seed de clientes/cuentas." >&2; exit 1; }
log "Usando cc_num_hash de prueba: ${CC_HASH:0:12}..."

# Limpiar transacciones de corridas anteriores (clientes/cuentas se conservan).
psql_local "TRUNCATE historial_estados, veredictos, transacciones RESTART IDENTITY CASCADE;" > /dev/null

# ============================================================================
# Fase 1: casos sin necesidad de temporizacion fina -- timeout generoso,
# stub responde casi al instante.
# ============================================================================
log "=== Fase 1: a tiempo, duplicado, trans_num repetido ==="
iniciar_registro 20
iniciar_stub 0
iniciar_cierre

# --- Caso 1: a tiempo --------------------------------------------------------
# monto=999 asegura preseleccion (umbral_monto_preseleccion=200) Y la regla
# del stub (umbral_monto_alto=500) -- resultado determinista: bloqueada.
T1="test-01-a-tiempo"
http=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8080/transacciones -H "Content-Type: application/json" -d "{
  \"trans_num\": \"$T1\", \"cc_num_hash\": \"$CC_HASH\", \"comercio\": \"Test\", \"categoria\": \"grocery_pos\",
  \"monto\": 999.0, \"fecha_hora_transaccion\": \"$(date -u +%Y-%m-%dT%H:%M:%S)\",
  \"lat_comercio\": 6.25, \"long_comercio\": -75.56, \"is_fraud_real\": 0 }")
[[ "$http" == "201" ]] || fallo "caso 1: HTTP $http al registrar"
if esperar_estado "$T1" "bloqueada" 10; then
  tardio=$(psql_local "SELECT tardio FROM veredictos WHERE trans_num='$T1';")
  [[ "$tardio" == "f" ]] || fallo "caso 1: veredicto marcado tardio=true, esperaba false"
  log "Caso 1 (a tiempo): OK"
fi

# --- Caso 4: duplicado -------------------------------------------------------
T4="test-04-duplicado"
r1=$(enviar_transaccion "$T4" 50.0 "$CC_HASH")
r2=$(enviar_transaccion "$T4" 50.0 "$CC_HASH")
if [[ "$r1" == *'"duplicado":false'* ]] && [[ "$r2" == *'"duplicado":true'* ]]; then
  cantidad=$(psql_local "SELECT count(*) FROM transacciones WHERE trans_num='$T4';")
  [[ "$cantidad" == "1" ]] || fallo "caso 4: hay $cantidad filas para $T4, esperaba 1"
  log "Caso 4 (duplicado): OK"
else
  fallo "caso 4: respuestas inesperadas: r1=$r1 r2=$r2"
fi

# --- Caso 5: trans_num repetido con datos distintos --------------------------
T5="test-05-repetido-datos-distintos"
enviar_transaccion "$T5" 10.0 "$CC_HASH" > /dev/null
enviar_transaccion "$T5" 888.0 "$CC_HASH" "shopping_net" > /dev/null  # payload distinto, debe ignorarse
monto_guardado=$(psql_local "SELECT monto FROM transacciones WHERE trans_num='$T5';")
if [[ "$monto_guardado" == "10.00" ]]; then
  log "Caso 5 (trans_num repetido, datos distintos): OK -- se conservo el primer payload (monto=10.00)"
else
  fallo "caso 5: monto guardado fue '$monto_guardado', esperaba 10.00 (el del primer envio)"
fi

# ============================================================================
# Fase 2: caso "tardio" -- timeout corto, stub con retraso mayor al timeout.
# ============================================================================
log "=== Fase 2: veredicto tardio ==="
iniciar_registro 2
iniciar_stub 5

T2="test-02-tardio"
enviar_transaccion "$T2" 999.0 "$CC_HASH" > /dev/null
esperar_estado "$T2" "no_preseleccionada_timeout" 10 && log "Caso 2: cerrada por timeout (esperado, el stub aun no respondio)"
sleep 5  # esperar a que el stub (retraso=5s) por fin publique el veredicto
tardio=$(psql_local "SELECT tardio FROM veredictos WHERE trans_num='$T2';")
estado_final="$(estado_de "$T2")"
if [[ "$tardio" == "t" && "$estado_final" == "no_preseleccionada_timeout" ]]; then
  log "Caso 2 (tardio): OK -- veredicto tardio=true, estado sin cambiar"
else
  fallo "caso 2: tardio='$tardio' estado_final='$estado_final' (esperaba tardio=t, estado sin cambiar)"
fi

# ============================================================================
# Fase 3: caso "timeout puro" -- el stub esta apagado, nunca llega veredicto.
# ============================================================================
log "=== Fase 3: timeout puro (sin stub) ==="
detener_stub

T3="test-03-timeout-puro"
enviar_transaccion "$T3" 999.0 "$CC_HASH" > /dev/null
if esperar_estado "$T3" "no_preseleccionada_timeout" 10; then
  veredictos_t3=$(psql_local "SELECT count(*) FROM veredictos WHERE trans_num='$T3';")
  [[ "$veredictos_t3" == "0" ]] || fallo "caso 3: hay $veredictos_t3 veredictos para $T3, esperaba 0 (nunca deberia llegar ninguno)"
  log "Caso 3 (timeout puro): OK"
fi

# ============================================================================
# Fase 4: carga sostenida -- version local corta (la version completa de
# 10 tx/s x 10 min se corre una sola vez contra la nube real, no aqui).
# ============================================================================
log "=== Fase 4: carga sostenida (local, corta) ==="
iniciar_registro 20
iniciar_stub 0

CARGA_CSV="${CARGA_CSV:-$REPO_ROOT/scripts/fixtures/carga_local.csv}"
CARGA_TX_POR_SEGUNDO="${CARGA_TX_POR_SEGUNDO:-10}"

( cd "$REPO_ROOT/Backend/generador" && \
  REGISTRO_URL=http://127.0.0.1:8080 \
  CSV_PATH="$CARGA_CSV" DATASET_URL="file:///$CARGA_CSV" \
  TX_POR_SEGUNDO="$CARGA_TX_POR_SEGUNDO" \
  "$VENV_PY" main.py ) > /tmp/test_carga.log 2>&1
errores_generador=$(grep -c '^Traceback\|RuntimeError' /tmp/test_carga.log || true)
enviadas=$(grep -c '^\[20' /tmp/test_carga.log || true)
log "Carga sostenida: ${enviadas} transacciones enviadas, ${errores_generador} errores en el generador"
[[ "$errores_generador" == "0" ]] || fallo "carga sostenida: el generador reporto errores, ver /tmp/test_carga.log"

# Dar tiempo a que el stub (retraso=0) procese todo -- con timeout=20s no
# deberia quedar NINGUNA pendiente sin resolver, mucho antes de que venza.
sleep 5
pendientes_sin_resolver=$(psql_local "SELECT count(*) FROM transacciones WHERE estado='pendiente_analisis';")
if [[ "$pendientes_sin_resolver" == "0" ]]; then
  log "Carga sostenida: OK -- 0 pendientes sin resolver"
else
  fallo "carga sostenida: quedaron $pendientes_sin_resolver pendientes sin resolver (el stub no deberia tardar mas de unos ms por transaccion)"
fi
atascadas_en_recibida=$(psql_local "SELECT count(*) FROM transacciones WHERE estado='recibida';")
[[ "$atascadas_en_recibida" == "0" ]] || fallo "carga sostenida: $atascadas_en_recibida transacciones atascadas en 'recibida'"

# ============================================================================
log "=============================================="
if [[ "$FALLOS" == "0" ]]; then
  log "TODOS LOS CASOS PASARON"
  exit 0
else
  log "$FALLOS CASO(S) FALLARON -- revisar los mensajes de FALLO arriba"
  exit 1
fi
