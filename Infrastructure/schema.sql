CREATE TABLE IF NOT EXISTS clientes (
    cc_num_hash          TEXT PRIMARY KEY,
    nombre_enmascarado    TEXT,
    apellido_enmascarado   TEXT,
    genero                  CHAR(1),
    ciudad                    TEXT,
    estado                     TEXT,
    codigo_postal                TEXT,
    poblacion_ciudad               INTEGER,
    ocupacion                        TEXT,
    fecha_nacimiento                    DATE,
    lat_hogar                             NUMERIC(9,6),
    long_hogar                             NUMERIC(9,6)
);

CREATE TABLE IF NOT EXISTS transacciones (
    trans_num            TEXT PRIMARY KEY,
    cc_num_hash            TEXT REFERENCES clientes(cc_num_hash),
    comercio                 TEXT,
    categoria                  TEXT,
    monto                        NUMERIC(10,2),
    fecha_hora_transaccion         TIMESTAMP,
    lat_comercio                     NUMERIC(9,6),
    long_comercio                      NUMERIC(9,6),
    preseleccionada                      BOOLEAN DEFAULT FALSE,
    estado                                 TEXT DEFAULT 'pendiente',
    fecha_resolucion                         TIMESTAMP
);

CREATE TABLE IF NOT EXISTS alertas (
    id                  SERIAL PRIMARY KEY,
    trans_num             TEXT REFERENCES transacciones(trans_num),
    motivo                  TEXT,
    fecha_generacion          TIMESTAMP DEFAULT now(),
    resuelta                    BOOLEAN DEFAULT FALSE
);