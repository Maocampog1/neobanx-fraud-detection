# Arquitectura — NeobanX (Detección de Fraude en Streaming)

<img width="1311" height="779" alt="image" src="https://github.com/user-attachments/assets/f765937d-8d69-40b8-8116-26ce8de71ea4" />


## Leyenda de componentes

### Flujo Transaccional

| Componente | Qué hace |
|---|---|
| **Generador de transacción (Python)** | Cloud Function invocada por Cloud Scheduler cada 4 segundos; toma una transacción del dataset base y la expone como respuesta de una API. |
| **Preselección de análisis** | Cloud Function que decide si una transacción se analiza (muestreo aleatorio o si el monto supera un umbral). Si se selecciona, la envía en paralelo a "Espera veredicto" y al Pub/Sub de inicio del flujo de análisis; si no, la envía directo a Cloud SQL. |
| **Espera veredicto del flujo de detección** | Cloud Function que retiene la transacción preseleccionada a la espera del veredicto, con un timeout: si no llega a tiempo, la transacción se persiste como "no preseleccionada". |
| **Cloud SQL (PostgreSQL)** | Base de datos transaccional donde se guardan todas las transacciones, preseleccionadas o no, con su estado final. |

### Flujo Analítico y de Detección

| Componente | Qué hace |
|---|---|
| **Pub/Sub — Transacciones preseleccionadas** | Cola que recibe las transacciones seleccionadas para análisis, garantizando que no se pierdan si el flujo de detección está caído o saturado. |
| **Redis / Memorystore** | Almacén de baja latencia con el perfil histórico de cada cliente (montos promedio, ubicaciones frecuentes), consultado durante el enriquecimiento. |
| **API Nager.Date** | Servicio externo que indica si la fecha de la transacción es festivo en Colombia; se usa como una de las reglas de detección. |
| **Spark Structured Streaming (Dataproc)** | Job de streaming que consume las transacciones del Pub/Sub, las enriquece con el perfil del cliente y la bandera de festivo, y aplica las reglas de fraude. |
| **Veredicto de la transacción** | Cloud Function que formaliza el resultado del análisis (aprobada o alerta) y lo publica en dos Pub/Sub distintos: uno hacia el flujo transaccional, otro hacia analítica. |
| **Pub/Sub — Veredicto hacia flujo transaccional** | Cola que entrega el veredicto de vuelta a "Espera veredicto", para que la transacción se actualice con su estado final. |
| **Pub/Sub — Veredicto hacia analítica** | Cola que entrega el veredicto hacia BigQuery, de forma independiente al envío hacia el flujo transaccional. |
| **BigQuery** | Almacena el modelo analítico en estrella con las transacciones que sí pasaron por análisis y su resultado. |
| **Looker Studio** | Dashboard que consume las tablas de BigQuery, mostrando únicamente las transacciones preseleccionadas para análisis. |

## Flujo de una transacción

Cada 4 segundos, Cloud Scheduler dispara la función **Generador de transacción**, que toma la siguiente transacción del dataset base y la entrega a la función **Preselección de análisis**. Esta función decide si la transacción se analiza — por muestreo aleatorio o porque su monto supera un umbral definido — y a partir de ahí el flujo se bifurca. Si **no** es preseleccionada, se envía directamente a **Cloud SQL** con estado "no preseleccionada", sin pasar por el flujo de análisis. Si **sí** es preseleccionada, se envía simultáneamente a dos destinos: a la función **Espera veredicto**, que la retiene mientras llega una decisión, y al **Pub/Sub de transacciones preseleccionadas**, que marca el inicio del flujo analítico.

Del lado analítico, **Spark Structured Streaming sobre Dataproc** consume la transacción desde ese Pub/Sub, la enriquece consultando el perfil histórico del cliente en **Redis/Memorystore** y la bandera de día festivo desde **Nager.Date**, y aplica las reglas de detección de fraude. El resultado enriquecido llega a la función **Veredicto de la transacción**, que formaliza si la transacción queda aprobada o genera una alerta, y publica ese resultado en dos Pub/Sub en paralelo: uno regresa al flujo transaccional, y el otro va hacia **BigQuery** para alimentar el dashboard de **Looker Studio** (que solo muestra transacciones que pasaron por análisis).

De vuelta en el flujo transaccional, la función **Espera veredicto** recibe el veredicto desde su Pub/Sub y lo compara con la transacción que tiene retenida; si coincide, actualiza el estado con el resultado del análisis (aprobada / bloqueada) y lo persiste en **Cloud SQL**. Si el veredicto no llega dentro del tiempo límite establecido, la función deja de esperar y persiste la transacción en Cloud SQL como "no preseleccionada" — y si el veredicto llega después de ese punto, se descarta, porque esa transacción ya quedó resuelta.

---

## Estado del despliegue — Sprint 1 (Semana 5-6)

Componentes ya provisionados y probados end-to-end:

| Componente | Estado | Evidencia |
|---|---|---|
| Proyecto GCP + billing + IAM | ✅ Desplegado | Sprint 0 |
| Pub/Sub `transacciones-neobanx` | ✅ Desplegado | Sprint 0 |
| Cloud SQL `neobanx-transaccional` (PostgreSQL) | ✅ Desplegado | Sprint 0 |
| BigQuery dataset `raw` + tabla `transacciones_raw` (particionada por `trans_date_trans_time`) | ✅ Desplegado vía Terraform | Captura BigQuery Studio |
| Esquema Cloud SQL: `clientes`, `transacciones`, `alertas` | ✅ Desplegado vía Terraform (`schema.sql`) | `\dt` en psql, integridad referencial probada con FK |
| Registros de prueba en Cloud SQL | ✅ Insertados y validados con JOIN entre las 3 tablas | Consulta en psql |
| Cloud Function `consumidor` (Pub/Sub → BigQuery Raw) | ✅ Desplegada vía Terraform, probada end-to-end | Mensaje de prueba publicado desde Cloud Shell y verificado en BigQuery |
| Generador (Juanes) — `Backend/generador/` | ✅ Probado end-to-end contra el proyecto real | 268 transacciones reales publicadas (ventana 2019-02-25 22:00–00:00), 28 fraudes verificados en `raw.transacciones_raw` |
| Regla baseline de veredicto en `consumidor` | ✅ Desplegada — agrega `veredicto` (aprobada/alerta) a cada fila de BigQuery | Por monto y categoría, no es un modelo entrenado — placeholder hasta que exista el flujo de Spark |
| Frontend demo (`Frontend/`) en Cloud Run | ✅ Desplegado vía Terraform (`google_cloud_run_v2_service.frontend`), acceso público | Simula transacciones hacia Pub/Sub y muestra las últimas 20 con su veredicto desde BigQuery |

## Requisitos

| Herramienta | Versión | Para qué |
|---|---|---|
| Terraform | >= 1.7 | Desplegar toda la infraestructura (`required_version` en `main.tf`) |
| Provider `google` | ~> 6.0 | Fijado en `main.tf`, no requiere acción manual |
| gcloud CLI | cualquiera reciente | Autenticación (`gcloud auth ...`) y verificación (`gcloud pubsub`, `bq query`) |
| Python | 3.11+ | Generador, consumidor (runtime `python312` en Cloud Functions) y frontend |
| Docker | **No hace falta instalarlo localmente** | El Dockerfile de `Frontend/` se construye en Cloud Build automáticamente (`gcloud builds submit`, disparado por Terraform), no en tu máquina |

## Configuración del proyecto GCP

Variables en `Infrastructure/variables.tf`:

| Variable | Default | Requerida |
|---|---|---|
| `project_id` | `neobanx-fraud-detection` | No (ya parametrizado) |
| `region` | `us-central1` | No (ya parametrizado) |
| `db_password` | — | **Sí**, sin default — contraseña del usuario `postgres` de Cloud SQL |

## Manejo de secretos y credenciales

Nada de esto vive en el repo (verificado, sin credenciales reales commiteadas):

| Secreto | Dónde vive | Notas |
|---|---|---|
| `db_password` | `terraform.tfvars` local, gitignored | Ver documento privado del equipo |
| Credenciales de `gcloud`/ADC | `gcloud auth application-default login`, guardadas por el SDK fuera del repo | Una por cada máquina/persona |
| `GENERATOR_SALT` | Variable de entorno local, no versionada | Provisional — ver nota abajo |
| Clave HMAC para `cc_num_hash` | **Pendiente**: debe crearse en Secret Manager | Ver `Documentation/reglas_calidad_neobanx.md` — el generador aún no la usa |

## Recursos que crea este Terraform

- 5 APIs habilitadas: Cloud Functions, Cloud Build, Cloud Run, Eventarc, Artifact Registry
- Dataset + tabla de BigQuery (`raw.transacciones_raw`, particionada por fecha)
- Base de datos `neobanx` dentro de la instancia de Cloud SQL (ver excepción abajo — la instancia en sí no la crea este Terraform) + su esquema (`schema.sql`, aplicado vía `psql`)
- Bucket de Cloud Storage + objeto con el código zippeado del consumidor
- Cloud Function v2 `consumidor` (trigger de Pub/Sub)
- Repositorio de Artifact Registry + imagen Docker del frontend (build en Cloud Build) + servicio de Cloud Run `neobanx-demo` + su binding público de IAM

**No crea:** el tópico/suscripción de Pub/Sub ni la instancia de Cloud SQL en sí — ver la sección de excepciones.

## Excepciones de configuración manual

No todo pasó por Terraform. Documentado para que quede claro y sea verificable:

| Qué se hizo a mano | Por qué | Cómo verificarlo |
|---|---|---|
| La instancia de Cloud SQL `neobanx-transaccional` **no la crea este Terraform** — `main.tf` solo la referencia como `data "google_sql_database_instance"`, asumiendo que ya existe | Se creó en Sprint 0, antes de escribir el Terraform de este repo | `gcloud sql instances describe neobanx-transaccional` — existe y el `data` block la encuentra por nombre |
| Un registro de prueba en `clientes` se insertó a mano vía `psql`, no vía `schema.sql` (que solo crea tablas vacías) | Validar que el esquema y la llave foránea funcionan antes de que existiera el generador | `SELECT * FROM clientes;` desde Cloud Shell — 1 fila con `cc_num_hash = 'abc123hash'` (valor de prueba, no un hash real) |
| Encender/apagar la instancia de Cloud SQL (`gcloud sql instances patch --activation-policy`) | Ahorrar créditos cuando nadie la está usando — no es parte del ciclo de vida de Terraform | `gcloud sql instances describe neobanx-transaccional --format="value(state)"` |

## Cómo desplegar desde cero (reproducible salvo las excepciones de arriba)

```bash
cd Infrastructure
terraform init
terraform plan
terraform apply
```

Requiere el `terraform.tfvars` descrito arriba en "Configuración del proyecto GCP".

Para destruir todo y no dejar nada corriendo (ahorro de créditos):

```bash
terraform destroy
```

Esto **no** destruye la instancia de Cloud SQL en sí (no la creó este Terraform, solo la referencia) — para apagarla en vez de borrarla, ver "Excepciones de configuración manual" arriba.

### Contrato de datos del generador

El formato exacto del mensaje que debe publicar el generador de streaming a Pub/Sub está
documentado en [`Backend/contrato_datos_generador.md`](../Backend/contrato_datos_generador.md).

### Cómo comprobar que el pipeline funciona

Cada componente tiene su propia guía de prueba:

- **Generador → Pub/Sub → BigQuery**: [`Backend/README.md`](../Backend/README.md), sección
  "Generador — uso local" — incluye cómo correr una ventana corta y verificar con
  `gcloud pubsub subscriptions pull` y `bq query`.
- **Frontend**: [`Frontend/README.md`](../Frontend/README.md) — botón de simulación +
  tabla en vivo desde BigQuery.

Prueba de referencia ya ejecutada contra el proyecto real: 268 transacciones publicadas,
28 fraudes verificados en `raw.transacciones_raw` (ver tabla de estado arriba).

### Pendiente

- Prueba de carga completa end-to-end con el equipo (Semana 7): mensajes/seg y latencia
  extremo a extremo, corriendo el generador de forma sostenida.
- Job de Spark Structured Streaming sobre Dataproc (flujo analítico y de detección).
- Integración con Redis/Memorystore en el flujo de enriquecimiento de Spark. La consulta a
  Nager.Date ya está integrada y probada como módulo reutilizable (`Backend/generador/holidays.py`);
  falta conectarla al enriquecimiento del job de Spark.
- **Implementar `cc_num_hash` según `Documentation/reglas_calidad_neobanx.md`.**
  Las reglas de calidad ya especifican la técnica correcta: HMAC-SHA256 con una clave secreta fija
  guardada en Secret Manager (no un salt aleatorio por registro como usa hoy el generador de forma
  provisional). Falta: crear el secreto en Secret Manager, actualizar `hash_cc_num` en
  `Backend/generador/main.py` para usarlo, y cargar `clientes.cc_num_hash` con la misma clave (hoy
  solo tiene un valor de prueba, `abc123hash`, no un hash real) — si no, los joins entre `clientes`
  y `transacciones` no van a coincidir.
- **Revisar el acceso público del frontend demo.** `google_cloud_run_v2_service_iam_member.frontend_public`
  lo deja abierto a `allUsers` — está bien para un demo de sprint, pero vale la pena decidir como
  equipo si se restringe antes de la sustentación final.
