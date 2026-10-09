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
-- TIPOS
--   Los CAST a DATE/TIMESTAMP son a propósito: hacen que el script funcione
--   igual si Datastream replica una columna como DATETIME o como TIMESTAMP.

-- ---------------------------------------------------------------------------
-- dim_estado: los 6 estados de la máquina de estados de `transacciones`
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE analitica.dim_estado AS
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
CREATE OR REPLACE TABLE analitica.dim_tiempo AS
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
CREATE OR REPLACE TABLE analitica.dim_cliente AS
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
CREATE OR REPLACE TABLE analitica.clientes_enmascarados AS
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
CREATE OR REPLACE TABLE analitica.dim_comercio AS
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
OPTIONS (description = 'Recorrido de cada transacción: registro, veredicto, cierre, réplica CDC y modelo analítico')
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