# Diccionario de datos v2 — NeobanX

**Proyecto:** NeobanX, plataforma de detección de fraude en tiempo real (SI4002, EAFIT)
**Equipo:** Sparktanos (Juan Esteban Alzate, Camilo Salazar, María Alejandra Ocampo)
**Versión:** 2.0 (Sprint 2), octubre de 2026
**Reemplaza a:** `Diccionario datos.md` (v1, Sprint 1)

### Qué cambia respecto a la v1

| Cambio | Detalle |
|---|---|
| Tablas nuevas | `raw.public_veredictos`, `raw.public_historial_estados` y toda la capa `analitica` (modelo en estrella, capa enmascarada, calidad y linaje) |
| Roles de gobierno | Cada tabla tiene **Data Owner** y **Data Steward** |
| Clasificación | Cada tabla tiene un nivel de clasificación, y cada columna con datos personales tiene su **policy tag** |
| Metadatos en la plataforma | Las descripciones y los roles no viven solo en este documento: están como descripción y etiquetas en BigQuery y se ven en Dataplex (Knowledge Catalog) |

---

## 1. Roles de gobierno

Según DAMA-DMBOK (Data Governance):

- **Data Owner:** responde por los datos ante el negocio y ante la ley. Decide quién puede acceder y para qué. Es un rol de negocio, no técnico.
- **Data Steward:** cuida los datos en el día a día: que tengan calidad, que estén documentados y que se usen según las políticas. Es la persona a la que se le pregunta por una tabla.

| Dominio | Tablas | Data Owner (rol) | Data Steward |
|---|---|---|---|
| Transaccional | `raw.public_transacciones`, `raw.public_veredictos`, `raw.public_historial_estados` | Gerencia de Riesgo y Fraude | Juan Esteban Alzate |
| Clientes y cuentas | `raw.public_clientes`, `raw.public_cuentas`, `analitica.clientes_enmascarados` | Oficial de Protección de Datos | Camilo Salazar (`raw`) / María Alejandra Ocampo (`analitica`) |
| Analítica | `analitica.fact_transacciones` y las dimensiones | Gerencia de Riesgo y Fraude | María Alejandra Ocampo |
| Calidad | `analitica.dq_resultados`, `analitica.dq_ultima_corrida` | Gerencia de Riesgo y Fraude | María Alejandra Ocampo |
| Gobierno (linaje) | `analitica.linaje_transaccion` | Gerencia de Riesgo y Fraude | María Alejandra Ocampo |
| Referencia | `analitica.festivos_us` | Gerencia de Riesgo y Fraude | María Alejandra Ocampo |

---

## 2. Clasificación de la información

### 2.1 Nivel de clasificación por tabla

| Nivel | Significado | Quién puede leerla |
|---|---|---|
| `publica` | Información pública o de referencia, sin riesgo | Cualquier usuario del proyecto |
| `interna` | Datos de operación y analítica **sin datos personales** | Equipo del proyecto |
| `confidencial` | Datos de negocio sensibles (transacciones, veredictos, tarjeta seudonimizada) | Equipo técnico y cuentas de servicio que los procesan |
| `restringida_pii` | Contiene datos personales en claro (Ley 1581 de 2012) | Solo cuentas de servicio autorizadas, por columna (ver 2.2) |
| `pii_enmascarada` | Datos personales generalizados, sin posibilidad práctica de reidentificar | Equipo del proyecto |

### 2.2 Clasificación por columna (policy tags)

Taxonomía de Data Catalog `neobanx-clasificacion-pii`, con control de acceso por columna (`FINE_GRAINED_ACCESS_CONTROL`):

| Policy tag | Qué significa | Columnas (`raw.public_clientes`) |
|---|---|---|
| `PII_alta` | Identifica directamente a una persona | `nombre_enmascarado`, `apellido_enmascarado`, `genero`, `ocupacion`, `fecha_nacimiento`, `lat_hogar`, `long_hogar` |
| `Cuasi_identificador` | No identifica sola, pero sí combinada con otros datos | `ciudad`, `codigo_postal` |

**Quién lee las columnas con policy tag:** solo `sa-analitica` (la consulta programada) y el agente de servicio de Datastream, con el rol `roles/datacatalog.categoryFineGrainedReader`. Cualquier otra cuenta, incluida la del dueño del proyecto, recibe **Access Denied** en esas columnas. Esto se comprobó el 9 de octubre de 2026.

**Enmascaramiento:** el enmascaramiento dinámico de BigQuery (`maskedReader`) exige que el proyecto pertenezca a una organización, y este proyecto es de una cuenta personal. Por eso se aplica **enmascaramiento estático por generalización** en el pipeline: `analitica.clientes_enmascarados`.

**El número de tarjeta (`cc_num`) nunca se almacena.** Solo existe `cc_num_hash` (HMAC con una clave guardada en Secret Manager).

---

## 3. Inventario de tablas

| Tabla | Capa | Tipo | Origen | Actualización | Clasificación |
|---|---|---|---|---|---|
| `raw.public_transacciones` | raw | Tabla | Datastream (CDC) desde Cloud SQL `public.transacciones` | Continua (segundos) | `confidencial` |
| `raw.public_veredictos` | raw | Tabla | Datastream desde `public.veredictos` | Continua | `confidencial` |
| `raw.public_historial_estados` | raw | Tabla | Datastream desde `public.historial_estados` | Continua | `confidencial` |
| `raw.public_clientes` | raw | Tabla | Datastream desde `public.clientes` (carga de maestros) | Continua | `restringida_pii` |
| `raw.public_cuentas` | raw | Tabla | Datastream desde `public.cuentas` (carga de maestros) | Continua | `confidencial` |
| `analitica.fact_transacciones` | analitica | Tabla (hechos) | Consulta programada `neobanx-modelo-estrella` | Cada 15 min | `interna` |
| `analitica.dim_cliente` | analitica | Tabla (dimensión) | Consulta programada | Cada 15 min | `interna` |
| `analitica.dim_comercio` | analitica | Tabla (dimensión) | Consulta programada | Cada 15 min | `interna` |
| `analitica.dim_tiempo` | analitica | Tabla (dimensión) | Consulta programada + `festivos_us` | Cada 15 min | `publica` |
| `analitica.dim_estado` | analitica | Tabla (dimensión) | Consulta programada (valores fijos) | Cada 15 min | `interna` |
| `analitica.clientes_enmascarados` | analitica | Tabla | Consulta programada | Cada 15 min | `pii_enmascarada` |
| `analitica.festivos_us` | analitica | Tabla (referencia) | API pública Nager.Date (`cargar_festivos.sh`) | En cada deploy | `publica` |
| `analitica.dq_resultados` | analitica | Tabla (histórico) | Consulta programada `neobanx-calidad-datos` | Cada 15 min (agrega filas) | `interna` |
| `analitica.dq_ultima_corrida` | analitica | Vista | Sobre `dq_resultados` | Al consultarla | `interna` |
| `analitica.linaje_transaccion` | analitica | Vista | Sobre `raw` y `fact_transacciones` | Al consultarla | `interna` |

**Nota sobre `datastream_metadata`:** todas las tablas de `raw` tienen una columna `datastream_metadata` (RECORD) que agrega Datastream con datos técnicos de la replicación (identificador del cambio y momento en el origen). No es un dato de negocio y no aparece en la capa `analitica`.

---

## 4. Capa `raw`: réplica del sistema transaccional

### 4.1 `raw.public_transacciones`

Una fila por transacción, con su estado actual en la máquina de estados.

| Columna | Tipo | Descripción | Clasificación | Regla de calidad |
|---|---|---|---|---|
| `trans_num` | STRING | Identificador único de la transacción (clave primaria) | Confidencial | R1: no se repite |
| `cc_num_hash` | STRING | Tarjeta seudonimizada (HMAC). Une con `public_cuentas` | Confidencial | |
| `comercio` | STRING | Nombre del comercio (el generador ya quita el prefijo `fraud_` del dataset) | Interna | |
| `categoria` | STRING | Categoría del comercio (`grocery_pos`, `shopping_net`, etc.) | Interna | |
| `monto` | NUMERIC | Valor de la transacción en USD | Confidencial | R5: mayor que 0 |
| `fecha_hora_transaccion` | TIMESTAMP | Fecha y hora de la compra según el dataset (2020) | Interna | |
| `lat_comercio` | NUMERIC | Latitud del comercio | Interna | |
| `long_comercio` | NUMERIC | Longitud del comercio | Interna | |
| `estado` | STRING | Estado actual: `recibida`, `sin_analizar`, `pendiente_analisis`, `aprobada`, `bloqueada` o `no_preseleccionada_timeout` | Interna | R2: valor válido |
| `motivo_preseleccion` | STRING | Por qué se envió (o no) al motor de reglas: `umbral_monto`, `muestreo`, `no_preseleccionada`… | Interna | |
| `created_at` | TIMESTAMP | Momento real en que la plataforma registró la transacción | Interna | R3: no más de 5 min en `pendiente_analisis` |
| `deadline_at` | TIMESTAMP | Plazo máximo para recibir el veredicto (`created_at` + 30 s) | Interna | |
| `finalizada_at` | TIMESTAMP | Momento en que la transacción llegó a un estado terminal | Interna | |
| `is_fraud_real` | INTEGER | Etiqueta del dataset (1 = fraude). **Solo para medir el desempeño**; ninguna regla la usa | Confidencial | |

### 4.2 `raw.public_veredictos`

Decisión del motor de reglas para cada transacción preseleccionada. Una transacción puede tener más de un veredicto (uno a tiempo y otro tardío).

| Columna | Tipo | Descripción | Clasificación | Regla de calidad |
|---|---|---|---|---|
| `veredicto_id` | INTEGER | Identificador del veredicto (clave primaria) | Interna | |
| `trans_num` | STRING | Transacción evaluada | Confidencial | R6: debe existir en `public_transacciones` |
| `resultado` | STRING | `aprobada` o `bloqueada` | Interna | |
| `reglas_disparadas` | JSON | Lista de reglas que se cumplieron (por ejemplo `["categoria_riesgo"]`) | Interna | |
| `version_reglas` | STRING | Versión del motor que decidió (`stub-v1`, o la del job de Flink) | Interna | |
| `evaluado_at` | TIMESTAMP | Momento en que el motor evaluó la transacción | Interna | |
| `recibido_at` | TIMESTAMP | Momento en que el servicio de cierre recibió el veredicto | Interna | |
| `tardio` | BOOLEAN | `true` si llegó después del plazo; en ese caso se guarda, pero no cambia el estado | Interna | |

### 4.3 `raw.public_historial_estados`

Auditoría: cada cambio de estado de una transacción.

| Columna | Tipo | Descripción | Clasificación |
|---|---|---|---|
| `historial_id` | INTEGER | Identificador del cambio (clave primaria) | Interna |
| `trans_num` | STRING | Transacción que cambió de estado | Confidencial |
| `estado_anterior` | STRING | Estado antes del cambio | Interna |
| `estado_nuevo` | STRING | Estado después del cambio | Interna |
| `cambiado_at` | TIMESTAMP | Momento del cambio | Interna |

### 4.4 `raw.public_clientes`

Datos maestros de clientes. **Es la única tabla con PII en claro.**

| Columna | Tipo | Descripción | Policy tag | Regla de calidad |
|---|---|---|---|---|
| `cliente_id` | INTEGER | Identificador del cliente (clave primaria) | | |
| `cliente_hash` | STRING | Identificador seudonimizado del cliente | | |
| `nombre_enmascarado` | STRING | Nombre del cliente (ya enmascarado en la carga) | **PII_alta** | |
| `apellido_enmascarado` | STRING | Apellido del cliente (ya enmascarado en la carga) | **PII_alta** | |
| `genero` | STRING | Género | **PII_alta** | |
| `ciudad` | STRING | Ciudad de residencia | **Cuasi_identificador** | |
| `estado_geo` | STRING | Estado de EE. UU. (dos letras) | | |
| `codigo_postal` | STRING | Código postal | **Cuasi_identificador** | R4: exactamente 5 dígitos |
| `poblacion_ciudad` | INTEGER | Población de la ciudad | | |
| `ocupacion` | STRING | Ocupación | **PII_alta** | |
| `fecha_nacimiento` | DATE | Fecha de nacimiento | **PII_alta** | |
| `lat_hogar` | NUMERIC | Latitud del hogar | **PII_alta** | |
| `long_hogar` | NUMERIC | Longitud del hogar | **PII_alta** | |
| `created_at` | TIMESTAMP | Momento de la carga | | |

### 4.5 `raw.public_cuentas`

Relación entre la tarjeta (seudonimizada) y el cliente.

| Columna | Tipo | Descripción | Clasificación |
|---|---|---|---|
| `cc_num_hash` | STRING | Tarjeta seudonimizada con HMAC (clave primaria). El número real nunca se guarda | Confidencial |
| `cliente_id` | INTEGER | Cliente dueño de la tarjeta | Interna |
| `created_at` | TIMESTAMP | Momento de la carga | Interna |

---

## 5. Capa `analitica`: modelo en estrella (Kimball)

**Grano de la tabla de hechos:** una fila por transacción. `trans_num` es una dimensión degenerada.

```
                 dim_tiempo (fecha)
                        │
dim_cliente ──── fact_transacciones ──── dim_comercio
 (cliente_id)           │                 (comercio_id)
                   dim_estado (estado)
```

### 5.1 `analitica.fact_transacciones`

Particionada por `fecha` y con clustering por `estado, categoria`.

| Columna | Tipo | Descripción | Se calcula a partir de |
|---|---|---|---|
| `trans_num` | STRING | Identificador de la transacción (dimensión degenerada) | `public_transacciones.trans_num` |
| `fecha` | DATE | Fecha de la compra. **Columna de partición** y llave hacia `dim_tiempo` | `fecha_hora_transaccion` |
| `hora` | INTEGER | Hora del día de la compra (0-23) | `fecha_hora_transaccion` |
| `cliente_id` | INTEGER | Llave hacia `dim_cliente` | `public_cuentas` vía `cc_num_hash` |
| `comercio_id` | INTEGER | Llave hacia `dim_comercio` | `FARM_FINGERPRINT(comercio)` |
| `categoria` | STRING | Categoría del comercio. **Columna de clustering** | `public_transacciones` |
| `estado` | STRING | Estado final. Llave hacia `dim_estado` y **columna de clustering** | `public_transacciones` |
| `monto` | NUMERIC | Valor en USD | `public_transacciones` |
| `preseleccionada` | BOOLEAN | Si se envió al motor de reglas | `motivo_preseleccion` |
| `motivo_preseleccion` | STRING | Por qué se preseleccionó | `public_transacciones` |
| `resultado_veredicto` | STRING | Resultado del veredicto efectivo | `public_veredictos` |
| `reglas_disparadas` | STRING (REPEATED) | Reglas que se cumplieron, como arreglo | `public_veredictos.reglas_disparadas` |
| `version_reglas` | STRING | Versión del motor que decidió | `public_veredictos` |
| `veredicto_tardio` | BOOLEAN | Si el veredicto efectivo fue tardío | `public_veredictos.tardio` |
| `latencia_cierre_seg` | FLOAT | Segundos entre el registro y el estado terminal | `finalizada_at − created_at` |
| `is_fraud_real` | INTEGER | Etiqueta del dataset, solo para medir falsos positivos y negativos | `public_transacciones` |

**Veredicto efectivo:** si una transacción tiene varios veredictos, cuenta el que llegó a tiempo y, entre iguales, el más antiguo.

### 5.2 `analitica.dim_cliente` (sin PII)

| Columna | Tipo | Descripción |
|---|---|---|
| `cliente_id` | INTEGER | Identificador del cliente |
| `estado_geo` | STRING | Estado de EE. UU. |
| `rango_edad` | STRING | `18-24`, `25-39`, `40-54`, `55-69` o `70+`, calculado contra el 31/12/2020 |
| `tipo_ciudad` | STRING | `rural (<10k)`, `mediana (10k-100k)` o `urbana (100k+)` según la población |

### 5.3 `analitica.dim_comercio`

| Columna | Tipo | Descripción |
|---|---|---|
| `comercio_id` | INTEGER | `FARM_FINGERPRINT` del nombre del comercio |
| `comercio` | STRING | Nombre del comercio sin el prefijo `fraud_` |
| `categoria_principal` | STRING | Categoría del comercio |

### 5.4 `analitica.dim_tiempo`

Un día por fila, del 1/1/2019 al 31/12/2021.

| Columna | Tipo | Descripción |
|---|---|---|
| `fecha` | DATE | Día (llave) |
| `anio` | INTEGER | Año |
| `mes` | INTEGER | Mes (1-12) |
| `dia` | INTEGER | Día del mes |
| `dia_semana_num` | INTEGER | Día de la semana (1 = domingo) |
| `dia_semana` | STRING | Nombre del día |
| `es_fin_de_semana` | BOOLEAN | Sábado o domingo |
| `es_festivo` | BOOLEAN | Festivo en EE. UU. según Nager.Date |
| `nombre_festivo` | STRING | Nombre del festivo (si hay dos el mismo día, separados por `/`) |

### 5.5 `analitica.dim_estado`

| Columna | Tipo | Descripción |
|---|---|---|
| `estado` | STRING | Uno de los 6 estados (llave) |
| `descripcion` | STRING | Qué significa el estado |
| `es_terminal` | BOOLEAN | Si es un estado final |
| `fue_analizada` | BOOLEAN | Si el motor de reglas la evaluó a tiempo |

### 5.6 `analitica.clientes_enmascarados`

Capa de PII enmascarada por generalización. Ciudad, coordenadas, género y ocupación se omiten.

| Columna | Tipo | Descripción | Técnica |
|---|---|---|---|
| `cliente_id` | INTEGER | Identificador del cliente | |
| `nombre` | STRING | Inicial del nombre + `***` (por ejemplo `O***`) | Supresión parcial |
| `apellido` | STRING | Inicial del apellido + `***` | Supresión parcial |
| `anio_nacimiento` | INTEGER | Solo el año de nacimiento | Generalización |
| `estado_geo` | STRING | Estado de EE. UU. | |
| `codigo_postal_aprox` | STRING | Primeros 3 dígitos + `XX` (por ejemplo `050XX`) | Generalización |

### 5.7 `analitica.festivos_us`

| Columna | Tipo | Descripción |
|---|---|---|
| `fecha` | DATE | Día festivo |
| `nombre` | STRING | Nombre en inglés |
| `nombre_local` | STRING | Nombre local |
| `global` | BOOLEAN | Si aplica a todo el país (`false` = solo algunos estados) |

---

## 6. Calidad de datos

### 6.1 `analitica.dq_resultados`

Histórico: cada corrida agrega una fila por regla. Particionada por fecha de `ejecutado_at`.

| Columna | Tipo | Descripción |
|---|---|---|
| `corrida_id` | STRING | Identificador de la corrida (lo comparten las 6 reglas de una corrida) |
| `ejecutado_at` | TIMESTAMP | Momento de la evaluación |
| `regla` | STRING | Código de la regla (R1..R6) |
| `dimension` | STRING | Dimensión de calidad (DAMA-DMBOK) |
| `tabla` | STRING | Tabla evaluada |
| `descripcion` | STRING | Qué verifica la regla |
| `filas_evaluadas` | INTEGER | Filas revisadas |
| `filas_fallidas` | INTEGER | Filas que incumplen |
| `resultado` | STRING | `OK` si `filas_fallidas` = 0; si no, `FALLA` |

`analitica.dq_ultima_corrida` es una vista con las mismas columnas, solo de la corrida más reciente: el semáforo actual.

### 6.2 Reglas

| Regla | Dimensión | Tabla | Qué verifica |
|---|---|---|---|
| R1 | Unicidad | `public_transacciones` | `trans_num` no se repite |
| R2 | Validez | `public_transacciones` | `estado` es uno de los 6 estados |
| R3 | Oportunidad | `public_transacciones` | Ninguna transacción lleva más de 5 min en `pendiente_analisis` |
| R4 | Validez | `public_clientes` | `codigo_postal` tiene exactamente 5 dígitos |
| R5 | Exactitud | `public_transacciones` | `monto` > 0 |
| R6 | Integridad referencial | `public_veredictos` | Todo veredicto tiene su transacción |

---

## 7. Linaje

### 7.1 Recorrido de una transacción

`analitica.linaje_transaccion` devuelve, para un `trans_num`, una fila por paso:

| Orden | Paso | Recorrido |
|---|---|---|
| 1 | `registro` | Generador → Cloud Run `registro` → Cloud SQL `transacciones` |
| 2 | `veredicto` / `veredicto_tardio` | Pub/Sub `tx-preseleccionadas` → motor de reglas → Pub/Sub `tx-veredictos` → Cloud Run `cierre` → Cloud SQL `veredictos` |
| 3 | `cierre` | Cloud Run `cierre` → Cloud SQL `transacciones` (estado terminal) |
| 4 | `replica_cdc` | Datastream → BigQuery `raw` |
| 5 | `modelo_analitico` | Consulta programada → `analitica.fact_transacciones` |

Uso:

```sql
SELECT orden, paso, momento, detalle
FROM analitica.linaje_transaccion
WHERE trans_num = '...'
ORDER BY orden;
```

### 7.2 Linaje entre tablas (Dataplex)

Con la API de Data Lineage activa, BigQuery registra automáticamente qué tablas lee y escribe cada consulta programada. El grafo se ve en BigQuery → tabla → pestaña **Linaje**:

```
raw.public_transacciones ─┐
raw.public_cuentas ───────┼──► analitica.fact_transacciones ──► analitica.linaje_transaccion
raw.public_veredictos ────┘
```

---

## 8. Metadatos en Dataplex (Knowledge Catalog)

Cada tabla lleva en BigQuery una descripción y estas etiquetas, que Dataplex muestra y permite buscar:

| Etiqueta | Valores |
|---|---|
| `data_owner` | `gerencia_riesgo_fraude`, `oficial_proteccion_datos` |
| `data_steward` | `juan_alzate`, `camilo_salazar`, `maria_ocampo` |
| `dominio` | `transaccional`, `clientes`, `analitica`, `calidad`, `gobierno`, `referencia` |
| `clasificacion` | `publica`, `interna`, `confidencial`, `restringida_pii`, `pii_enmascarada` |
| `capa` | `raw`, `analitica` |

Ejemplos de búsqueda en Dataplex:

- `label:data_steward=maria_ocampo`: todo lo que cuida María Alejandra.
- `label:clasificacion=restringida_pii`: dónde hay datos personales en claro.

**Dónde se definen (para mantenerlas):**

- Tablas de `raw` y `festivos_us`: `scripts/aplicar_catalogo.sh`, que corre `construir_analitica.sh`.
- Tablas y vistas del modelo: `OPTIONS (...)` en `Infrastructure/sql/modelo_estrella.sql`.
- Calidad: `Infrastructure/sql/calidad.sql`.
- Policy tags: `Infrastructure/gobernanza.tf` y `scripts/aplicar_policy_tags.sh`.