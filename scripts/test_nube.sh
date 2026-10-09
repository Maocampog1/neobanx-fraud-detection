#!/usr/bin/env bash
# ============================================================================
# test_nube.sh — flujo transaccional completo, contra la NUBE REAL
# ============================================================================
#
# Equivalente a scripts/test.sh pero contra los 3 Cloud Run reales
# (registro/cierre/stub-veredicto) en vez del stack local. Pensado para
# correr UNA sola vez, dentro de la imagen de herramientas (necesita gcloud,
# cloud-sql-proxy, psql):
#
#   docker run --rm \
#     -v <config-gcloud-autenticada>:/root/.config/gcloud \
#     -v $(pwd):/workspace \
#     neobanx-deploy -c "cd /workspace && ./scripts/test_nube.sh"
#
# Modifica TEMPORALMENTE las variables de entorno de `registro` y
# `stub-veredicto` en Cloud Run (via `gcloud run services update`) para
# forzar los casos de timeout/tardío sin esperar el timeout real de 30s.
# Son cambios de prueba, no de diseño -- no se reflejan en Terraform y no
# importa si quedan así, porque este flujo se destruye al terminar la sesión.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"
REGION="${REGION:-us-central1}"
INSTANCE_CONNECTION_NAME="${PROJECT_ID}:${REGION}:neobanx-transaccional"

FALLOS=0
log() { echo "[test_nube] $*"; }
fallo() { echo "[test_nube] FALLO: $*" >&2; FALLOS=$((FALLOS + 1)); }

REGISTRO_URL="$(gcloud run services describe registro --region="$REGION" --project="$PROJECT_ID" --format='value(status.url)')"
TOKEN="$(gcloud auth print-identity-token)"
log "registro: ${REGISTRO_URL}"

# --- Cloud SQL proxy (para verificar estado en la base real) -----------------

PUERTO_PROXY=5435
# postgres (superusuario), no agente_ro: agente_ro solo puede leer vistas
# (v_historial_cliente, linaje_transaccion, alertas), no las tablas base
# que este script necesita verificar (transacciones, veredictos, cuentas).
POSTGRES_PWD="$(gcloud secrets versions access latest --secret=neobanx-db-postgres --project="$PROJECT_ID")"

cloud-sql-proxy --address 127.0.0.1 --port "$PUERTO_PROXY" "$INSTANCE_CONNECTION_NAME" &
PROXY_PID=$!

limpiar() {
  kill "$PROXY_PID" 2>/dev/null || true
  wait "$PROXY_PID" 2>/dev/null || true
}
trap limpiar EXIT

for _ in $(seq 1 30); do
  pg_isready -h 127.0.0.1 -p "$PUERTO_PROXY" -U postgres >/dev/null 2>&1 && break
  sleep 1
done

psql_cloud() {
  PGPASSWORD="$POSTGRES_PWD" psql -h 127.0.0.1 -p "$PUERTO_PROXY" -U postgres -d neobanx -t -A -c "$1"
}

estado_de() { psql_cloud "SELECT estado FROM transacciones WHERE trans_num='$1';" | tr -d '[:space:]'; }

esperar_estado() {
  local trans_num="$1" esperado="$2" timeout_s="$3" inicio actual
  inicio=$(date +%s)
  while true; do
    actual="$(estado_de "$trans_num")"
    [[ "$actual" == "$esperado" ]] && return 0
    if (( $(date +%s) - inicio > timeout_s )); then
      fallo "trans_num=$trans_num esperaba estado='$esperado', quedó en '$actual' tras ${timeout_s}s"
      return 1
    fi
    sleep 1
  done
}

enviar_transaccion() {
  curl -s -X POST "$REGISTRO_URL/transacciones" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{
    \"trans_num\": \"$1\", \"cc_num_hash\": \"$3\", \"comercio\": \"Test nube\", \"categoria\": \"${4:-grocery_pos}\",
    \"monto\": $2, \"fecha_hora_transaccion\": \"$(date -u +%Y-%m-%dT%H:%M:%S)\",
    \"lat_comercio\": 6.25, \"long_comercio\": -75.56, \"is_fraud_real\": 0 }"
}

CC_HASH="$(psql_cloud 'SELECT cc_num_hash FROM cuentas LIMIT 1;')"
[[ -n "$CC_HASH" ]] || { echo "No hay cuentas cargadas en la nube." >&2; exit 1; }
log "cc_num_hash de prueba: ${CC_HASH:0:12}..."

# ============================================================================
# Fase 1: config por defecto (timeout=30s, stub retraso=0 ya desplegados) --
# a tiempo, duplicado, trans_num repetido.
# ============================================================================
log "=== Fase 1: a tiempo, duplicado, trans_num repetido ==="

T1="test-nube-01-a-tiempo-$(date +%s)"
http=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$REGISTRO_URL/transacciones" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{
  \"trans_num\": \"$T1\", \"cc_num_hash\": \"$CC_HASH\", \"comercio\": \"Test\", \"categoria\": \"grocery_pos\",
  \"monto\": 999.0, \"fecha_hora_transaccion\": \"$(date -u +%Y-%m-%dT%H:%M:%S)\",
  \"lat_comercio\": 6.25, \"long_comercio\": -75.56, \"is_fraud_real\": 0 }")
[[ "$http" == "201" ]] || fallo "caso 1: HTTP $http"
if esperar_estado "$T1" "bloqueada" 15; then
  tardio=$(psql_cloud "SELECT tardio FROM veredictos WHERE trans_num='$T1';")
  [[ "$tardio" == "f" ]] || fallo "caso 1: tardio=true, esperaba false"
  log "Caso 1 (a tiempo): OK"
fi

T4="test-nube-04-duplicado-$(date +%s)"
r1=$(enviar_transaccion "$T4" 50.0 "$CC_HASH")
r2=$(enviar_transaccion "$T4" 50.0 "$CC_HASH")
if [[ "$r1" == *'"duplicado":false'* ]] && [[ "$r2" == *'"duplicado":true'* ]]; then
  cantidad=$(psql_cloud "SELECT count(*) FROM transacciones WHERE trans_num='$T4';")
  [[ "$cantidad" == "1" ]] || fallo "caso 4: hay $cantidad filas, esperaba 1"
  log "Caso 4 (duplicado): OK"
else
  fallo "caso 4: respuestas inesperadas r1=$r1 r2=$r2"
fi

T5="test-nube-05-repetido-$(date +%s)"
enviar_transaccion "$T5" 10.0 "$CC_HASH" > /dev/null
enviar_transaccion "$T5" 888.0 "$CC_HASH" "shopping_net" > /dev/null
monto_guardado=$(psql_cloud "SELECT monto FROM transacciones WHERE trans_num='$T5';")
if [[ "$monto_guardado" == "10.00" ]]; then
  log "Caso 5 (repetido, datos distintos): OK"
else
  fallo "caso 5: monto='$monto_guardado', esperaba 10.00"
fi

# ============================================================================
# Fase 2: timeout corto en registro (5s) + stub con retraso mayor (20s) --
# prueba a la vez el cierre por timeout Y el veredicto tardío sobre esa
# misma fila. (El caso "nunca llega ningún veredicto" ya se probó aislado y
# determinista en local, directo contra `cierre`, sin stub de por medio --
# no se repite aquí porque "apagar" un pull-worker de Cloud Run sin borrar
# el servicio no tiene una forma limpia: `--max-instances=0` no es válido.)
# ============================================================================
log "=== Fase 2: timeout (5s) + veredicto tardío (stub con retraso=20s) ==="
gcloud run services update registro --region="$REGION" --project="$PROJECT_ID" \
  --update-env-vars="TIMEOUT_VEREDICTO_SEGUNDOS=5" --quiet >/dev/null
gcloud run services update stub-veredicto --region="$REGION" --project="$PROJECT_ID" \
  --update-env-vars="RETRASO_SEGUNDOS=20" --quiet >/dev/null

T2="test-nube-02-tardio-$(date +%s)"
enviar_transaccion "$T2" 999.0 "$CC_HASH" > /dev/null
esperar_estado "$T2" "no_preseleccionada_timeout" 20 && log "Caso 2/3: cerrada por timeout antes de que respondiera el stub (esperado)"
sleep 20  # esperar el veredicto tardío del stub (retraso=20s)
tardio=$(psql_cloud "SELECT tardio FROM veredictos WHERE trans_num='$T2';")
estado_final="$(estado_de "$T2")"
if [[ "$tardio" == "t" && "$estado_final" == "no_preseleccionada_timeout" ]]; then
  log "Caso 2 (tardío): OK"
else
  fallo "caso 2: tardio='$tardio' estado='$estado_final'"
fi

# ============================================================================
# Fase 4: restaurar config normal, carga breve de verificación.
# ============================================================================
log "=== Fase 4: restaurando config y carga breve ==="
gcloud run services update registro --region="$REGION" --project="$PROJECT_ID" \
  --update-env-vars="TIMEOUT_VEREDICTO_SEGUNDOS=30" --quiet >/dev/null
gcloud run services update stub-veredicto --region="$REGION" --project="$PROJECT_ID" \
  --update-env-vars="RETRASO_SEGUNDOS=0" --quiet >/dev/null

PIDS_CARGA=()
for i in $(seq 1 10); do
  T="test-nube-carga-${i}-$(date +%s)"
  enviar_transaccion "$T" "$((RANDOM % 50 + 1))" "$CC_HASH" > /dev/null &
  PIDS_CARGA+=($!)
done
# `wait` sin argumentos esperaria TAMBIEN a cloud-sql-proxy (corre en
# background desde el inicio del script y nunca termina solo) -- hay que
# esperar especificamente los PID de estos 10 envios, o el script se
# queda colgado para siempre.
wait "${PIDS_CARGA[@]}"
sleep 8
pendientes=$(psql_cloud "SELECT count(*) FROM transacciones WHERE estado='pendiente_analisis';")
if [[ "$pendientes" == "0" ]]; then
  log "Carga breve: OK -- 0 pendientes sin resolver"
else
  fallo "carga breve: $pendientes pendientes sin resolver"
fi

log "=============================================="
if [[ "$FALLOS" == "0" ]]; then
  log "TODOS LOS CASOS PASARON (NUBE REAL)"
  exit 0
else
  log "$FALLOS CASO(S) FALLARON -- revisar los mensajes de FALLO arriba"
  exit 1
fi
