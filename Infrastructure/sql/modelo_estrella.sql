-- ============================================================================
-- modelo_estrella.sql — capa analítica (dataset `analitica`)
-- ============================================================================
--
-- QUIÉN LO EJECUTA
--   - La consulta programada de BigQuery, cada 15 minutos
--     (Infrastructure/analitica.tf).
--   - A demanda: scripts/construir_analitica.sh (útil en la demo, para no
--     esperar los 15 minutos).
--
-- CÓMO FUNCIONA
--   Reconstruye el modelo completo desde la réplica `raw` (Datastream) en cada
--   corrida. Con el volumen del proyecto (miles de filas), reconstruir es más
--   simple y más seguro que un MERGE incremental, y deja el script idempotente.
--
-- ORDEN DELIBERADO
--   Primero va lo que NO depende de `raw` (dim_estado, dim_tiempo). Datastream
--   solo crea una tabla en `raw` cuando le llega su primera fila: justo después
--   de un deploy, las tablas de transacciones y veredictos todavía no existen.
--   Las corridas fallan hasta que entra la primera transacción, y eso es
--   esperado: no rompe el deploy ni deja nada a medias.
--
-- PII
--   Ningún objeto de este dataset expone PII en claro. La única tabla con
--   datos de cliente es clientes_enmascarados, y solo con valores
--   generalizados (inicial, año, código postal truncado), sin ciudad ni
--   coordenadas (Documentation/reglas_calidad_neobanx.md, sección 6).
--
-- CATÁLOGO (Dataplex)
--   Cada objeto lleva descripción y etiquetas de gobierno: data_owner,
--   data_steward, dominio, clasificacion y capa. Van aquí (no en un script
--   aparte) porque CREATE OR REPLACE recrea la tabla cada 15 minutos y
--   borraría cualquier etiqueta puesta desde afuera.
--
-- TIPOS
--   Los CAST a DATE/TIMESTAMP son a propósito: hacen que el script funcione
--   igual si Datastream replica una columna como DATETIME o como TIMESTAMP.

-- ---------------------------------------------------------------------------
-- dim_estado: los 6 estados de la máquina de estados de `transacciones`
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE analitica.dim_estado
OPTIONS (
  description = 'Dimensión de estados: los 6 estados de la máquina de estados de una transacción.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT * FROM UNNEST([
  STRUCT(
    'recibida'                    AS estado,
    'Recibida, sin decisión aún'  AS descripcion,
    FALSE                         AS es_terminal,
    FALSE                         AS fue_analizada
  ),
  ('sin_analizar',               'No preseleccionada para análisis',                TRUE,  FALSE),
  ('pendiente_analisis',         'Esperando veredicto del motor de detección',      FALSE, FALSE),
  ('aprobada',                   'Analizada y aprobada',                            TRUE,  TRUE),
  ('bloqueada',                  'Analizada y bloqueada (alerta de fraude)',        TRUE,  TRUE),
  ('no_preseleccionada_timeout', 'Preseleccionada, sin veredicto antes del plazo',  TRUE,  FALSE)
]);

-- ---------------------------------------------------------------------------
-- dim_tiempo: un día por fila, con la bandera de festivo (Nager.Date)
-- ---------------------------------------------------------------------------
-- El rango cubre todo el dataset Sparkov (2019-2020) con margen.
CREATE OR REPLACE TABLE analitica.dim_tiempo
OPTIONS (
  description = 'Dimensión de tiempo: un día por fila (2019-2021) con día de la semana, fin de semana y festivos de EE. UU. (Nager.Date).',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "publica"), ("capa", "analitica")]
)
AS
SELECT
  d                                   AS fecha,
  EXTRACT(YEAR FROM d)                AS anio,
  EXTRACT(MONTH FROM d)               AS mes,
  EXTRACT(DAY FROM d)                 AS dia,
  EXTRACT(DAYOFWEEK FROM d)           AS dia_semana_num,   -- 1 = domingo
  FORMAT_DATE('%A', d)                AS dia_semana,
  EXTRACT(DAYOFWEEK FROM d) IN (1, 7) AS es_fin_de_semana,
  f.fecha IS NOT NULL                 AS es_festivo,
  f.nombre                            AS nombre_festivo
FROM UNNEST(GENERATE_DATE_ARRAY('2019-01-01', '2021-12-31')) AS d
LEFT JOIN (
  -- Nager.Date puede traer el mismo día dos veces (festivos estatales).
  SELECT fecha, STRING_AGG(DISTINCT nombre, ' / ') AS nombre
  FROM analitica.festivos_us
  GROUP BY fecha
) AS f
  ON f.fecha = d;

-- ---------------------------------------------------------------------------
-- dim_cliente: SIN PII
-- ---------------------------------------------------------------------------
-- La edad se calcula contra el final del dataset (2020-12-31), no contra
-- hoy, para que el rango sea estable y coherente con las fechas de las
-- transacciones.
CREATE OR REPLACE TABLE analitica.dim_cliente
OPTIONS (
  description = 'Dimensión de clientes SIN PII: estado (geográfico), rango de edad y tipo de ciudad.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT
  cliente_id,
  estado_geo,
  CASE
    WHEN edad < 25 THEN '18-24'
    WHEN edad < 40 THEN '25-39'
    WHEN edad < 55 THEN '40-54'
    WHEN edad < 70 THEN '55-69'
    ELSE '70+'
  END AS rango_edad,
  CASE
    WHEN poblacion_ciudad < 10000  THEN 'rural (<10k)'
    WHEN poblacion_ciudad < 100000 THEN 'mediana (10k-100k)'
    ELSE 'urbana (100k+)'
  END AS tipo_ciudad
FROM (
  SELECT
    cliente_id,
    estado_geo,
    poblacion_ciudad,
    DATE_DIFF(DATE '2020-12-31', CAST(fecha_nacimiento AS DATE), YEAR) AS edad
  FROM raw.public_clientes
);

-- ---------------------------------------------------------------------------
-- clientes_enmascarados: capa de PII enmascarada (enmascaramiento ESTÁTICO)
-- ---------------------------------------------------------------------------
-- La genera sa-analitica, la única cuenta (con Datastream) que puede leer las
-- columnas con policy tag en raw.public_clientes. Reemplaza al enmascaramiento
-- dinámico de BigQuery, que exige una organización (ver gobernanza.tf).
-- Generalización aplicada:
--   nombre/apellido  -> primera letra + '***'
--   fecha_nacimiento -> solo el año
--   codigo_postal    -> primeros 3 dígitos + 'XX'
--   ciudad, coordenadas, género y ocupación -> se omiten
CREATE OR REPLACE TABLE analitica.clientes_enmascarados
OPTIONS (
  description = 'Clientes con PII enmascarada por generalización (inicial + ***, año de nacimiento, código postal truncado). Sin ciudad ni coordenadas.',
  labels = [("data_owner", "oficial_proteccion_datos"), ("data_steward", "maria_ocampo"),
            ("dominio", "clientes"), ("clasificacion", "pii_enmascarada"), ("capa", "analitica")]
)
AS
SELECT
  cliente_id,
  CONCAT(SUBSTR(CAST(nombre_enmascarado AS STRING), 1, 1), '***')   AS nombre,
  CONCAT(SUBSTR(CAST(apellido_enmascarado AS STRING), 1, 1), '***') AS apellido,
  EXTRACT(YEAR FROM CAST(fecha_nacimiento AS DATE))                 AS anio_nacimiento,
  estado_geo,
  CONCAT(SUBSTR(CAST(codigo_postal AS STRING), 1, 3), 'XX')         AS codigo_postal_aprox
FROM raw.public_clientes;

-- ---------------------------------------------------------------------------
-- dim_comercio
-- ---------------------------------------------------------------------------
-- El generador ya quita el prefijo `fraud_`; se vuelve a quitar aquí como
-- red de seguridad, porque es una convención del dataset, no una señal de
-- fraude (Documentation/reglas_calidad_neobanx.md, sección 5).
CREATE OR REPLACE TABLE analitica.dim_comercio
OPTIONS (
  description = 'Dimensión de comercios (sin el prefijo fraud_ del dataset) con su categoría principal.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT
  FARM_FINGERPRINT(comercio) AS comercio_id,
  comercio,
  ANY_VALUE(categoria)       AS categoria_principal
FROM (
  SELECT REGEXP_REPLACE(comercio, r'^fraud_', '') AS comercio, categoria
  FROM raw.public_transacciones
)
GROUP BY comercio;

-- ---------------------------------------------------------------------------
-- fact_transacciones: particionada por fecha, clustering por estado y categoría
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE analitica.fact_transacciones
PARTITION BY fecha
CLUSTER BY estado, categoria
OPTIONS (
  description = 'Hechos: una fila por transacción (grano). Estado final, veredicto efectivo, reglas disparadas y latencia de cierre. Particionada por fecha.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
WITH veredicto_efectivo AS (
  -- Una transacción puede tener más de un veredicto (uno a tiempo y otro
  -- tardío, o duplicados si corren el stub y Flink a la vez). Se toma el que
  -- cuenta: primero el que llegó a tiempo, y entre iguales el más antiguo.
  SELECT
    trans_num,
    resultado,
    reglas_disparadas,
    version_reglas,
    tardio
  FROM raw.public_veredictos
  WHERE TRUE
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY trans_num
    ORDER BY tardio, CAST(evaluado_at AS TIMESTAMP)
  ) = 1
)
SELECT
  t.trans_num,
  CAST(t.fecha_hora_transaccion AS DATE)                        AS fecha,
  EXTRACT(HOUR FROM t.fecha_hora_transaccion)                   AS hora,
  q.cliente_id,
  FARM_FINGERPRINT(REGEXP_REPLACE(t.comercio, r'^fraud_', ''))  AS comercio_id,
  t.categoria,
  t.estado,
  CAST(t.monto AS NUMERIC)                                      AS monto,
  IFNULL(t.motivo_preseleccion NOT IN ('no_preseleccionada'), FALSE)
                                                                AS preseleccionada,
  t.motivo_preseleccion,
  v.resultado                                                   AS resultado_veredicto,
  IFNULL(JSON_VALUE_ARRAY(v.reglas_disparadas), [])             AS reglas_disparadas,
  v.version_reglas,
  v.tardio                                                      AS veredicto_tardio,
  TIMESTAMP_DIFF(
    CAST(t.finalizada_at AS TIMESTAMP),
    CAST(t.created_at AS TIMESTAMP),
    MILLISECOND
  ) / 1000                                                      AS latencia_cierre_seg,
  -- Solo para medir falsos positivos/negativos. Nunca entra a una regla.
  t.is_fraud_real
FROM raw.public_transacciones AS t
LEFT JOIN raw.public_cuentas  AS q USING (cc_num_hash)
LEFT JOIN veredicto_efectivo  AS v USING (trans_num);

-- ---------------------------------------------------------------------------
-- linaje_transaccion: el recorrido de UNA transacción por la plataforma
-- ---------------------------------------------------------------------------
-- Una fila por paso, sobre la réplica `raw` (lo que pasó en Cloud SQL) y el
-- modelo analítico. Uso:
--   SELECT * FROM analitica.linaje_transaccion
--   WHERE trans_num = '...' ORDER BY orden;
-- Va al final porque lee fact_transacciones, que se crea justo arriba.
CREATE OR REPLACE VIEW analitica.linaje_transaccion
OPTIONS (
  description = 'Linaje por transacción: registro, veredicto, cierre, réplica CDC y modelo analítico, en orden.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "gobierno"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
WITH t AS (
  SELECT
    trans_num,
    estado,
    motivo_preseleccion,
    CAST(created_at AS TIMESTAMP)    AS creada_at,
    CAST(finalizada_at AS TIMESTAMP) AS finalizada_at
  FROM raw.public_transacciones
)
SELECT
  trans_num,
  1                                                           AS orden,
  'registro'                                                  AS paso,
  'Generador -> Cloud Run registro -> Cloud SQL transacciones' AS recorrido,
  creada_at                                                   AS momento,
  CONCAT('motivo_preseleccion=', IFNULL(motivo_preseleccion, 'n/a')) AS detalle
FROM t

UNION ALL
SELECT
  v.trans_num,
  2,
  IF(v.tardio, 'veredicto_tardio', 'veredicto'),
  'Pub/Sub tx-preseleccionadas -> motor de reglas -> Pub/Sub tx-veredictos -> Cloud Run cierre -> Cloud SQL veredictos',
  CAST(v.evaluado_at AS TIMESTAMP),
  CONCAT(
    'resultado=', IFNULL(CAST(v.resultado AS STRING), 'n/a'),
    ' | reglas=', ARRAY_TO_STRING(IFNULL(JSON_VALUE_ARRAY(v.reglas_disparadas), []), ','),
    ' | version_reglas=', IFNULL(CAST(v.version_reglas AS STRING), 'n/a')
  )
FROM raw.public_veredictos AS v

UNION ALL
SELECT
  trans_num,
  3,
  'cierre',
  'Cloud Run cierre -> Cloud SQL transacciones',
  finalizada_at,
  CONCAT('estado_final=', estado)
FROM t
WHERE finalizada_at IS NOT NULL

UNION ALL
SELECT
  trans_num,
  4,
  'replica_cdc',
  'Datastream -> BigQuery raw.public_transacciones y raw.public_veredictos',
  CAST(NULL AS TIMESTAMP),
  'fila replicada en raw'
FROM t

UNION ALL
SELECT
  trans_num,
  5,
  'modelo_analitico',
  'Consulta programada -> analitica.fact_transacciones',
  CAST(NULL AS TIMESTAMP),
  CONCAT('estado=', estado, ' | latencia_cierre_seg=', IFNULL(CAST(latencia_cierre_seg AS STRING), 'n/a'))
FROM analitica.fact_transacciones;

-- ---------------------------------------------------------------------------
-- Vistas para el tablero (Looker Studio)
-- ---------------------------------------------------------------------------
-- Looker Studio trabaja mejor con tablas planas que con uniones. Estas vistas
-- entregan el modelo ya unido y los KPIs ya calculados. No guardan datos: se
-- calculan al consultarlas, así que siempre muestran lo último del modelo.
--
-- KPIs (sección 3.3 del documento del proyecto):
--   1. % de fraude detectado en tiempo real   | SLA: latencia < 5 s
--   2. % de falsos positivos                  | SLA: precisión de las reglas
--   3. Ranking de operaciones más riesgosas   | SLA: tablero < 5 s
--   4. % de transacciones completas           | SLA: completitud > 95 %
--   5. % de alertas consistentes              | SLA: ACID, escritura < 5 s

-- v_tablero_transacciones: una fila por transacción, con dimensiones y banderas
-- 0/1 (en Looker se suman para obtener conteos y porcentajes).
CREATE OR REPLACE VIEW analitica.v_tablero_transacciones
OPTIONS (
  description = 'Tablero: fact_transacciones unida con sus dimensiones, con banderas 0/1 para los KPIs. Fuente principal de Looker Studio.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
WITH conteo_veredictos AS (
  -- Cuántos veredictos tuvo cada transacción: sirve para el KPI 5
  -- (alertas sin duplicar ni perder).
  SELECT
    trans_num,
    COUNTIF(NOT tardio) AS n_a_tiempo,
    COUNTIF(tardio)     AS n_tardios
  FROM raw.public_veredictos
  GROUP BY trans_num
),
base AS (
  SELECT
    f.*,
    e.descripcion            AS estado_descripcion,
    e.es_terminal,
    e.fue_analizada,
    t.dia_semana,
    t.dia_semana_num,
    t.es_fin_de_semana,
    t.es_festivo,
    t.nombre_festivo,
    c.estado_geo,
    c.rango_edad,
    c.tipo_ciudad,
    m.comercio,
    IFNULL(v.n_a_tiempo, 0)  AS n_a_tiempo,
    IFNULL(v.n_tardios, 0)   AS n_tardios
  FROM analitica.fact_transacciones AS f
  LEFT JOIN analitica.dim_estado    AS e USING (estado)
  LEFT JOIN analitica.dim_tiempo    AS t USING (fecha)
  LEFT JOIN analitica.dim_cliente   AS c USING (cliente_id)
  LEFT JOIN analitica.dim_comercio  AS m USING (comercio_id)
  LEFT JOIN conteo_veredictos       AS v USING (trans_num)
)
SELECT
  trans_num,
  fecha,
  hora,
  dia_semana,
  dia_semana_num,
  es_fin_de_semana,
  es_festivo,
  nombre_festivo,
  categoria,
  comercio,
  estado_geo,
  rango_edad,
  tipo_ciudad,
  estado,
  estado_descripcion,
  monto,
  preseleccionada,
  motivo_preseleccion,
  resultado_veredicto,
  ARRAY_TO_STRING(reglas_disparadas, ', ')                            AS reglas_disparadas,
  version_reglas,
  latencia_cierre_seg,
  is_fraud_real,
  n_a_tiempo                                                          AS n_veredictos_a_tiempo,
  n_tardios                                                           AS n_veredictos_tardios,

  -- Estados
  IF(estado IN ('aprobada', 'bloqueada'), 1, 0)                       AS es_analizada,
  IF(estado = 'bloqueada', 1, 0)                                      AS es_bloqueada,
  IF(estado = 'no_preseleccionada_timeout', 1, 0)                     AS es_timeout,
  IF(n_tardios > 0, 1, 0)                                             AS es_tardio,
  IF(preseleccionada, 1, 0)                                           AS es_preseleccionada,

  -- KPI 1 y 2: detección frente a la etiqueta real del dataset
  IF(is_fraud_real = 1, 1, 0)                                         AS es_fraude_real,
  IF(is_fraud_real = 1 AND estado = 'bloqueada', 1, 0)                AS es_fraude_detectado,
  IF(is_fraud_real = 1 AND estado != 'bloqueada', 1, 0)               AS es_fraude_no_detectado,
  IF(is_fraud_real = 0 AND estado = 'bloqueada', 1, 0)                AS es_falso_positivo,

  -- SLA 1: analizada y cerrada en menos de 5 segundos
  IF(estado IN ('aprobada', 'bloqueada') AND latencia_cierre_seg < 5, 1, 0) AS es_dentro_sla,

  -- KPI 4: campos clave presentes
  IF(cliente_id IS NOT NULL AND comercio_id IS NOT NULL AND categoria IS NOT NULL
     AND monto IS NOT NULL AND fecha IS NOT NULL AND hora IS NOT NULL, 1, 0) AS es_completa,

  -- KPI 5: cada alerta registrada una sola vez, sin pérdidas
  IF(preseleccionada AND n_a_tiempo = 1 AND estado IN ('aprobada', 'bloqueada'), 1, 0) AS es_alerta_consistente,
  IF(n_a_tiempo > 1, 1, 0)                                            AS es_alerta_duplicada,
  IF(preseleccionada AND n_a_tiempo = 0, 1, 0)                        AS es_alerta_perdida,

  -- Dinero: fraude frenado y fraude que se escapó
  IF(is_fraud_real = 1 AND estado = 'bloqueada', monto, 0)            AS monto_fraude_bloqueado,
  IF(is_fraud_real = 1 AND estado != 'bloqueada', monto, 0)           AS monto_fraude_no_detectado
FROM base;

-- v_tablero_kpis: UNA fila con los 5 KPIs y sus SLA, ya calculados.
-- Alimenta las tarjetas (scorecards) del resumen ejecutivo.
CREATE OR REPLACE VIEW analitica.v_tablero_kpis
OPTIONS (
  description = 'Tablero: los 5 KPIs del proyecto y sus SLA, en una sola fila.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT
  COUNT(*)                                                       AS total_transacciones,
  SUM(es_preseleccionada)                                        AS preseleccionadas,
  SUM(es_analizada)                                              AS analizadas,
  SAFE_DIVIDE(SUM(es_analizada), COUNT(*))                       AS pct_analizadas,
  SUM(es_bloqueada)                                              AS bloqueadas,
  SUM(es_timeout)                                                AS timeouts,
  SUM(es_tardio)                                                 AS tardios,

  -- KPI 1 + SLA
  SUM(es_fraude_real)                                            AS fraudes_reales,
  SUM(es_fraude_detectado)                                       AS fraudes_detectados,
  SAFE_DIVIDE(SUM(es_fraude_detectado), SUM(es_fraude_real))     AS kpi1_pct_fraude_detectado,
  SAFE_DIVIDE(SUM(es_dentro_sla), SUM(es_analizada))             AS sla1_pct_dentro_5s,
  APPROX_QUANTILES(IF(es_analizada = 1, latencia_cierre_seg, NULL), 100)[SAFE_OFFSET(95)]
                                                                 AS sla1_latencia_p95_seg,

  -- KPI 2 + SLA
  SUM(es_falso_positivo)                                         AS falsos_positivos,
  SAFE_DIVIDE(SUM(es_falso_positivo), SUM(es_bloqueada))         AS kpi2_pct_falsos_positivos,
  SAFE_DIVIDE(SUM(es_fraude_detectado), SUM(es_bloqueada))       AS sla2_precision_reglas,

  -- KPI 4 + SLA
  SAFE_DIVIDE(SUM(es_completa), COUNT(*))                        AS kpi4_pct_completitud,
  0.95                                                           AS sla4_meta_completitud,

  -- KPI 5
  SAFE_DIVIDE(SUM(es_alerta_consistente), SUM(es_preseleccionada)) AS kpi5_pct_alertas_consistentes,
  SUM(es_alerta_duplicada)                                       AS alertas_duplicadas,
  SUM(es_alerta_perdida)                                         AS alertas_perdidas,

  -- Dinero
  SUM(monto_fraude_bloqueado)                                    AS monto_fraude_bloqueado,
  SUM(monto_fraude_no_detectado)                                 AS monto_fraude_no_detectado
FROM analitica.v_tablero_transacciones;

-- v_tablero_categorias: KPI 3, ranking de categorías por tasa de fraude.
CREATE OR REPLACE VIEW analitica.v_tablero_categorias
OPTIONS (
  description = 'Tablero: KPI 3, ranking de categorías de comercio por tasa de fraude real y tasa de bloqueo.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT
  categoria,
  COUNT(*)                                                       AS transacciones,
  SUM(es_fraude_real)                                            AS fraudes_reales,
  SAFE_DIVIDE(SUM(es_fraude_real), COUNT(*))                     AS tasa_fraude,
  SUM(es_bloqueada)                                              AS bloqueadas,
  SAFE_DIVIDE(SUM(es_bloqueada), COUNT(*))                       AS tasa_bloqueo,
  SAFE_DIVIDE(SUM(es_fraude_detectado), SUM(es_fraude_real))     AS pct_fraude_detectado,
  SUM(monto)                                                     AS monto_total,
  RANK() OVER (ORDER BY SAFE_DIVIDE(SUM(es_fraude_real), COUNT(*)) DESC) AS ranking_riesgo
FROM analitica.v_tablero_transacciones
GROUP BY categoria;

-- v_tablero_reglas: una fila por regla disparada en cada transacción bloqueada.
CREATE OR REPLACE VIEW analitica.v_tablero_reglas
OPTIONS (
  description = 'Tablero: una fila por regla disparada en cada transacción bloqueada, con la etiqueta real para ver qué regla acierta más.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "analitica"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT
  f.trans_num,
  f.fecha,
  f.categoria,
  f.monto,
  regla,
  f.is_fraud_real
FROM analitica.fact_transacciones AS f,
  UNNEST(f.reglas_disparadas) AS regla
WHERE f.resultado_veredicto = 'bloqueada';