# Plataforma de Detección de Fraude en Tiempo Real para NeobanX

Proyecto de la trayectoria en Ingeniería de Datos — Universidad EAFIT
Asignatura: SI4002 - Proyecto de Ingeniería de Datos
Semestre: 2026-2 · **Sprint 1**

## Descripción

NeobanX es un neobanco digital ficticio (caso de estudio simulado) que actualmente detecta transacciones fraudulentas de forma tardía, después de que la operación ya se completó. Este proyecto diseña e implementa una arquitectura de datos en streaming sobre GCP capaz de ingerir, enriquecer y evaluar cada transacción en el momento en que ocurre, reduciendo tanto las pérdidas económicas como los bloqueos injustificados a clientes legítimos.

## Equipo

| Nombre | Rol |
|---|---|
| Juan Esteban Alzate | Arquitecto de Datos / Líder Técnico — generador de streaming, ingesta de datos |
| Camilo Salazar Acevedo | Gobernanza y Calidad de Datos — perfilamiento, diccionario de datos, reglas de calidad, Ley 1581 |
| María Alejandra Ocampo | Infraestructura y Despliegue Cloud — arquitectura GCP, Terraform, Cloud SQL, BigQuery, Cloud Functions, Cloud Run, frontend |

## Presentación y demo del Sprint 1

- **Diapositivas**: *(agregar aquí el link de Gamma/Drive cuando esté publicado)*
- **Demo en vivo del producto y del pipeline de datos**: https://neobanx-demo-scgmt4q3eq-uc.a.run.app
  Simula una transacción con un clic → se publica a Pub/Sub → se procesa en la Cloud Function → se persiste en BigQuery → aparece con su veredicto (aprobada/alerta) en tiempo real. Esto ejercita el pipeline real de punta a punta, no una maqueta.

## Arquitectura

```
Fuentes ──▶ Ingesta ──▶ Procesamiento ──▶ Almacenamiento ──▶ Visualización
```

| Capa | Tecnología | Rol |
|---|---|---|
| Fuentes | Dataset Sparkov (Kaggle), API Nager.Date | Base de transacciones y perfil de cliente; calendario de festivos |
| Ingesta | Google Pub/Sub | Streaming de eventos, respetando la cadencia temporal original |
| Procesamiento | Dataproc / Spark Structured Streaming (objetivo) | Enriquecimiento y aplicación de reglas de detección de fraude |
| Almacenamiento — Transaccional | Cloud SQL (PostgreSQL) | Registro y bloqueo de operaciones con garantías ACID |
| Almacenamiento — Analítico | BigQuery (modelo en estrella, objetivo) | Consultas agregadas para el dashboard |
| Almacenamiento — Distribuido | Redis / Memorystore (objetivo) | Perfil del cliente en clave-valor, baja latencia |
| Visualización | Looker Studio (objetivo) | Dashboard de estadísticas de fraude |

### Estado actual (Sprint 1 — Alfa)

La tabla de arriba es la arquitectura objetivo del proyecto completo. Esto es lo que ya está construido y corriendo de verdad en GCP hoy:

| Componente | Estado |
|---|---|
| Generador (Backend/generador/) — CSV Sparkov a Pub/Sub | Construido y probado end-to-end contra el proyecto real |
| Cloud Function consumidor — Pub/Sub a BigQuery Raw | Desplegada, incluye regla baseline de veredicto (aprobada/alerta) |
| BigQuery Raw (raw.transacciones_raw) | Desplegado vía Terraform, particionado por fecha |
| Cloud SQL (esquema clientes/transacciones/alertas) | Esquema desplegado; sin datos reales de clientes cargados aún |
| Demo Streamlit en Cloud Run (Frontend/) | Desplegado — simula transacciones y muestra el veredicto en vivo |
| Diccionario de datos y reglas de calidad (Documentation/) | Documentados a partir del perfilamiento del dataset |
| Spark Structured Streaming sobre Dataproc | Pendiente (Sprint 2) |
| Redis / Memorystore (perfil de cliente en streaming) | Pendiente (Sprint 2) |
| Looker Studio | Pendiente — el demo de Streamlit cubre esa necesidad por ahora |
| Modelo de detección real (ML) | Pendiente — hoy es una regla simple por monto+categoría, para demostrar el flujo completo |

## Estructura del proyecto

```
neobanx-fraud-detection/
├── .env                               Secretos y config real (NUNCA se sube, .gitignore)
├── .env.example                       Plantilla de .env — SÍ se versiona
├── .gitignore
├── .gitattributes                     Normaliza saltos de línea (LF) en .sh y .env
├── scripts/
│   ├── bootstrap.sh                   Crea .env, autentica gcloud, genera terraform.tfvars
│   ├── deploy.sh                      Despliega toda la infraestructura definida en Terraform
│   └── destroy.sh                     Destruye toda la infraestructura definida en Terraform
├── Backend/
│   ├── generador/                    Lee fraudTrain.csv y publica a Pub/Sub (Juanes)
│   │   ├── main.py                   Limpieza, orden cronologico, hash de PII, publish
│   │   ├── holidays.py               Integracion Nager.Date (festivos en Colombia)
│   │   ├── explorar_fraude.py        Utilidad para encontrar ventanas densas en fraude
│   │   ├── requirements.txt
│   │   └── data/                     fraudTrain.csv va aqui - NO se sube al repo (.gitignore)
│   ├── consumidor/                   Cloud Function: Pub/Sub -> BigQuery Raw (Maria)
│   │   ├── main.py                   Inserta cada mensaje + calcula el veredicto baseline
│   │   └── requirements.txt
│   ├── contrato_datos_generador.md   Contrato exacto del JSON que viaja por Pub/Sub
│   └── README.md                     Detalle del contrato + como correr el generador
├── Frontend/                         Demo en Streamlit, desplegado en Cloud Run (Maria)
│   ├── app.py                        Simula transacciones y muestra el veredicto en vivo
│   ├── Dockerfile
│   ├── requirements.txt
│   └── README.md
├── Infrastructure/                   Todo lo que gestiona Terraform (Maria)
│   ├── main.tf                       BigQuery, esquema Cloud SQL, Cloud Function, Cloud Run
│   ├── variables.tf                  project_id, region, db_password (sensible)
│   ├── schema.sql                    DDL: tablas clientes / transacciones / alertas
│   ├── terraform.tfvars.example      Plantilla de terraform.tfvars — SÍ se versiona
│   ├── terraform.tfvars              Valores reales, generado por bootstrap.sh (.gitignore)
│   └── README.md                     Requisitos, secretos, recursos, estado del despliegue
├── Documentation/                    Gobernanza y calidad de datos (Camilo)
│   ├── Diccionario datos.md
│   ├── hallazgos_profiling_fase2.md
│   ├── reglas_calidad_neobanx.md
│   └── perfilamiento_neobanx.ipynb
└── README.md                         Este archivo
```

Cada carpeta con código tiene su propio README.md con el detalle — este archivo es el mapa general, no repite lo que ya está explicado ahí.

## Scripts de reproducibilidad

Todo el entorno local (autenticación, configuración y despliegue) se levanta con unos pocos comandos, gracias a `.env` + `scripts/bootstrap.sh` + Terraform.

### Requisitos previos (una sola vez por máquina)

- `gcloud` CLI instalado
- `terraform` >= 1.7
- `psql` (usado internamente por Terraform para aplicar `schema.sql` a Cloud SQL)
- Python 3.11+ (si vas a correr el generador de streaming)
- **Git Bash** (en Windows, necesario para correr los scripts `.sh` de este repo — PowerShell/CMD no son compatibles con ellos)

### Paso 1 — Clonar el repo y crear tu `.env`

```bash
git clone <url-del-repo>
cd neobanx-fraud-detection
cp .env.example .env
```

Edita `.env` con los valores reales del equipo (pide `DB_PASSWORD` y `GENERATOR_SALT` por el documento privado del equipo, nunca por chat abierto). Formato esperado — **sin espacios alrededor del `=`**, y con comillas en los valores que tengan espacios (ej. fechas):

```dotenv
GCP_PROJECT_ID=neobanx-fraud-detection
GCP_REGION=us-central1

DB_INSTANCE_NAME=neobanx-transaccional
DB_NAME=neobanx
DB_PASSWORD=<contraseña real del equipo>

GENERATOR_SALT=<salt real del equipo>
TOPIC_ID=transacciones-neobanx
FECHA_INICIO="2019-02-25 22:00:00"
FECHA_FIN="2019-02-26 00:00:00"
MAX_FILAS=
```

### Paso 2 — Dar permisos de ejecución a los scripts (una sola vez por máquina, en Git Bash)

```bash
chmod +x scripts/bootstrap.sh
chmod +x scripts/deploy.sh scripts/destroy.sh
```

### Paso 3 — Bootstrap: autentica gcloud y genera `terraform.tfvars` automáticamente

```bash
./scripts/bootstrap.sh
```

Esto hace, en orden:
1. Verifica que `gcloud`, `terraform` y `psql` estén instalados.
2. Autentica tu cuenta de Google con gcloud.
3. Genera `Infrastructure/terraform.tfvars` automáticamente a partir de tu `.env` — **nunca lo escribas a mano**.

> **Nota — si el login por navegador falla** (error `mismatching_state` / CSRF, común en Windows/Git Bash), usa el flujo manual, en dos ventanas de Git Bash:
> ```bash
> gcloud auth login --no-browser
> gcloud auth application-default login --no-browser
> ```
> Cada comando te da un link para abrir en el navegador y espera un código/comando de vuelta en la terminal. Verifica que quedaste autenticada con:
> ```bash
> gcloud auth list
> ```
> Debe mostrar tu cuenta con un `*` (cuenta activa). Este login solo se pide **una vez por máquina** — las siguientes veces que corras `bootstrap.sh`, si ya hay sesión activa, se salta este paso automáticamente.

### Paso 4 — Desplegar (o actualizar) toda la infraestructura

```bash
./scripts/deploy.sh          # terraform init + plan + apply, pide confirmación
./scripts/deploy.sh --yes    # sin confirmación, para automatización
```

`deploy.sh` cumple doble función: la primera vez **crea** los recursos, y en corridas posteriores **actualiza** cualquier cambio en el código (por ejemplo, si se modifica `main.py` del consumidor o `schema.sql`, Terraform detecta el cambio por hash y vuelve a aplicar solo lo necesario) — es el mismo comando para desplegar y para actualizar.

> **Nota — "Already Exists" al desplegar desde una máquina nueva**: como el estado de Terraform (`terraform.tfstate`) hoy es local a cada máquina, si alguien ya desplegó estos recursos desde otra computadora, tu `apply` puede fallar con errores `409: Already Exists`. Se soluciona importando el recurso al estado local antes de repetir el `apply`, por ejemplo:
> ```bash
> cd Infrastructure
> terraform import google_bigquery_dataset.raw projects/neobanx-fraud-detection/datasets/raw
> ```
> *Plan de remediación*: migrar a un backend remoto de Terraform (bucket de GCS compartido) para que todo el equipo use el mismo estado y este paso deje de ser necesario.

### Paso 5 — Destruir toda la infraestructura (cuando termines de trabajar)

```bash
./scripts/destroy.sh          # terraform destroy, pide confirmación
./scripts/destroy.sh --yes    # sin confirmación
```

Elimina todo lo gestionado por este Terraform, para no dejar recursos consumiendo créditos educativos.

> **Nota — Cloud SQL cobra por tiempo activo**, no solo por uso real: si no vas a destruir toda la infraestructura pero sí terminaste de trabajar por el día, apaga solo la instancia:
> ```bash
> gcloud sql instances patch neobanx-transaccional --activation-policy=NEVER --project=neobanx-fraud-detection
> ```
> Y para volver a prenderla antes de trabajar:
> ```bash
> gcloud sql instances patch neobanx-transaccional --activation-policy=ALWAYS --project=neobanx-fraud-detection
> ```

### Resumen — flujo completo desde cero

```bash
git clone <url-del-repo>
cd neobanx-fraud-detection
cp .env.example .env
# editar .env con los valores reales del equipo
chmod +x scripts/bootstrap.sh scripts/deploy.sh scripts/destroy.sh
./scripts/bootstrap.sh
./scripts/deploy.sh --yes
```

> **Nota de alcance**: el tópico de Pub/Sub y la instancia de Cloud SQL (`neobanx-transaccional`) se aprovisionaron en el Sprint 0 y este Terraform los referencia (`data` sources), no los vuelve a crear. Esto está documentado como excepción en la sección "Procesos manuales" más abajo.

## Cómo correr el generador de streaming

El generador (`Backend/generador/main.py`) lee su configuración (`GENERATOR_SALT`, `FECHA_INICIO`, `FECHA_FIN`, `TOPIC_ID`, `MAX_FILAS`) desde variables de entorno. En vez de escribir esas variables a mano cada vez, se cargan automáticamente desde el `.env` de la raíz del repo con `source`.

### Requisitos

- Haber completado el `.env` (ver sección "Scripts de reproducibilidad" arriba).
- Tener `fraudTrain.csv` (Kaggle `kartik2112/fraud-detection`) en `Backend/generador/data/fraudTrain.csv` — no se versiona (`.gitignore`).

### Pasos (en Git Bash)

```bash
cd Backend/generador
pip install -r requirements.txt

# Carga las variables del .env de la raíz del repo en esta terminal
set -a
source ../../.env
set +a

python main.py
```

Verifica que las variables sí se cargaron antes de correr `main.py`:

```bash
echo "GENERATOR_SALT=$GENERATOR_SALT"
echo "FECHA_INICIO=$FECHA_INICIO"
echo "FECHA_FIN=$FECHA_FIN"
```

Si alguna sale vacía, confirma que estás parado en `Backend/generador/` (`pwd`) y que el `.env` existe dos niveles arriba (`ls ../../.env`).

### Verificar que el pipeline recibió las transacciones

En una segunda terminal de Git Bash, sin cerrar la que está corriendo el generador:

```bash
bq query --project_id=neobanx-fraud-detection --use_legacy_sql=false \
  "SELECT trans_num, merchant, amt, veredicto, ingestion_timestamp FROM \`neobanx-fraud-detection.raw.transacciones_raw\` ORDER BY ingestion_timestamp DESC LIMIT 5"
```

Si aparecen filas nuevas con `veredicto` en `aprobada`/`alerta`, el pipeline generador → Pub/Sub → Cloud Function → BigQuery está funcionando de punta a punta. También se puede observar en vivo desde el demo del frontend (`Frontend/README.md`).

## Manejo de credenciales, secretos y tokens

**Ningún secreto real está ni ha estado en el historial de este repositorio.**

- `.env` (contiene `DB_PASSWORD`, `GENERATOR_SALT`) está en `.gitignore` desde su creación; solo `.env.example` (con valores ficticios tipo `changeme`) se versiona
- `terraform.tfvars` (contiene `db_password`) está en `.gitignore`; solo `terraform.tfvars.example` se versiona, y el real lo genera automáticamente `scripts/bootstrap.sh` a partir de `.env`
- `terraform.tfstate` / `terraform.tfstate.backup` están en `.gitignore` — pueden contener valores sensibles una vez aplicados, y **nunca deben subirse a git** (quedarían legibles en el historial de commits)
- `db_password` está declarada `sensitive = true` en `variables.tf`, para que Terraform la oculte en logs y outputs
- No existen archivos de *service account* (`.json` de credenciales) en el repositorio; la autenticación local se hace vía `gcloud auth application-default login`, que guarda las credenciales fuera del proyecto
- Contraseñas y claves reales se comparten por un documento privado del equipo (Drive), nunca por chat abierto ni por commit

## DDL, generadores, modelos, pipelines y pruebas

| Elemento | Ubicación |
|---|---|
| DDL del modelo transaccional | `Infrastructure/schema.sql` (tablas `clientes`, `transacciones`, `alertas`) |
| Esquema de la capa analítica (BigQuery) | `Infrastructure/main.tf` → `google_bigquery_table.transacciones_raw` |
| Generador de datos (streaming) | `Backend/generador/main.py` |
| Consumidor / modelo baseline de detección | `Backend/consumidor/main.py` (función `calcular_veredicto`) |
| Pipeline de infraestructura completo | `Infrastructure/main.tf` |
| Frontend / demo | `Frontend/app.py` |
| Pruebas funcionales realizadas | Manuales, con casos de control conocidos (ver `Infrastructure/README.md`: mensajes `test_veredicto_ok` / `test_veredicto_alerta` verificados en BigQuery) |
| Pruebas automatizadas | No implementadas en Sprint 1 — planificadas para Sprint 2 (GitHub Actions) |

## Procesos manuales identificados y justificados

- **Aprovisionamiento inicial de Pub/Sub y de la instancia de Cloud SQL**: se crearon en el Sprint 0, antes de adoptar la política estricta de "todo vía Terraform" del Sprint 1. Este `main.tf` los referencia como recursos existentes (`data` sources) en vez de recrearlos. *Plan de remediación*: incorporar su creación a Terraform (`google_pubsub_topic`, `google_sql_database_instance` como `resource`, no `data`) en Sprint 2, o documentar formalmente como infraestructura base fuera del ciclo de vida gestionado.

- **Autorización de red `0.0.0.0/0` en Cloud SQL**: para que Terraform (vía `psql`) y el equipo pudieran conectarse a la instancia y aplicar `schema.sql`, se autorizó temporalmente el acceso desde cualquier IP en la consola de GCP, una única vez.
  *Por qué se hizo manual*: automatizarlo con IPs dinámicas por integrante o Cloud SQL Auth Proxy requería tiempo adicional no disponible en el Sprint 1.
  *Riesgo aceptado*: la instancia solo contiene datos sintéticos de prueba.
  *Plan de remediación (Sprint 2)*: Cloud SQL Auth Proxy o restricción a IPs específicas del equipo, gestionado vía Terraform.

- **Estado de Terraform (`terraform.tfstate`) local a cada máquina**: al ser un repo de equipo, cada integrante que corre `deploy.sh` desde su propia computadora mantiene su propia copia local del estado, lo que puede producir errores `409: Already Exists` si el recurso ya fue creado desde otra máquina (ver nota en la sección "Scripts de reproducibilidad").
  *Por qué se hizo así*: para el Sprint 1 se priorizó tener el pipeline funcionando end-to-end sobre configurar infraestructura de estado remoto.
  *Plan de remediación (Sprint 2)*: backend remoto de Terraform sobre un bucket de Google Cloud Storage (GCS), compartido por todo el equipo, con bloqueo de estado para evitar que dos personas apliquen cambios al mismo tiempo.

Ningún otro recurso (BigQuery, Cloud Function, Cloud Run, IAM, APIs habilitadas) se creó o modificó manualmente — todo vive en `Infrastructure/main.tf`.

## Decisiones técnicas y trade-offs

| Decisión | Elegido | Por qué |
|---|---|---|
| Procesamiento | Streaming (transacciones) + batch de apoyo (perfil cliente) | SLA de detección < 5s; el perfil de cliente cambia poco |
| Capa transaccional | SQL — Cloud SQL (PostgreSQL) | ACID e integridad referencial para operaciones financieras |
| Capa analítica | Data Warehouse — BigQuery | Particionamiento y consultas rápidas sin gestionar infraestructura |
| Perfil de cliente | Clave-valor — Redis/Memorystore (Sprint 2) | Lecturas de baja latencia durante el streaming |
| Cómputo | Serverless (Cloud Functions, Cloud Run) | Menor complejidad operativa y costo, escalado automático |
| Infraestructura | Terraform (IaC) | Reproducibilidad total, mínimos pasos manuales |
| Modelo de detección (Sprint 1) | Regla baseline (monto + categoría) | Punto de partida rápido y explicable; modelo de ML real planificado para Sprint 2 |

**Seguridad**: PII tokenizada (hash HMAC determinístico) antes de salir de la capa transaccional · acceso a Cloud SQL con SSL obligatorio · secretos nunca en el repositorio.

**Costo**: cuenta educativa con presupuesto mensual y alertas en 50/90/100% · Cloud SQL se detiene cuando no está en uso · resto de servicios serverless, con costo proporcional al uso real.

## Fuentes de datos

1. **Dataset base de transacciones — Sparkov** (Kaggle): dataset sintético de transacciones con tarjeta de crédito, incluye transacción, perfil de cliente y geolocalización en un solo registro.
2. **Generador de streaming propio**: script en Python que ordena el dataset por `trans_date_trans_time` y publica cada evento a Pub/Sub respetando los intervalos de tiempo reales.
3. **API Nager.Date** (`date.nager.at`): calendario de festivos de Colombia, cacheado para enriquecer las reglas de detección.

## Modelos de datos

- **Transaccional (ER, normalizado)**: clientes, transacciones, alertas — con integridad referencial y transacciones ACID.
- **Analítico (estrella)**: tabla de hechos de transacciones con dimensiones de cliente, tiempo, ubicación y canal (Sprint 2).
- **Distribuido (clave-valor)**: perfil histórico del cliente en Redis, para lecturas de baja latencia durante el streaming (Sprint 2).

## Gobernanza y calidad de datos

Resultado del perfilamiento completo del dataset base, en `Documentation/`:

- **Diccionario de datos** — los 23 campos del dataset Sparkov, con tipo, sensibilidad (PII) y notas de calidad por campo.
- **Hallazgos del perfilamiento — Fase 2** — completitud, unicidad, consistencia y exactitud sobre el histórico completo (1.296.675 registros).
- **Reglas de calidad de datos** — reglas formales de completitud, unicidad, tipado, rango y anonimización de PII a implementar en el pipeline.

## KPIs y SLAs

| Pregunta de Negocio | KPI | SLA Técnico |
|---|---|---|
| ¿Detectamos el fraude a tiempo? | % de transacciones fraudulentas detectadas en tiempo real | Latencia del pipeline < 5 segundos |
| ¿Cuántos clientes buenos bloqueamos por error? | % de falsos positivos | Precisión de las reglas de detección |
| ¿Qué operación es más riesgosa? | Ranking de operaciones por tasa de fraude | Tiempo de respuesta del dashboard < 5 segundos |
| ¿Los datos son confiables? | % de transacciones con datos completos | Completitud de datos > 95% |

## Metodología

Cadencia ágil (Scrum) apoyada en CRISP-DM (comprensión del dominio y los datos), DataOps (versionamiento y monitoreo básico del pipeline) y DAMA-DMBOK (gobernanza de datos, a nivel introductorio).

## Cronograma

| Sprint | Semanas | Entregable |
|---|---|---|
| Sprint 0 | 1 – 3 | Propuesta de proyecto |
| **Sprint 1** | **4 – 7** | **Producto Alfa (Walking Skeleton) — este entregable** |
| Sprint 2 | 8 – 15 | Producto Beta (modelado + gobernanza) |
| Sprint Final | 16 – 17 | Producto Final (dashboard + sustentación) |

## Alcance

**Incluye**: arquitectura de datos en GCP, ingesta streaming desde 3 fuentes, procesamiento con Spark Structured Streaming (objetivo), los tres modelos de datos, gobernanza básica (diccionario, calidad), dashboard.

**No incluye**: entrenamiento de modelos de ML/DL en Sprint 1, desarrollo de una aplicación bancaria de cara al cliente, implementación completa de DAMA-DMBOK, conexión con datos financieros reales. El demo en `Frontend/` es una herramienta interna de validación del pipeline, no un producto para clientes del neobanco; la regla de veredicto que usa hoy es lógica simple por monto/categoría, no un modelo entrenado.

## Documentación y presentación del Sprint 1

- Guías de cada componente: `Backend/README.md`, `Frontend/README.md`, `Infrastructure/README.md`
- Gobernanza y calidad de datos: ver sección arriba
- Presentación del Sprint 1: *(agregar aquí el enlace cuando esté publicado)*

## Referencias

- SCARFF: Scalable Real-time Fraud Finder — [arxiv.org/pdf/1709.08920](https://arxiv.org/pdf/1709.08920)
- Detección de Fraude en Tiempo Real con Spark: Micro-Batch vs. Continuo — [gprjournals.org](https://gprjournals.org/journals/index.php/ajt/article/view/465)
- Credit Card Fraud Detection con PySpark — [github.com/Akak0o0y/credit-card-fraud-detection-spark](https://github.com/Akak0o0y/credit-card-fraud-detection-spark)
