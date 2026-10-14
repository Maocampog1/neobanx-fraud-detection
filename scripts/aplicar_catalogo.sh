#!/usr/bin/env bash
# ============================================================================
# aplicar_catalogo.sh — metadatos de gobierno para Dataplex Catalog
# ============================================================================
#
# Pone descripción y etiquetas (data_owner, data_steward, dominio,
# clasificacion, capa) a las tablas que NO crea el SQL del modelo:
#   - las de `raw`, que crea Datastream;
#   - analitica.festivos_us, que carga cargar_festivos.sh.
# Las tablas del modelo y de calidad llevan sus etiquetas en su propio SQL
# (modelo_estrella.sql y calidad.sql), porque se recrean cada 15 minutos.
#
# Dataplex Catalog lee estas descripciones y etiquetas solo: se puede buscar
# por ejemplo  label:data_steward=maria_ocampo
#
# Es idempotente. Si una tabla de raw todavía no existe (Datastream la crea
# con su primera fila), se avisa y se sigue.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-neobanx-fraud-detection}"

etiquetar() {
  local tabla="$1" descripcion="$2"
  shift 2

  if ! bq --project_id="${PROJECT_ID}" show "${tabla}" >/dev/null 2>&1; then
    echo "[catalogo] AVISO: ${tabla} todavía no existe, se omite"
    return 0
  fi

  local args=()
  for etiqueta in "$@"; do
    args+=(--set_label "${etiqueta}")
  done

  bq --project_id="${PROJECT_ID}" update --description "${descripcion}" "${args[@]}" "${tabla}" >/dev/null
  echo "[catalogo]   ${tabla}"
}

echo "[catalogo] Aplicando descripciones y etiquetas de gobierno"

# --- Dominio transaccional (Owner: Riesgo y Fraude, Steward: Juan Esteban) ---
etiquetar raw.public_transacciones \
  "Réplica CDC (Datastream) de public.transacciones en Cloud SQL: una fila por transacción con su estado en la máquina de estados." \
  data_owner:gerencia_riesgo_fraude data_steward:juan_alzate \
  dominio:transaccional clasificacion:confidencial capa:raw

etiquetar raw.public_veredictos \
  "Réplica CDC de public.veredictos: decisión del motor de reglas por transacción preseleccionada (incluye veredictos tardíos)." \
  data_owner:gerencia_riesgo_fraude data_steward:juan_alzate \
  dominio:transaccional clasificacion:confidencial capa:raw

etiquetar raw.public_historial_estados \
  "Réplica CDC de public.historial_estados: cada cambio de estado de una transacción con su momento (auditoría de la máquina de estados)." \
  data_owner:gerencia_riesgo_fraude data_steward:juan_alzate \
  dominio:transaccional clasificacion:confidencial capa:raw

# --- Dominio clientes y cuentas (Owner: Protección de Datos, Steward: Camilo) ---
etiquetar raw.public_clientes \
  "Réplica CDC de public.clientes. Contiene PII: columnas protegidas con policy tags PII_alta y Cuasi_identificador." \
  data_owner:oficial_proteccion_datos data_steward:camilo_salazar \
  dominio:clientes clasificacion:restringida_pii capa:raw

etiquetar raw.public_cuentas \
  "Réplica CDC de public.cuentas: relación tarjeta-cliente. La tarjeta solo aparece seudonimizada (cc_num_hash, HMAC); nunca el número real." \
  data_owner:oficial_proteccion_datos data_steward:camilo_salazar \
  dominio:clientes clasificacion:confidencial capa:raw

# --- Referencia (Owner: Riesgo y Fraude, Steward: María Alejandra) ---
etiquetar analitica.festivos_us \
  "Festivos de EE. UU. 2019-2021 cargados desde la API pública Nager.Date. Alimenta dim_tiempo." \
  data_owner:gerencia_riesgo_fraude data_steward:maria_ocampo \
  dominio:referencia clasificacion:publica capa:analitica

echo "[catalogo] Listo."