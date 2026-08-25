# Reglas de Calidad de Datos — NeobanX

Reglas formales a implementar en el pipeline (consumidor / carga a BigQuery Raw y Cloud SQL), derivadas del perfilamiento inicial sobre `fraudTrain.csv`.

## 1. Completitud

- Campos obligatorios (NOT NULL) en toda la cadena: `trans_num`, `trans_date_trans_time`, `cc_num`, `amt`, `category`, `is_fraud` (cuando aplique).
- El histórico base no tiene nulos, pero el streaming en vivo sí puede tenerlos (fallos de red, timeouts, payloads truncados) — el consumidor debe rechazar o poner en cuarentena (dead-letter) cualquier mensaje que no cumpla completitud mínima, no descartarlo silenciosamente.

## 2. Unicidad

- `trans_num` es la llave de deduplicación. El consumidor debe validar que no exista ya en BigQuery Raw / Cloud SQL antes de insertar (o usar `MERGE`/`INSERT ... ON CONFLICT DO NOTHING` en Cloud SQL).
- Un mismo `trans_num` puede llegar duplicado por reintentos del generador o redistribución de partición en Pub/Sub — esto es esperado, no un error del generador.

## 3. Tipos y formato

- `zip` y `cc_num`: **STRING**, nunca numérico — de lo contrario se pierden ceros iniciales y se dificulta el enmascaramiento.
- `trans_date_trans_time`: TIMESTAMP parseado explícitamente con formato `YYYY-MM-DD HH:MM:SS`.
- `unix_time`: se conserva tal cual viene (INTEGER), pero **no se usa para ordenar ni calcular tiempos** — tiene un desfase constante de ~7 años frente al real. Cualquier lógica de tiempo (orden de eventos, ventaneo) debe usar `trans_date_trans_time`.
- `dob`: DATE parseado con formato `YYYY-MM-DD`.

## 4. Rango y exactitud

- `amt` > 0.
- `lat`, `merch_lat` ∈ [-90, 90]; `long`, `merch_long` ∈ [-180, 180].
- `is_fraud` ∈ {0, 1}.
- `city_pop` > 0.

## 5. Consistencia

- `category`: debe pertenecer al conjunto cerrado de 14 valores observados en el histórico (rechazar/marcar cualquier valor fuera de ese conjunto como posible error de esquema).
- `gender`: debe ser `M` o `F`.
- `merchant`: se espera el prefijo `fraud_` en el 100% de los registros — esto es una convención del dataset original, **no** un indicador de fraude; debe documentarse para que nadie lo use como variable predictiva.

## 6. Sensibilidad (PII)

- Campos de alta sensibilidad — `cc_num`, `first`, `last`, `street`, `dob`, `job`, `gender`, `lat`/`long` del cliente — requieren enmascaramiento o tokenización antes de exponerse fuera de la capa transaccional restringida (Cloud SQL con acceso controlado).
- Un hash sin protección (ej. SHA-256 directo sobre `cc_num`, sin clave) **no** se considera anonimización real — es reversible por diccionario.
- **Caso particular de `cc_num_hash`:** al usarse como llave de unión entre `clientes` y `transacciones` (`REFERENCES clientes(cc_num_hash)`), el hash debe ser **determinístico** — la misma tarjeta siempre produce el mismo hash — para que el join funcione. Esto descarta un *salt* aleatorio por registro; la técnica correcta es **HMAC-SHA256 con una clave secreta fija** guardada en Secret Manager (no en el código ni en el repo): mismo `cc_num` → mismo hash siempre, pero irreversible sin la clave. Para PII que no se usa como llave de unión (`first`, `last`, `street`), sí se puede usar salt aleatorio sin este problema.
- `zip` y `city` se tratan como cuasi-identificadores: no requieren enmascaramiento individual, pero no deben combinarse libremente con otros cuasi-identificadores en vistas públicas o el dashboard.
