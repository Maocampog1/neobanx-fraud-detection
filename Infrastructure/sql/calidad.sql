-- ============================================================================
-- calidad.sql — reglas de calidad de datos -> analitica.dq_resultados
-- ============================================================================
--
-- QUIÉN LO EJECUTA
--   - La consulta programada "neobanx-calidad-datos", cada 15 minutos
--     (Infrastructure/calidad.tf), con la cuenta sa-analitica.
--   - A demanda: scripts/correr_calidad.sh (útil en la demo).
--
-- CÓMO FUNCIONA
--   Cada corrida evalúa las 6 reglas sobre la réplica `raw` y AGREGA una fila
--   por regla a dq_resultados (no reemplaza): así queda el histórico que
--   muestra el dashboard. resultado = 'OK' si filas_fallidas = 0.
--
-- REGLAS (Documentation/reglas_calidad_neobanx.md)
--   R1 Unicidad              trans_num no se repite
--   R2 Validez               estado pertenece a la máquina de estados
--   R3 Oportunidad           0 transacciones con más de 5 min en pendiente_analisis
--   R4 Validez               codigo_postal de exactamente 5 dígitos
--   R5 Exactitud             monto > 0
--   R6 Integridad referencial 0 veredictos sin transacción
--
-- Nota: R4 lee codigo_postal, que tiene policy tag Cuasi_identificador.
-- sa-analitica puede leerlo; una persona del equipo no. La regla publica solo
-- el conteo, nunca el dato.

-- En BigQuery las variables deben declararse al inicio del script.
DECLARE corrida STRING DEFAULT GENERATE_UUID();
DECLARE ahora TIMESTAMP DEFAULT CURRENT_TIMESTAMP();

CREATE TABLE IF NOT EXISTS analitica.dq_resultados (
  corrida_id      STRING    OPTIONS (description = 'Identificador de la corrida (las 6 reglas de una corrida lo comparten)'),
  ejecutado_at    TIMESTAMP OPTIONS (description = 'Momento de la evaluación'),
  regla           STRING    OPTIONS (description = 'Código de la regla (R1..R6)'),
  dimension       STRING    OPTIONS (description = 'Dimensión de calidad según DAMA-DMBOK'),
  tabla           STRING    OPTIONS (description = 'Tabla evaluada'),
  descripcion     STRING    OPTIONS (description = 'Qué verifica la regla'),
  filas_evaluadas INT64     OPTIONS (description = 'Filas revisadas'),
  filas_fallidas  INT64     OPTIONS (description = 'Filas que incumplen la regla'),
  resultado       STRING    OPTIONS (description = 'OK si filas_fallidas = 0, si no FALLA')
)
PARTITION BY DATE(ejecutado_at)
OPTIONS (description = 'Histórico de resultados de las reglas de calidad (calidad.sql)');

-- Etiquetas de gobierno para Dataplex Catalog. Va como ALTER porque
-- CREATE TABLE IF NOT EXISTS no toca la tabla si ya existe.
ALTER TABLE analitica.dq_resultados SET OPTIONS (
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "calidad"), ("clasificacion", "interna"), ("capa", "analitica")]
);

INSERT INTO analitica.dq_resultados
WITH reglas AS (
  SELECT
    'R1_unicidad_trans_num'      AS regla,
    'Unicidad'                   AS dimension,
    'raw.public_transacciones'   AS tabla,
    'trans_num no se repite'     AS descripcion,
    COUNT(*)                                AS filas_evaluadas,
    COUNT(*) - COUNT(DISTINCT trans_num)    AS filas_fallidas
  FROM raw.public_transacciones

  UNION ALL
  SELECT
    'R2_estado_valido',
    'Validez',
    'raw.public_transacciones',
    'estado pertenece a la máquina de estados',
    COUNT(*),
    COUNTIF(estado IS NULL OR estado NOT IN (
      'recibida', 'sin_analizar', 'pendiente_analisis',
      'aprobada', 'bloqueada', 'no_preseleccionada_timeout'
    ))
  FROM raw.public_transacciones

  UNION ALL
  SELECT
    'R3_pendientes_vencidos',
    'Oportunidad',
    'raw.public_transacciones',
    'ninguna transacción lleva más de 5 minutos en pendiente_analisis',
    COUNTIF(estado = 'pendiente_analisis'),
    COUNTIF(estado = 'pendiente_analisis'
            AND CAST(created_at AS TIMESTAMP) < TIMESTAMP_SUB(ahora, INTERVAL 5 MINUTE))
  FROM raw.public_transacciones

  UNION ALL
  SELECT
    'R4_codigo_postal_5_digitos',
    'Validez',
    'raw.public_clientes',
    'codigo_postal tiene exactamente 5 dígitos',
    COUNT(*),
    COUNTIF(codigo_postal IS NULL
            OR NOT REGEXP_CONTAINS(CAST(codigo_postal AS STRING), r'^[0-9]{5}$'))
  FROM raw.public_clientes

  UNION ALL
  SELECT
    'R5_monto_positivo',
    'Exactitud',
    'raw.public_transacciones',
    'monto mayor que cero',
    COUNT(*),
    COUNTIF(monto IS NULL OR CAST(monto AS NUMERIC) <= 0)
  FROM raw.public_transacciones

  UNION ALL
  SELECT
    'R6_veredicto_sin_transaccion',
    'Integridad referencial',
    'raw.public_veredictos',
    'todo veredicto corresponde a una transacción existente',
    COUNT(*),
    COUNTIF(t.tn IS NULL)
  FROM raw.public_veredictos AS v
  LEFT JOIN (SELECT DISTINCT trans_num AS tn FROM raw.public_transacciones) AS t
    ON v.trans_num = t.tn
)
SELECT
  corrida,
  ahora,
  regla,
  dimension,
  tabla,
  descripcion,
  filas_evaluadas,
  filas_fallidas,
  IF(filas_fallidas = 0, 'OK', 'FALLA')
FROM reglas;

-- Vista para el dashboard: solo la última corrida (semáforo actual).
CREATE OR REPLACE VIEW analitica.dq_ultima_corrida
OPTIONS (
  description = 'Semáforo de calidad: resultado de las 6 reglas en la corrida más reciente.',
  labels = [("data_owner", "gerencia_riesgo_fraude"), ("data_steward", "maria_ocampo"),
            ("dominio", "calidad"), ("clasificacion", "interna"), ("capa", "analitica")]
)
AS
SELECT *
FROM analitica.dq_resultados
WHERE corrida_id = (
  SELECT corrida_id
  FROM analitica.dq_resultados
  ORDER BY ejecutado_at DESC
  LIMIT 1
);