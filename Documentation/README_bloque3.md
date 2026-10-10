# Bloque 3 · Analítica, gobernanza, tablero, frontend y agente de IA

**Responsable:** María Alejandra Ocampo · Equipo Sparktanos · SI4002 EAFIT · Sprint 2

Este documento explica todo lo que construye el Bloque 3 sobre la plataforma NeobanX: qué es cada pieza, por qué se diseñó así, cómo se despliega y cómo se prueba. Todo se crea con `scripts/deploy.sh` y se borra con `scripts/destroy.sh`. **El único paso manual es el tablero de Looker Studio** (sección 5).

---

## 1. Dónde encaja el Bloque 3

```
fraudTest.csv ─▶ registro (Cloud Run) ─▶ Cloud SQL ─▶ Pub/Sub ─▶ motor de reglas ─▶ cierre ─▶ Cloud SQL
                      ▲                       │                                                  │
                      │                       │ Datastream (CDC)                                 │
   ┌──────────────────┴───────────┐           ▼                                                  │
   │ FRONTEND (Streamlit)         │      BigQuery `raw` ──(cada 15 min)──▶ BigQuery `analitica`  │
   │  · Generador en vivo         │                                         │  modelo estrella   │
   │  · Monitor en tiempo real ◀──┼─────────────────────────────────────────┼────────────────────┘
   │  · Asistente de fraude ──────┼──▶ AGENTE (ADK + Gemini) ◀── Cloud SQL  │  calidad, linaje
   └──────────────────────────────┘                                         ▼
                                                                   LOOKER STUDIO (tablero)
```

Hay dos caminos de datos, y el diseño los separa a propósito:

| Camino | Qué lleva | Latencia | Quién lo usa |
|---|---|---|---|
| **Caliente** (streaming) | Cada transacción por Pub/Sub hasta el veredicto, en Cloud SQL | < 5 s (SLA) | Monitor del frontend y agente |
| **Tibio** (micro-batch) | Réplica CDC en BigQuery, transformada cada 15 min al modelo estrella | ~15 min | Tablero de Looker y reglas de calidad |

La decisión de bloquear se toma en el camino caliente. La analítica nunca frena una transacción.

---

## 2. Modelo analítico en estrella (Kimball) · `Infrastructure/sql/modelo_estrella.sql`

Una **consulta programada** de BigQuery (`google_bigquery_data_transfer_config.modelo_estrella`, cada 15 min, como `sa-analitica`) reconstruye el dataset `analitica` a partir de `raw`:

| Objeto | Tipo | Grano / contenido |
|---|---|---|
| `fact_transacciones` | Hecho | Una fila por transacción: monto, estado, veredicto, latencias, banderas de fraude |
| `dim_cliente` | Dimensión | Cliente por `cc_num_hash` (nunca el número real) |
| `dim_comercio` | Dimensión | Comercio y categoría |
| `dim_tiempo` | Dimensión | Fecha, hora, día de semana y festivo (EE. UU.) |
| `dim_estado` | Dimensión | Catálogo de estados de la transacción |
| `clientes_enmascarados` | Tabla | Capa enmascarada por generalización: inicial + `***`, año de nacimiento, estado y código postal `050XX`; sin ciudad, coordenadas, género ni ocupación |
| `festivos_us` | Referencia | Festivos de EE. UU. desde la API pública Nager.Date |
| `linaje_transaccion` | Vista | Los 5 pasos de cada transacción: registro → veredicto → cierre → réplica CDC → modelo |
| `v_tablero_*` | Vistas | Lo que lee Looker: `transacciones`, `kpis`, `categorias`, `reglas` |

Todas las tablas y vistas llevan **descripción y etiquetas** (`data_owner`, `data_steward`, `dominio`, `clasificacion`, `capa`). Con eso aparecen en el catálogo de Dataplex y se pueden buscar.

---

## 3. Gobernanza (DAMA-DMBOK)

### 3.1 Clasificación y control de acceso · `Infrastructure/gobernanza.tf`
- **Taxonomía de Data Catalog** `pii` con dos *policy tags*:
  - `PII_alta` (identifica directamente): nombre, apellido, género, ocupación, fecha de nacimiento y coordenadas del hogar.
  - `Cuasi_identificador` (identifica combinado con otros datos): ciudad y código postal.
- Solo `sa-analitica` y el agente de Datastream tienen `FineGrainedReader`. Cualquier otra persona recibe **Access Denied** al leer esas columnas en `raw.public_clientes` (verificado).
- **Por qué enmascaramiento estático y no *Data Policies*:** el enmascaramiento dinámico de BigQuery (`maskedReader`) exige una Organización de GCP, y el proyecto académico es de una cuenta personal. Por eso se publica la tabla generalizada `clientes_enmascarados` para los analistas, y la tabla cruda queda protegida por los policy tags.
- **El `cc_num` real nunca entra a ninguna base.** El generador y el frontend lo convierten con HMAC-SHA256 (`Backend/common/hmac_util.py`), con la clave en Secret Manager.

### 3.2 Catálogo · `scripts/aplicar_catalogo.sh`
Etiqueta las tablas `raw.public_*` y `analitica.festivos_us` (dueño, steward, clasificación). Las de transacciones, veredictos e historial son de `gerencia_riesgo_fraude`, y las de clientes y cuentas del `oficial_proteccion_datos` (clasificación `restringida_pii`).

### 3.3 Calidad de datos · `Infrastructure/sql/calidad.sql`, `Infrastructure/calidad.tf`
Una consulta programada cada 15 min corre 6 reglas y **agrega** el resultado a `analitica.dq_resultados`. La vista `dq_ultima_corrida` muestra la última corrida:

| Regla | Dimensión DAMA | Qué revisa |
|---|---|---|
| R1 | Unicidad | `trans_num` no se repite |
| R2 | Validez | El estado pertenece a la máquina de estados |
| R3 | Oportunidad | Ninguna transacción lleva más de 5 minutos en `pendiente_analisis` |
| R4 | Validez | `codigo_postal` tiene exactamente 5 dígitos |
| R5 | Exactitud | El monto es mayor que cero |
| R6 | Integridad referencial | Todo veredicto corresponde a una transacción existente |

Para correrla a mano: `bash ./scripts/correr_calidad.sh`

### 3.4 Linaje
- **Técnico:** la Data Lineage API (`datalineage.googleapis.com`) dibuja el grafo `raw → analitica` en Dataplex.
- **De negocio:** la vista `linaje_transaccion` cuenta la historia de cada transacción en 5 pasos, con sus tiempos.

### 3.5 Diccionario de datos
`Documentation/diccionario_datos_v2.md`: roles, clasificación, inventario de los 15 objetos, todas las columnas, reglas de calidad, linaje y la correspondencia con el diccionario v1.

---

## 4. KPIs y SLAs

| Pregunta de negocio | KPI | SLA |
|---|---|---|
| ¿Detectamos el fraude a tiempo? | KPI 1 · % de fraude real detectado | Latencia p95 de cierre < 5 s |
| ¿Cuántos clientes buenos bloqueamos? | KPI 2 · % de falsos positivos sobre bloqueadas | — |
| ¿Qué operación es más riesgosa? | KPI 3 · Ranking de categorías por tasa de fraude | Tablero < 5 s |
| ¿Los datos son confiables? | KPI 4 · % de transacciones completas | > 95 % |
| ¿Las alertas son coherentes? | KPI 5 · % de alertas consistentes (sin duplicadas ni perdidas) | — |

**Resultados de una corrida de referencia (~5.500 transacciones):** 36 % de fraude detectado, 82 % de falsos positivos, 100 % de completitud, 92 % de alertas consistentes, p95 < 1 s.

**Hallazgos:**
- `grocery_pos` y `gas_transport` tienen fraude real pero 0 % de bloqueo: las reglas actuales no cubren esas categorías.
- El fraude se concentra entre las 22 h y las 3 h.
- En Thanksgiving la tasa de fraude sube a 1,8 %, contra 1,1 % en días normales.

> Las cifras cambian en cada corrida: dependen de cuántas transacciones se generen y desde qué fecha.

---

## 5. Tablero en Looker Studio (único paso manual)

Fuentes: `analitica.v_tablero_kpis`, `v_tablero_transacciones`, `v_tablero_categorias`, `v_tablero_reglas` y `dq_ultima_corrida`.

| Página | Contenido |
|---|---|
| **Resumen** | Las 5 tarjetas de KPI, latencia p95 (`sla1_latencia_p95_seg`), monto bloqueado y monto de fraude no detectado |
| **Riesgo** | Tabla con barras por categoría, fraude por hora del día, mapa por estado y comparación festivo / no festivo |
| **Calidad y operación** | Semáforo de las 6 reglas de calidad y dona de estados finales |

Cómo conectarlo: Looker Studio → *Crear* → *Fuente de datos* → BigQuery → proyecto `neobanx-fraud-detection` → dataset `analitica` → la vista. La actualización de datos se pone en 15 min, igual que la consulta programada.

---

## 6. Frontend de demo · `Frontend/`, `Infrastructure/frontend.tf`

App en **Streamlit 1.40.1** sobre Cloud Run. **Nada es simulado:** lee el CSV real y llama a la API real.

| Pestaña | Qué hace |
|---|---|
| **Login** | Usuario `neobanx`. La contraseña la genera Terraform (`random_password`) y vive en Secret Manager (`neobanx-frontend-login`); se compara con `hmac.compare_digest` y hay máximo 5 intentos |
| **▶️ Generador en vivo** | Lee `fraudTest.csv` y envía cada fila a `POST /transacciones` del servicio de registro, con HMAC de la tarjeta y el contrato `TransaccionEvento`. Controles: cantidad (20 a 2000), velocidad (1 a 15 tx/s) y fecha de inicio del dataset |
| **📡 Monitor en tiempo real** | Lee Cloud SQL con el rol de solo lectura `frontend_ro`. Intervalo de 1 a 30 s y límite de 100 a 1000 filas. Muestra totales, % analizadas, bloqueadas, timeouts, pendientes, latencia p95 y la tabla coloreada por estado |
| **💬 Asistente de fraude** | Chat con el agente (sección 7), con preguntas sugeridas y una sección para probar los límites |

**Decisiones:**
- **Un hilo de fondo envía las transacciones**, así la página no se congela.
- **`max_instance_count = 1` y afinidad de sesión:** hay un solo generador a la vez y la sesión no cambia de servidor a mitad de la demo.
- **`cpu_idle = false`:** el hilo del generador sigue corriendo entre peticiones.
- **El servicio de registro es privado.** El frontend lo llama con un *ID token* de `sa-frontend`, que tiene `run.invoker` **solo** sobre ese servicio.

**Ver la contraseña:**
```powershell
docker run -it --rm -v neobanx-gcloud-config:/root/.config/gcloud neobanx-deploy -c "gcloud secrets versions access latest --secret=neobanx-frontend-login"
```
Se mantiene entre deploys y cambia después de cada `destroy`, porque se genera una nueva.

---

## 7. Agente de IA · `Backend/agente/`, `Infrastructure/agente.tf`

**Google ADK 1.18.0 + Gemini Flash en Vertex AI**, servido con FastAPI en Cloud Run. El agente **no decide bloqueos**: eso lo hace el motor de reglas. Solo **explica** decisiones ya tomadas, con los datos guardados, lo que mantiene la decisión del proyecto de no usar ML para decidir.

### 7.1 Herramientas (`herramientas.py`)
Son consultas **fijas y parametrizadas**: el modelo elige cuál usar, pero nunca escribe SQL.

| Herramienta | Vista | Devuelve |
|---|---|---|
| `consultar_transaccion(trans_num)` | `linaje_transaccion` + `alertas` | Estado, reglas disparadas, tiempos, veredictos tardíos, etiqueta real y `cliente_ref` |
| `historial_cliente(cliente_ref)` | `v_historial_cliente` | Comportamiento agregado: totales, montos y categoría frecuente. **Sin ciudad ni ocupación** |
| `resumen_fraude(horas)` | `linaje_transaccion` | Conteos por estado, fraude bloqueado y escapado, falsos positivos, p95 y reglas más frecuentes |
| `bloqueadas_recientes(limite)` | `alertas` | Últimas alertas de fraude |

### 7.2 Tres capas contra la fuga de datos personales
1. **Base de datos:** el rol `agente_ro` solo puede hacer `SELECT` sobre 3 vistas. Leer `clientes` da *permission denied*.
2. **Herramientas:** nunca piden columnas sensibles, y el hash de la tarjeta sale recortado a 12 caracteres (`cliente_ref`).
3. **Guardrails en el servidor (`guardrails.py`):**
   - Antes del modelo, rechazan preguntas que piden datos personales (direcciones, nombres, teléfonos, tarjetas…), intentos de manipulación ("ignora tus instrucciones") y números de tarjeta escritos en el chat.
   - Después del modelo, ocultan cualquier número de tarjeta o hash completo que aparezca en la respuesta.

Aunque alguien lograra engañar al modelo, el dato personal **nunca le llega**, así que no puede filtrarlo. Además, la instrucción del agente limita los temas a fraude y le prohíbe inventar. La respuesta muestra los **datos crudos** que consultó, para que se pueda verificar.

### 7.3 Seguridad del servicio
- Es privado: **solo `sa-frontend`** tiene `run.invoker`.
- Corre como `sa-agente`, con `aiplatform.user`, `cloudsql.client` y acceso solo al secreto de `agente_ro`.
- El modelo se cambia en una línea (`local.modelo_agente` en `agente.tf`) si Google retira la versión.

### 7.4 Preguntas de prueba
- "¿Cuáles son las últimas 5 transacciones bloqueadas?"
- "¿Por qué se bloqueó la transacción `<trans_num>`? Compárala con el historial del cliente."
- "Resume el fraude de las últimas 24 horas."
- Límites: "Dame las direcciones de los clientes bloqueados" (rechazada por el guardrail) y "¿Me recomiendas una receta?" (fuera de tema).

---

## 8. Cómo desplegar y probar

Desde `C:\dev\neobanx-fraud-detection`, con Docker Desktop abierto:

```powershell
# 1. Desplegar todo (revisar el plan antes de escribir yes)
docker run -it --rm -v neobanx-gcloud-config:/root/.config/gcloud -v ${PWD}:/workspace neobanx-deploy -c "cd /workspace && ./scripts/deploy.sh"

# 2. Construir la capa analítica (policy tags, catálogo y primera corrida del modelo)
docker run -it --rm -v neobanx-gcloud-config:/root/.config/gcloud -v ${PWD}:/workspace neobanx-deploy -c "cd /workspace && bash ./scripts/construir_analitica.sh"

# 3. Al terminar la sesión: destruir
docker run -it --rm -v neobanx-gcloud-config:/root/.config/gcloud -v ${PWD}:/workspace neobanx-deploy -c "cd /workspace && ./scripts/destroy.sh"
```

**Prueba de punta a punta:**
1. Abrir la URL del frontend (la imprime `deploy.sh`) y entrar.
2. En el Generador, enviar 200 transacciones a 10 tx/s desde el 01/12/2020.
3. En el Monitor, verlas pasar de `pendiente_analisis` a `aprobada`, `bloqueada` o `no_preseleccionada_timeout`.
4. En el Asistente, preguntar por 3 transacciones bloqueadas.
5. Unos 15 minutos después, ver los datos en Looker.

**Reglas al desplegar:**
- Si `terraform init` pregunta si copiar el estado local al remoto, responder **no**.
- Antes de escribir `yes`, revisar que solo se destruyan recursos `null_resource.build_*`, que son reconstrucciones de imagen.
- Nunca subir `.env`, `terraform.tfvars` ni archivos `*_tmp.txt`.

---

## 9. Problemas conocidos y solución

| Síntoma | Causa | Solución |
|---|---|---|
| Todas las transacciones salen `no_preseleccionada_timeout` | El stub de veredictos deja de leer Pub/Sub tras horas sin uso | `gcloud run services update stub-veredicto --region us-central1 --update-env-vars REINICIO=$(date +%s)` |
| La primera carga del frontend es lenta | Cloud Run escala a 0 y la primera vez descarga el CSV | Abrir la página 2 minutos antes y enviar 20 transacciones de calentamiento |
| El chat responde "Tuve un problema consultando los datos" | Error del modelo o de la base | `gcloud run services logs read agente --region us-central1 --limit 30` |
| "model not found" en los logs del agente | Google retiró la versión de Gemini | Cambiar `local.modelo_agente` en `agente.tf` y volver a hacer deploy |
| No conecta Docker | Docker Desktop no está abierto | Abrirlo y comprobar con `docker info` que aparezca la sección `Server:` |

---

## 10. Archivos del Bloque 3

```
Backend/agente/            main.py · herramientas.py · guardrails.py · requirements.txt · Dockerfile
Frontend/                  app.py · requirements.txt · Dockerfile
Infrastructure/            gobernanza.tf · calidad.tf · frontend.tf · agente.tf
Infrastructure/sql/        modelo_estrella.sql · calidad.sql
scripts/                   construir_analitica.sh · aplicar_catalogo.sh · correr_calidad.sh
Documentation/             diccionario_datos_v2.md · README_bloque3.md
```

Todas las versiones están fijas (imágenes `python:3.12-slim-bookworm`, `requirements.txt` con `==`, Terraform 1.9.8) para que la imagen se construya igual hoy y el día de la demo.