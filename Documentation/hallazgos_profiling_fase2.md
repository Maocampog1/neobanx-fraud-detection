# Hallazgos del Perfilamiento de Datos — Fase 2
### Proyecto NeobanX — Equipo Sparktanos

**Fuente analizada:** `fraudTrain.csv` (dataset Sparkov, Kaggle), 1.296.675 registros, 23 campos, periodo enero 2019 – diciembre 2020 (1000 clientes, 800 comercios). Volumen total del dataset (train + test): ~1.85M registros.

**Metodología:** perfilamiento estructural, de completitud, validez, unicidad, consistencia y exactitud, más EDA de distribuciones — ejecutado sobre el 100% del archivo (ver `perfilamiento_neobanx.ipynb`).

## Hallazgos principales

- **Sin nulos ni duplicados en el histórico.** Ninguna de las 23 columnas tiene valores faltantes, y no hay duplicados exactos ni por `trans_num`. Esto no exime al pipeline de streaming de validar ambas condiciones, ya que el dato en vivo no tiene esta misma garantía.
- **`unix_time` no es un timestamp estándar.** Tiene un desfase constante de ~220.838.400 segundos (~7 años) frente al valor real calculado desde `trans_date_trans_time`. Cualquier lógica de tiempo del pipeline debe usar `trans_date_trans_time`, nunca `unix_time` directamente.
- **`zip` ya perdió los ceros iniciales en el CSV fuente** (81.782 registros con menos de 5 dígitos). Debe tratarse como texto en el modelo transaccional, igual que `cc_num`.
- **Fuerte desbalance de clases:** solo ~0.58% de las transacciones están marcadas como fraude, relevante para calibrar el umbral de las reglas de negocio del flujo de detección.
- **El campo `merchant` viene prefijado con `fraud_` en el 100% de los registros** — es una convención del generador original del dataset (Sparkov), no una fuga de información hacia `is_fraud`; debe documentarse para evitar que se use por error como variable predictiva.
- **PII de alta sensibilidad** en `cc_num`, `first`, `last`, `street`, `dob`, `job`, `gender` y la geolocalización del cliente (`lat`/`long`) — requieren enmascaramiento/tokenización con *salt* antes de exponerse fuera de la capa transaccional, en línea con la Ley 1581 de 2012.
- **Categorías y valores categóricos ya normalizados** (`category`, `gender`, `state`): sin mezclas de mayúsculas/minúsculas ni inconsistencias, señal de que el dataset fue curado antes de publicarse.

## Implicaciones para el pipeline

Estos hallazgos ya se tradujeron en (1) un diccionario de datos formal con tipo y sensibilidad por campo, y (2) un conjunto de reglas de calidad de completitud, unicidad, tipado y PII a implementar en el consumidor y en el esquema de Cloud SQL/BigQuery — ambos documentos anexos a esta entrega.
