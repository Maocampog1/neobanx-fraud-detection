# Diccionario de Datos — NeobanX (Dataset Base Sparkov)

Tabla: `raw_transacciones` (BigQuery, capa Raw) / origen: `fraudTrain.csv` + `fraudTest.csv`

| # | Campo | Tipo | PII | Notas de calidad |
|---|---|---|---|---|
| 1 | `Unnamed: 0` (índice original) | INTEGER | No | Índice de fila del CSV fuente; no usar como llave — usar `trans_num`. |
| 2 | `trans_date_trans_time` | TIMESTAMP | No | Formato único `YYYY-MM-DD HH:MM:SS`, sin valores nulos ni no parseables. Es la fuente de verdad para cualquier lógica de tiempo. |
| 3 | `cc_num` | STRING | **Sí** | Número de tarjeta. Almacenar como texto, no numérico. Requiere tokenización/hash con *salt* antes de exponerse fuera de la capa transaccional. |
| 4 | `merchant` | STRING | No | Todos los valores vienen con prefijo `fraud_` — es una convención del dataset, no señal de fraude. No usar como variable predictiva. |
| 5 | `category` | STRING (categórico) | No | 14 valores fijos observados (ej. `shopping_net`, `grocery_pos`, `gas_transport`...); ya viene normalizado. |
| 6 | `amt` | FLOAT | No | Sin negativos en el histórico; validar rango > 0 en streaming. |
| 7 | `first` | STRING | **Sí** | Nombre del cliente. |
| 8 | `last` | STRING | **Sí** | Apellido del cliente. |
| 9 | `gender` | STRING (M/F) | **Sí** | Atributo personal; tratar con el mismo cuidado que el resto de PII. |
| 10 | `street` | STRING | **Sí** | Dirección del cliente. |
| 11 | `city` | STRING | Cuasi-identificador | No identifica por sí solo, pero combinado con otros campos sí. |
| 12 | `state` | STRING | No | Código de 2 letras, 51 valores (50 estados + DC). |
| 13 | `zip` | STRING | Cuasi-identificador | **Almacenado como entero en el CSV fuente — ya perdió ceros iniciales.** Debe tratarse como texto de aquí en adelante en todo el pipeline. |
| 14 | `lat` | FLOAT | **Sí** | Latitud del domicilio del cliente. Rango válido [-90, 90] verificado. |
| 15 | `long` | FLOAT | **Sí** | Longitud del domicilio del cliente. Rango válido [-180, 180] verificado. |
| 16 | `city_pop` | INTEGER | No | Población de la ciudad; sin valores ≤ 0 en el histórico. |
| 17 | `job` | STRING | **Sí** | Ocupación del cliente; cuasi-identificador sensible combinado con otros campos. |
| 18 | `dob` | DATE | **Sí** | Fecha de nacimiento. Formato único `YYYY-MM-DD`, sin valores no parseables. |
| 19 | `trans_num` | STRING | No (identificador operativo) | Llave natural de la transacción. Sin duplicados en el histórico — es la llave de deduplicación aguas abajo (usada por el consumidor de Larry). |
| 20 | `unix_time` | INTEGER | No | **No es epoch estándar** — desfase constante de ~220.838.400 s (~7 años) frente al real. No usar para lógica de tiempo; conservar solo como campo de referencia del dataset original. |
| 21 | `merch_lat` | FLOAT | No | Latitud del comercio (no del cliente) — no es PII de persona natural. |
| 22 | `merch_long` | FLOAT | No | Longitud del comercio — no es PII de persona natural. |
| 23 | `is_fraud` | INTEGER (0/1) | No | Etiqueta de fraude. Fuerte desbalance de clases: ~0.58% de las transacciones son fraude. |

## Metadata de ingesta (agregada por el consumidor, no viene del dataset)

| Campo | Tipo | Descripción |
|---|---|---|
| `_ingested_at` | TIMESTAMP | Momento en que el consumidor cargó el registro a BigQuery Raw. |
| `_source` | STRING | `sparkov_historico` (carga batch inicial) o `streaming` (vía generador/Pub/Sub), para distinguir el origen del registro. |
| `_pubsub_message_id` | STRING | ID del mensaje de Pub/Sub, útil para trazabilidad y para detectar reentregas duplicadas. |

**Fuente:** hallazgos trasladados de la sección 9 (`perfilamiento_neobanx.ipynb`) — ver notebook completo para el detalle de cada verificación.
