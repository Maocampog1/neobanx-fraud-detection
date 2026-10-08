-- ============================================================================
-- NeobanX — Esquema transaccional v2 (Sprint 2)
-- Cloud SQL para PostgreSQL · base de datos: neobanx
-- ============================================================================
--
-- QUÉ MODELA ESTE ESQUEMA
--
-- El flujo transaccional de la arquitectura: TODAS las transacciones pasan por
-- aquí y su estado vive en esta base. Una transacción entra como 'recibida',
-- el servicio de registro decide si se preselecciona para análisis, y termina
-- en un estado terminal. El servicio de cierre aplica el veredicto que llega
-- desde el job de Flink (por Pub/Sub) con un UPDATE condicional, o la cierra
-- por timeout si el veredicto no llega a tiempo.
--
-- Máquina de estados:
--
--   recibida ──┬──> sin_analizar                        (no preseleccionada)
--              └──> pendiente_analisis ──┬──> aprobada
--                                        ├──> bloqueada
--                                        └──> no_preseleccionada_timeout
--
--   Terminales: sin_analizar, aprobada, bloqueada, no_preseleccionada_timeout
--
-- Gana el primero que llegue (veredicto o timeout): ambos cierran con
-- `WHERE estado = 'pendiente_analisis'`, así que el segundo no encuentra fila
-- que actualizar. Los veredictos que llegan tarde se registran con
-- `tardio = true` pero NO cambian el estado.
--
-- ----------------------------------------------------------------------------
-- POR QUÉ ESTE ARCHIVO EMPIEZA CON DROP
--
-- El esquema v1 usaba `CREATE TABLE IF NOT EXISTS`. Como las tablas ya existían
-- en la instancia, Postgres saltaba la creación SIN ERROR y las definiciones
-- nuevas se ignoraban en silencio: Terraform reportaba éxito y la base seguía
-- con el esquema viejo. Para que un cambio de esquema sea efectivo de verdad,
-- aquí se borra y se recrea. Es seguro porque esta base solo contiene datos
-- sintéticos del dataset Sparkov, reproducibles desde el repo.
--
-- ----------------------------------------------------------------------------
-- CÓMO SE APLICA
--
-- Las contraseñas de los roles NO están en este archivo (ni en git). Se pasan
-- como variables de psql desde el provisioner de Terraform, que las lee de
-- Secret Manager:
--
--   psql -h 127.0.0.1 -U postgres -d neobanx \
--     -v pwd_app_registro="..."   -v pwd_app_cierre="..." \
--     -v pwd_datastream="..."     -v pwd_agente_ro="..." \
--     -v pwd_frontend_ro="..." \
--     -f schema.sql
--
-- La conexión va por el Cloud SQL Auth Proxy (127.0.0.1), no por IP pública:
-- la instancia ya no autoriza 0.0.0.0/0.
-- ============================================================================

\set ON_ERROR_STOP on

-- --- Guarda: fallar temprano y claro si falta alguna contraseña -------------
-- `\if :{?var}` comprueba si la variable está definida. Si falta, se lanza una
-- excepción en lugar de usar `\quit`: `\quit` sale con código 0 y Terraform lo
-- interpretaría como éxito. Con ON_ERROR_STOP, la excepción hace que psql
-- termine con código distinto de cero y el apply falle de forma visible.

\if :{?pwd_app_registro}
\else
DO $guard$ BEGIN RAISE EXCEPTION 'Falta la variable pwd_app_registro (pasarla con -v)'; END $guard$;
\endif

\if :{?pwd_app_cierre}
\else
DO $guard$ BEGIN RAISE EXCEPTION 'Falta la variable pwd_app_cierre (pasarla con -v)'; END $guard$;
\endif

\if :{?pwd_datastream}
\else
DO $guard$ BEGIN RAISE EXCEPTION 'Falta la variable pwd_datastream (pasarla con -v)'; END $guard$;
\endif

\if :{?pwd_agente_ro}
\else
DO $guard$ BEGIN RAISE EXCEPTION 'Falta la variable pwd_agente_ro (pasarla con -v)'; END $guard$;
\endif

\if :{?pwd_frontend_ro}
\else
DO $guard$ BEGIN RAISE EXCEPTION 'Falta la variable pwd_frontend_ro (pasarla con -v)'; END $guard$;
\endif


BEGIN;

-- ============================================================================
-- 1. LIMPIEZA
-- ============================================================================
-- Orden inverso a las dependencias. La publicación de Datastream se borra
-- primero porque referencia las tablas. El slot de replicación NO se toca
-- aquí (ver sección 9): borrarlo mientras Datastream está conectado falla.

DROP PUBLICATION IF EXISTS neobanx_datastream_pub;

DROP VIEW IF EXISTS linaje_transaccion;
DROP VIEW IF EXISTS alertas;
DROP VIEW IF EXISTS v_historial_cliente;

DROP TABLE IF EXISTS historial_estados CASCADE;
DROP TABLE IF EXISTS veredictos        CASCADE;
DROP TABLE IF EXISTS transacciones     CASCADE;
DROP TABLE IF EXISTS cuentas           CASCADE;
DROP TABLE IF EXISTS clientes          CASCADE;

DROP FUNCTION IF EXISTS fn_registrar_cambio_estado() CASCADE;


-- ============================================================================
-- 2. ROLES DE APLICACIÓN
-- ============================================================================
-- Un rol por componente, con el mínimo privilegio que necesita (los GRANT van
-- en la sección 8). Se crean solo si no existen: DROP ROLE falla si el rol
-- posee objetos, y además sobreviven al DROP TABLE de arriba.
--
--   app_registro    servicio de registro y preselección (Cloud Run)
--   app_cierre      servicio de cierre: veredictos + monitor de timeouts
--   datastream_user replicación CDC hacia BigQuery
--   agente_ro       agente de investigación de alertas (solo lectura, sin PII)
--   frontend_ro     frontend de demo (solo lectura)

DO $$
DECLARE
  r TEXT;
BEGIN
  FOREACH r IN ARRAY ARRAY['app_registro','app_cierre','datastream_user','agente_ro','frontend_ro']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I LOGIN', r);
    END IF;
  END LOOP;
END
$$;

ALTER ROLE app_registro    WITH PASSWORD :'pwd_app_registro';
ALTER ROLE app_cierre      WITH PASSWORD :'pwd_app_cierre';
ALTER ROLE datastream_user WITH PASSWORD :'pwd_datastream';
ALTER ROLE agente_ro       WITH PASSWORD :'pwd_agente_ro';
ALTER ROLE frontend_ro     WITH PASSWORD :'pwd_frontend_ro';

-- Datastream necesita leer el WAL por replicación lógica.
ALTER ROLE datastream_user WITH REPLICATION;


-- ============================================================================
-- 3. CLIENTES Y CUENTAS
-- ============================================================================
-- El dataset Sparkov trae identidad y tarjeta en el mismo registro. Aquí se
-- separan: una persona (clientes) puede tener varias tarjetas (cuentas).
--
-- PII: el nombre y el apellido se guardan ya enmascarados por el proceso de
-- carga; `street` del dataset NO se persiste (se descartó por sensibilidad,
-- ver Documentation/reglas_calidad_neobanx.md). El número de tarjeta nunca
-- entra en texto plano: solo su HMAC-SHA256 (clave en Secret Manager).

CREATE TABLE clientes (
    cliente_id              BIGSERIAL    PRIMARY KEY,

    -- Llave natural tokenizada: HMAC-SHA256 de (nombre|apellido|fecha_nacimiento)
    -- del dataset, con la misma clave de Secret Manager que usa cc_num_hash.
    --
    -- Para qué sirve: identifica a una persona de forma estable SIN guardar su
    -- identidad real. Permite que la carga de datos maestros sea idempotente
    -- (`ON CONFLICT (cliente_hash) DO NOTHING`), que es necesario porque el
    -- equipo destruye y recrea el entorno en cada sesión de trabajo y la carga
    -- vuelve a correr cada vez.
    --
    -- No se puede usar el nombre enmascarado como llave natural: "J***" y
    -- "D***" colisionarían entre personas distintas.
    cliente_hash            TEXT         NOT NULL UNIQUE,

    nombre_enmascarado      TEXT         NOT NULL,
    apellido_enmascarado    TEXT         NOT NULL,
    genero                  CHAR(1)      CHECK (genero IS NULL OR genero IN ('M','F')),
    ciudad                  TEXT,
    estado_geo              TEXT,
    codigo_postal           TEXT,
    poblacion_ciudad        INTEGER      CHECK (poblacion_ciudad IS NULL OR poblacion_ciudad >= 0),
    ocupacion               TEXT,
    fecha_nacimiento        DATE,
    lat_hogar               NUMERIC(9,6) CHECK (lat_hogar  IS NULL OR lat_hogar  BETWEEN  -90 AND  90),
    long_hogar              NUMERIC(9,6) CHECK (long_hogar IS NULL OR long_hogar BETWEEN -180 AND 180),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  clientes IS 'Perfil del titular. PII enmascarada en la carga; street del dataset no se persiste.';
COMMENT ON COLUMN clientes.estado_geo IS 'Estado/departamento de residencia. Se llama estado_geo para no confundirlo con el estado de una transaccion.';

CREATE TABLE cuentas (
    cc_num_hash   TEXT        PRIMARY KEY,
    cliente_id    BIGINT      NOT NULL REFERENCES clientes(cliente_id) ON DELETE RESTRICT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  cuentas IS 'Tarjetas. La PK es el HMAC-SHA256 del cc_num, nunca el numero real.';
COMMENT ON COLUMN cuentas.cc_num_hash IS 'HMAC-SHA256 completo (sin truncar) con clave fija de Secret Manager.';

CREATE INDEX idx_cuentas_cliente ON cuentas (cliente_id);


-- ============================================================================
-- 4. TRANSACCIONES
-- ============================================================================
-- Tabla central del flujo. Cada fila es una transacción con su estado actual.

CREATE TABLE transacciones (
    trans_num               TEXT         PRIMARY KEY,
    cc_num_hash             TEXT         NOT NULL REFERENCES cuentas(cc_num_hash) ON DELETE RESTRICT,

    comercio                TEXT         NOT NULL,
    categoria               TEXT         NOT NULL,
    monto                   NUMERIC(10,2) NOT NULL CHECK (monto > 0),
    fecha_hora_transaccion  TIMESTAMPTZ  NOT NULL,
    lat_comercio            NUMERIC(9,6) CHECK (lat_comercio  IS NULL OR lat_comercio  BETWEEN  -90 AND  90),
    long_comercio           NUMERIC(9,6) CHECK (long_comercio IS NULL OR long_comercio BETWEEN -180 AND 180),

    -- Máquina de estados
    estado                  TEXT         NOT NULL DEFAULT 'recibida'
                                         CHECK (estado IN (
                                             'recibida',
                                             'sin_analizar',
                                             'pendiente_analisis',
                                             'aprobada',
                                             'bloqueada',
                                             'no_preseleccionada_timeout'
                                         )),
    motivo_preseleccion     TEXT         CHECK (motivo_preseleccion IS NULL OR motivo_preseleccion IN (
                                             'muestreo_aleatorio',
                                             'umbral_monto',
                                             'no_preseleccionada'
                                         )),

    -- Momentos del ciclo de vida
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deadline_at             TIMESTAMPTZ,
    finalizada_at           TIMESTAMPTZ,

    -- Etiqueta real del dataset Sparkov. SOLO para medir precisión y falsos
    -- positivos de las reglas (ver KPIs en el README). NUNCA es entrada de una
    -- regla de detección: sería fuga de información.
    is_fraud_real           SMALLINT     CHECK (is_fraud_real IS NULL OR is_fraud_real IN (0,1)),

    -- Coherencia de la máquina de estados:
    -- las preseleccionadas deben tener deadline; los estados terminales,
    -- momento de cierre.
    CONSTRAINT chk_deadline_si_pendiente CHECK (
        (estado = 'pendiente_analisis' AND deadline_at IS NOT NULL)
        OR estado <> 'pendiente_analisis'
    ),
    CONSTRAINT chk_finalizada_si_terminal CHECK (
        (estado IN ('sin_analizar','aprobada','bloqueada','no_preseleccionada_timeout')
         AND finalizada_at IS NOT NULL)
        OR estado IN ('recibida','pendiente_analisis')
    )
);

COMMENT ON TABLE  transacciones IS 'Todas las transacciones, preseleccionadas o no, con su estado terminal.';
COMMENT ON COLUMN transacciones.deadline_at   IS 'Limite para recibir veredicto. Si vence, el monitor cierra como no_preseleccionada_timeout.';
COMMENT ON COLUMN transacciones.is_fraud_real IS 'Etiqueta del dataset. Solo evaluacion de calidad del modelo; jamas entrada de las reglas.';

-- Índice parcial: el monitor de timeouts busca solo pendientes vencidas.
-- Al ser parcial se mantiene pequeño aunque la tabla crezca.
CREATE INDEX idx_tx_pendientes_deadline
    ON transacciones (deadline_at)
    WHERE estado = 'pendiente_analisis';

CREATE INDEX idx_tx_cuenta_fecha ON transacciones (cc_num_hash, fecha_hora_transaccion DESC);
CREATE INDEX idx_tx_estado       ON transacciones (estado);


-- ============================================================================
-- 5. VEREDICTOS
-- ============================================================================
-- Resultado del job de Flink. Se guarda siempre, incluso si llegó tarde: así
-- queda evidencia para calibrar el timeout.

CREATE TABLE veredictos (
    veredicto_id      BIGSERIAL    PRIMARY KEY,
    trans_num         TEXT         NOT NULL REFERENCES transacciones(trans_num) ON DELETE CASCADE,
    resultado         TEXT         NOT NULL CHECK (resultado IN ('aprobada','bloqueada')),
    reglas_disparadas JSONB        NOT NULL DEFAULT '[]'::jsonb,
    version_reglas    TEXT         NOT NULL,
    evaluado_at       TIMESTAMPTZ  NOT NULL,
    recibido_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    tardio            BOOLEAN      NOT NULL DEFAULT FALSE,

    -- Un veredicto efectivo por transacción. Los tardíos no compiten porque
    -- el índice único de abajo solo cubre los no tardíos.
    CONSTRAINT chk_reglas_es_array CHECK (jsonb_typeof(reglas_disparadas) = 'array')
);

COMMENT ON TABLE  veredictos IS 'Veredictos emitidos por el job de Flink. Los tardios se registran con tardio = true y no cambian el estado.';
COMMENT ON COLUMN veredictos.reglas_disparadas IS 'Array JSON de reglas que se activaron, ej: [{"regla":"monto_vs_promedio","valor":12.4}].';

CREATE UNIQUE INDEX idx_veredicto_efectivo_unico
    ON veredictos (trans_num)
    WHERE tardio = FALSE;

CREATE INDEX idx_veredictos_trans ON veredictos (trans_num);
CREATE INDEX idx_veredictos_reglas ON veredictos USING GIN (reglas_disparadas);


-- ============================================================================
-- 6. HISTORIAL DE ESTADOS (trazabilidad para linaje)
-- ============================================================================
-- Lo llena un trigger, no la aplicación: así ningún componente puede cambiar
-- un estado sin dejar rastro.

CREATE TABLE historial_estados (
    historial_id    BIGSERIAL    PRIMARY KEY,
    trans_num       TEXT         NOT NULL REFERENCES transacciones(trans_num) ON DELETE CASCADE,
    estado_anterior TEXT,
    estado_nuevo    TEXT         NOT NULL,
    cambiado_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE historial_estados IS 'Bitacora append-only de cambios de estado. La escribe un trigger, no la aplicacion.';

CREATE INDEX idx_historial_trans ON historial_estados (trans_num, cambiado_at);

CREATE FUNCTION fn_registrar_cambio_estado()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO historial_estados (trans_num, estado_anterior, estado_nuevo)
        VALUES (NEW.trans_num, NULL, NEW.estado);
    ELSIF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO historial_estados (trans_num, estado_anterior, estado_nuevo)
        VALUES (NEW.trans_num, OLD.estado, NEW.estado);
    END IF;
    RETURN NULL;  -- AFTER trigger: el valor de retorno se ignora
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_historial_estados
    AFTER INSERT OR UPDATE OF estado ON transacciones
    FOR EACH ROW
    EXECUTE FUNCTION fn_registrar_cambio_estado();


-- ============================================================================
-- 7. VISTAS
-- ============================================================================

-- 7.1 `alertas` — reemplaza la tabla del v1. Ya no es una tabla propia porque
-- una alerta no es más que una transacción bloqueada con su veredicto: tenerla
-- duplicada abría la puerta a que ambas se desincronizaran.
CREATE VIEW alertas AS
SELECT
    t.trans_num,
    t.cc_num_hash,
    t.comercio,
    t.categoria,
    t.monto,
    t.fecha_hora_transaccion,
    t.finalizada_at        AS bloqueada_at,
    v.reglas_disparadas,
    v.version_reglas,
    v.evaluado_at
FROM transacciones t
JOIN veredictos v
  ON v.trans_num = t.trans_num
 AND v.tardio = FALSE
WHERE t.estado = 'bloqueada';

COMMENT ON VIEW alertas IS 'Transacciones bloqueadas con el detalle de las reglas que las bloquearon.';


-- 7.2 `linaje_transaccion` — una fila por transacción con todo su recorrido:
-- etapas, momentos, veredicto y reglas. Es la base del linaje que se expone en
-- BigQuery y la fuente principal del agente de investigación.
CREATE VIEW linaje_transaccion AS
SELECT
    t.trans_num,
    t.cc_num_hash,
    t.estado                AS estado_actual,
    t.motivo_preseleccion,

    t.created_at            AS momento_recepcion,
    t.deadline_at           AS momento_limite,
    t.finalizada_at         AS momento_cierre,
    EXTRACT(EPOCH FROM (t.finalizada_at - t.created_at)) AS latencia_cierre_seg,

    v.resultado             AS veredicto,
    v.reglas_disparadas,
    v.version_reglas,
    v.evaluado_at           AS momento_evaluacion,
    EXTRACT(EPOCH FROM (v.recibido_at - v.evaluado_at)) AS latencia_transporte_seg,

    t.is_fraud_real,

    (SELECT jsonb_agg(
                jsonb_build_object('estado', h.estado_nuevo, 'momento', h.cambiado_at)
                ORDER BY h.cambiado_at)
       FROM historial_estados h
      WHERE h.trans_num = t.trans_num) AS trazabilidad_estados,

    (SELECT count(*) FROM veredictos vt
      WHERE vt.trans_num = t.trans_num AND vt.tardio) AS veredictos_tardios
FROM transacciones t
LEFT JOIN veredictos v
       ON v.trans_num = t.trans_num
      AND v.tardio = FALSE;

COMMENT ON VIEW linaje_transaccion IS 'Linaje por trans_num: etapas, momentos, latencias, veredicto y reglas disparadas.';


-- 7.3 `v_historial_cliente` — superficie de lectura del agente de IA.
-- Expone el comportamiento del cliente SIN PII: no incluye nombre, apellido,
-- fecha de nacimiento, coordenadas del hogar ni código postal.
CREATE VIEW v_historial_cliente AS
SELECT
    cu.cc_num_hash,
    cl.ciudad,
    cl.estado_geo,
    cl.ocupacion,
    date_part('year', CURRENT_DATE) - date_part('year', cl.fecha_nacimiento) AS edad_aprox,
    count(t.trans_num)                                     AS total_transacciones,
    count(*) FILTER (WHERE t.estado = 'bloqueada')          AS total_bloqueadas,
    count(*) FILTER (WHERE t.estado = 'aprobada')           AS total_aprobadas,
    round(avg(t.monto), 2)                                  AS monto_promedio,
    round(stddev_pop(t.monto), 2)                           AS monto_desviacion,
    max(t.monto)                                            AS monto_maximo,
    min(t.fecha_hora_transaccion)                           AS primera_transaccion,
    max(t.fecha_hora_transaccion)                           AS ultima_transaccion,
    mode() WITHIN GROUP (ORDER BY t.categoria)              AS categoria_frecuente
FROM cuentas cu
JOIN clientes cl ON cl.cliente_id = cu.cliente_id
LEFT JOIN transacciones t ON t.cc_num_hash = cu.cc_num_hash
GROUP BY cu.cc_num_hash, cl.ciudad, cl.estado_geo, cl.ocupacion, cl.fecha_nacimiento;

COMMENT ON VIEW v_historial_cliente IS 'Comportamiento agregado por cuenta, sin PII. Superficie de lectura del agente de investigacion.';


-- ============================================================================
-- 8. PRIVILEGIOS (mínimo por componente)
-- ============================================================================
-- Los GRANT van después de crear las tablas porque el DROP de la sección 1 se
-- lleva los privilegios anteriores.

-- Nadie crea objetos nuevos en public por defecto.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

GRANT USAGE ON SCHEMA public TO app_registro, app_cierre, datastream_user, agente_ro, frontend_ro;

-- 8.1 Registro y preselección: inserta la transacción y fija su estado inicial.
GRANT SELECT, INSERT, UPDATE ON transacciones TO app_registro;
GRANT SELECT                 ON cuentas, clientes TO app_registro;

-- 8.2 Cierre: cambia estados y registra veredictos.
GRANT SELECT, UPDATE         ON transacciones TO app_cierre;
GRANT SELECT, INSERT         ON veredictos    TO app_cierre;
GRANT USAGE, SELECT          ON SEQUENCE veredictos_veredicto_id_seq TO app_cierre;
GRANT SELECT                 ON historial_estados TO app_cierre;

-- 8.3 Datastream: solo lectura de las 5 tablas que replica a BigQuery.
GRANT SELECT ON clientes, cuentas, transacciones, veredictos, historial_estados
    TO datastream_user;

-- 8.4 Agente de IA: solo lectura, y solo vistas sin PII. No ve tablas base.
GRANT SELECT ON v_historial_cliente, linaje_transaccion, alertas TO agente_ro;

-- 8.5 Frontend de demo: solo lectura del estado en vivo.
GRANT SELECT ON transacciones, linaje_transaccion, alertas TO frontend_ro;

-- El trigger escribe en historial_estados con los privilegios del dueño de la
-- función (postgres), así que app_registro/app_cierre no necesitan INSERT ahí.
-- `SET search_path` es obligatorio en funciones SECURITY DEFINER: sin él, un
-- rol podría crear objetos en un esquema propio y secuestrar la resolución de
-- nombres para ejecutar código con privilegios de postgres.
ALTER FUNCTION fn_registrar_cambio_estado() OWNER TO postgres;
ALTER FUNCTION fn_registrar_cambio_estado() SECURITY DEFINER;
ALTER FUNCTION fn_registrar_cambio_estado() SET search_path = public, pg_temp;


-- ============================================================================
-- 9. REPLICACIÓN LÓGICA PARA DATASTREAM
-- ============================================================================
-- Requiere el flag `cloudsql.logical_decoding = on` en la instancia (se declara
-- en Terraform). La publicación lista las tablas que se replican a BigQuery.

CREATE PUBLICATION neobanx_datastream_pub
    FOR TABLE clientes, cuentas, transacciones, veredictos, historial_estados;

COMMIT;

-- NOTA — el slot de replicación NO se crea aquí.
--
-- `pg_create_logical_replication_slot` exige el atributo REPLICATION, y en
-- Cloud SQL el usuario `postgres` tiene el rol `cloudsqlsuperuser` pero NO ese
-- atributo. Intentarlo desde aquí falla con:
--
--     ERROR: must be superuser or replication role to use replication slots
--
-- El slot lo crea `aplicar_schema.sh` en un segundo paso, conectándose como
-- `datastream_user`, que sí recibió REPLICATION en la sección 2. La publicación
-- de arriba sí la puede crear `postgres`, así que esa se queda aquí.


-- ============================================================================
-- 10. VERIFICACIÓN
-- ============================================================================

SELECT 'Tablas creadas: ' || string_agg(tablename, ', ' ORDER BY tablename) AS resumen
FROM pg_tables
WHERE schemaname = 'public';

SELECT 'Vistas creadas: ' || string_agg(viewname, ', ' ORDER BY viewname) AS resumen
FROM pg_views
WHERE schemaname = 'public';

SELECT 'Roles: ' || string_agg(rolname, ', ' ORDER BY rolname) AS resumen
FROM pg_roles
WHERE rolname IN ('app_registro','app_cierre','datastream_user','agente_ro','frontend_ro');
