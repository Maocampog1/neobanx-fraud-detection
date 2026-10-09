# Sprint 2 — Bloque 2 (Juan) — Seguimiento

## Paso 0 — Preparación

- [X] Imagen Docker reconstruida (`cloud-sql-proxy` + `python3` confirmados)
- [X] Estado local de Terraform borrado (`.tfstate*`, `.terraform/`, incluido el residuo de `bamboo-test`)
- [X] `.env` actualizado (`DB_PASSWORD`/`GENERATOR_SALT`/`TOPIC_ID` fuera; `ALERT_EMAIL`, `BILLING_ACCOUNT`, `BUDGET_USD` dentro)
- [X] Verificado `roles/billing.costsManager` en la cuenta de facturación para `juanes1771@gmail.com`

## Fase local (sin costo de nube)

- [X] Contratos v2 en `/contracts` (evento transacción con `cc_num_hash` de 64 chars, evento veredicto) — probados con pydantic en local, incluyendo caso de validación que debe fallar
- [X] `Backend/contrato_datos_generador.md` actualizado a v2
- [X] Generador v2 (`Backend/generador/main.py`): lee `fraudTest`, usa `hmac_util`, HTTP autenticado al registro, `TX_POR_SEGUNDO`, reintentos
- [X] Servicio de registro (`Backend/registro/`): INSERT `recibida`, preselección, `deadline_at`, publish a `tx-preseleccionadas` — probado con Postgres local (`neobanx-pg-local`, puerto 5555) y rol real `app_registro`: a tiempo/sin preselección, preselección por umbral, duplicado (`ON CONFLICT DO NOTHING`), `cc_num_hash` inexistente → 422 sin dejar fila a medias. Historial vía trigger confirmado correcto.
- [X] Generador + registro probados juntos en local (Postgres Docker + `schema.sql`) — 20 transacciones de una muestra real de `fraudTrain.csv`, con `clientes`/`cuentas` cargados vía el mismo patrón de `cargar_maestros.sh` (tablas temporales + JOIN). Resultado: 3 `umbral_monto`, 3 `muestreo_aleatorio`, 14 `sin_analizar`, 0 atascadas en `recibida`, sin duplicados ni violaciones de FK.
- [X] Servicio de cierre (`Backend/cierre/`): pull loop de veredictos + monitor de timeouts con `SKIP LOCKED`, log `{"evento":"pendientes_vencidas","cantidad":N}`
- [X] Cierre probado en local (incluyendo condición de carrera con 2 procesos): veredicto a tiempo (`tardio=false`), timeout puro (monitor cierra 5 pendientes vencidas), veredicto tardío sobre fila ya cerrada (`tardio=true`, estado no cambia), y `SKIP LOCKED` confirmado con una fila bloqueada manualmente en otra sesión de `psql` (el monitor no esperó el lock, la cerró en la corrida siguiente tras liberarse). `/salud` y arranque sin `GOOGLE_CLOUD_PROJECT` (modo local) verificados.
- [X] Stub de veredicto (`Backend/stub_veredicto/`): regla baseline (monto alto / categoría de riesgo), llena `reglas_disparadas`, retraso configurable vía `RETRASO_SEGUNDOS`, `version_reglas="stub-v1"`
- [X] Stub probado en local: 4 casos de la regla (aprobada, monto alto, categoría riesgo, categoría riesgo sin disparar), callback completo con retraso simulado + `ack`, y mensaje corrupto → `nack` sin crashear. `/salud` y arranque sin `GOOGLE_CLOUD_PROJECT` verificados.
- [X] `scripts/test.sh` v2 diseñado (5 casos + carga sostenida) y pasando contra el stack local (Postgres Docker + emulador de Pub/Sub, generador+registro+stub+cierre reales corriendo juntos). Fixture committeado en `scripts/fixtures/carga_local.csv` (100 filas reales de `fraudTrain.csv`).

## Fase nube — sesión 1 (registro + cierre + stub)

- [X] `Infrastructure/run.tf` escrito (3 `google_cloud_run_v2_service`, `deletion_protection=false`) + nueva cuenta de servicio `sa-stub` en `secrets.tf` + `construir_imagen.sh` (build via `gcloud builds submit` con contexto = raíz del repo, necesario porque `contracts/`/`Backend/common/` viven fuera de cada carpeta de servicio)
- [X] `terraform apply` — corrido dos veces (la primera falló en `aplicar_schema` por correr fuera de la imagen Docker correcta, sin `cloud-sql-proxy`; la segunda, dentro de la imagen, completó los 139 recursos)
- [X] `test.sh` corrido contra la nube real (`scripts/test_nube.sh`, nuevo) — 5 casos + carga breve pasando: a tiempo, duplicado, repetido, timeout+tardío (fusionados, usando `gcloud run services update` para forzar timeouts cortos), carga de 10 tx. Bug encontrado y arreglado en el propio script: `wait` sin argumentos esperaba también a `cloud-sql-proxy` (nunca termina solo) y se colgaba para siempre.
- [X] `cierre`/`stub` apagados o destruidos al terminar la sesión (cobran por estar encendidos) — se hizo `destroy.sh` de todo el proyecto (138 recursos), ya que lo que sigue es trabajo 100% local (PyFlink) antes de la próxima sesión de nube

## Fase Flink

Entorno local de PyFlink listo (`Backend/flink/Dockerfile.dev`) — Python 3.13 (el único instalado localmente) no tiene builds de `grpcio-tools` para Windows, se resolvió con Docker. MiniCluster probado con un job mínimo (map+filter).

Investigación: cómo se somete un job a Dataproc con componente Flink — confirmado contra la doc oficial: `gcloud dataproc jobs submit flink` NO soporta Python (solo `--class`/`--jar`). El camino real es SSH al master (túnel IAP) + `export HADOOP_CLASSPATH=$(hadoop classpath)` + `flink run -d -m yarn-cluster -pyfs Backend/flink,Backend/common,contracts -py Backend/flink/main.py`.

Lógica PURA de las 4 reglas (`Backend/flink/reglas.py`, sin Flink todavía): monto vs. promedio (z-score, con fallback sin desviación), ráfaga (ventana deslizante), ubicación imposible (Haversine + velocidad), festivo+monto alto (EEUU, no Colombia — ver `Backend/flink/README.md`). 15 casos probados con Python plano, todos pasando.

Las 4 reglas conectadas a estado real de Flink (`Backend/flink/job.py`, `KeyedProcessFunction`), probado en MiniCluster (`Backend/flink/probar_job_local.py`): rafaga, ubicación imposible, monto vs. promedio y festivo disparan correctamente; estado aislado por tarjeta confirmado (tarjeta sin relación nunca se contamina)

**Pub/Sub ↔ Flink resuelto**: PyFlink no permite Source/Sink en Python puro (confirmado en el código fuente); se descartó compilar el conector oficial Java (`flink-connector-gcp-pubsub`) por riesgo/tiempo sin precedente. Solución: puente de archivos — `puente_entrada.py`/`puente_salida.py` traducen Pub/Sub ↔ archivos `.jsonl`, y `main.py` usa `FileSource`/`FileSink` (conectores reales de Flink, con binding de Python). Bucket `flink-puente` agregado en `storage.tf`.

**3 problemas reales encontrados en la primera sesión de nube de Flink, los 3 arreglados** (ver `Backend/flink/README.md`, sección "Decisiones de diseño", para el detalle completo):

1. `dataproc:pip.packages` nunca instaló nada en el master (PEP 668 de Debian 12, el mecanismo de Dataproc no pasa `--break-system-packages`) → reemplazado por una `initialization_action` propia (`Infrastructure/instalar_dependencias_flink.sh`), confirmado que SSH + `pip3 show` no encontraba ni `redis` en el master real.
2. El clúster corre **Flink 1.17.0**, no "la última" (2.3.0) que `pip install apache-flink` nos dio en local sin fijar versión → `AsyncDataStream`/`AsyncFunction` **no existen en 1.17**, confirmado leyendo el `pyflink.zip` real del clúster por SSH. `enriquecimiento.py` reescrito a `MapFunction` síncrono (el flujo de detección sigue siendo asíncrono a nivel de todo el sistema — Pub/Sub sigue desacoplando todo; lo que cambia es solo el rendimiento interno de este paso).
3. `Dockerfile.dev` ahora fija `apache-flink==1.17.0` exacto (no soporta Python 3.11+ por `numpy`, se bajó a 3.10; y necesita `--add-opens` de Java porque Java 17+ bloquea la reflexión interna de Flink 1.17 — Java 11 ya no está disponible ni en Debian 12 ni en el Debian 11 archivado). Pipeline completo (`main.py`, con los puentes de archivo) re-validado end-to-end con esta configuración corregida: mensaje de prueba → veredicto correcto (`bloqueada`, `monto_sobre_promedio`) con el contrato exacto.
   Costo de este hallazgo: una sesión de nube completa (apply + 142 recursos + varios intentos de SSH) que terminó en `destroy.sh` sin haber sometido el job real — pero ya no debería repetirse en la próxima sesión.

**Segunda sesión de nube de Flink — job llega a `RUNNING` en YARN, pero las tareas fallan en los TaskManagers.** Hallazgos nuevos (ver `Backend/flink/README.md`, sección "Bloqueador actual", para el detalle completo):

1. La `initialization_action` instalaba las dependencias en el Python de **conda** (`/opt/conda/miniconda3`), no en el de **sistema** (`/usr/bin/python3`) — el `pip3` resuelto por PATH en ese contexto es el de conda. Arreglado invocando `/usr/bin/python3 -m pip install` explícito en `Infrastructure/instalar_dependencias_flink.sh`.
2. Confirmado que Flink necesita el Python de **sistema**, no conda: solo el default de Flink resuelve `pyflink` (vive en un `.zip` bundleado, con el `PYTHONPATH` que Flink arma para sí mismo) — usar `-pyexec` apuntando a conda rompe esa resolución. `run_en_master.sh` usa `SYSTEM_PYTHON="/usr/bin/python3"` sin `-pyexec`.
3. **Master y workers son nodos independientes**: instalar dependencias a mano por SSH en el master no alcanza a los 2 workers (`neobanx-flink-w-0`, `neobanx-flink-w-1`), donde en realidad se ejecuta el código Python de las tareas. Faltaba `cloudpickle` (dependencia transitiva de PyFlink) también en los 3 nodos.
4. **Bloqueador sin resolver**: incluso con dependencias correctas en los 3 nodos, cada TaskManager falla con `ModuleNotFoundError: No module named 'pyflink'` al ejecutar un chequeo interno de Flink (`python -c "import pyflink;...print(...,'bin')"`) que exige que `pyflink` sea un paquete `pip` real (no solo el `.zip` bundleado que sí resuelve el lado cliente). Instalar `apache-flink==1.17.0` de verdad en el Python de sistema del clúster está bloqueado por `numpy<1.22` sin wheels para Python 3.11 (la versión de Python de sistema en Debian 12).
   Costo de este hallazgo: segunda sesión de nube completa (apply + varios intentos de `flink run` + SSH a los 3 nodos) terminada en `destroy.sh` sin job corriendo de verdad. Decisión explícita: investigar offline antes de una tercera sesión de nube.


* [ ] **Bloqueador de `pyflink` en los TaskManagers — resuelto, CONFIRMADO contra el clúster real de Dataproc (2026-10-09)**: Flink tiene un mecanismo oficial exactamente para este caso — empaquetar un venv completo (`apache-flink==1.17.0` + nuestras dependencias, construido en la misma imagen `Dockerfile.dev`) en un `.zip` (`Backend/flink/empaquetar_venv.sh`, nuevo, genera `venv.zip`, ~350MB, no se commitea), y someter el job con `-pyarch venv.zip -pyclientexec venv.zip/venv/bin/python3 -pyexec venv.zip/venv/bin/python3`. Validado primero en local con costo $0 (clúster Flink standalone real dentro de Docker, exit code 0), y luego 2 problemas adicionales que solo aparecieron contra el clúster real: la imagen base `python:3.10-slim` había cambiado de Debian 12 a 13 sin aviso (glibc incompatible) y `venv --copies` no empaqueta la librería compartida ni la stdlib de Python (ambos arreglados en `empaquetar_venv.sh`, ver `Backend/flink/README.md` para el detalle completo con comandos y fuentes). Tras esos 2 arreglos, **el job real llegó a `RUNNING` sin reiniciarse** (confirmado con `flink list`, no solo `yarn application -list`).

**Problema menor adicional, encontrado y arreglado en la misma sesión**: `ModuleNotFoundError: No module named 'contracts'` al procesar una transacción real — `-pyfs` embarca cada carpeta añadiendo su CONTENIDO al `PYTHONPATH` (no su nombre como paquete), así que `from contracts import ...` no resolvía. Arreglado en `main.py` con imports planos (`from transaccion import TransaccionEvento`), mismo patrón que ya usaban `job.py`/`holidays.py`.

**Pipeline COMPLETO confirmado de punta a punta contra la nube real**: una transacción de prueba publicada a mano en `tx-preseleccionadas` fue procesada por Flink, el veredicto salió bien formado por el puente de salida, llegó por Pub/Sub hasta el servicio `cierre` real (Cloud Run), y `cierre` lo deserializó y intentó insertarlo correctamente — el único error fue una violación de llave foránea esperada (la transacción de prueba nunca pasó por `registro`, es un artefacto de la prueba, no un bug real).

**Hallazgo + arreglo CONFIRMADO: Redis quedaba sin perfiles** (`ImportError: cannot import name 'secretmanager' from 'google.cloud'`) — causa: PySpark en Dataproc 2.x usa por defecto el Python de **conda** (`PYSPARK_PYTHON`, documentado en "Configure the Dataproc Python environment" de Google), pero `instalar_dependencias_flink.sh` instala las dependencias de `Backend/carga/perfiles_redis.py` (de Camilo) en el Python de **sistema** — necesario para Flink, ver más arriba. Mismo tipo de confusión conda-vs-sistema que ya resolvimos para Flink, esta vez golpeando el job de Camilo como efecto colateral de ese arreglo. **Arreglado** en `Infrastructure/perfiles.tf` (propiedades `spark.pyspark.python`/`spark.pyspark.driver.python = "/usr/bin/python3"`). **Validado contra la nube real en esta misma sesión: los 983 perfiles volvieron a cargar correctamente** (mismo número que Camilo había logrado originalmente).

**Segundo hallazgo + arreglo CONFIRMADO: `cierre` fallaba bajo carga con `BrokenPipeError`/`DeadlineExceeded` al conectar a Cloud SQL** — bug preexistente en `Backend/common/db_conexion.py` (compartido con `registro`), ajeno al trabajo de Flink: `_conectar_nube()` creaba un `Connector()` de Cloud SQL **nuevo en cada llamada**. A `registro` (una conexión por request, serializada) nunca le afectó, pero `cierre` es un proceso de larga vida que llama esto concurrentemente desde el monitor de timeouts Y desde el callback de Pub/Sub — cada `Connector()` nuevo abre su propio hilo de fondo para renovar certificados, y varios compitiendo a la vez bajo carga producían los errores de conexión (confirmado en los logs reales de Cloud Run durante la corrida de `test_nube.sh`). **Arreglado** cacheando un único `Connector()` y la contraseña a nivel de proceso (con un `threading.Lock()` para la primera inicialización). **Validado**: tras reconstruir y redesplegar, `test_nube.sh` pasó los 5 casos + carga sostenida sin ningún error de conexión.

**Hallazgo adicional, no un bug — latencia de Flink puede superar el timeout de 30s**: con el stub apagado, una transacción con perfil real tardía en recibir el veredicto de Flink (file-bridge: descubrimiento cada 2s + checkpoint cada 10s + propagación de Pub/Sub se suman) y la fila ya se había cerrado por timeout antes de que llegara — el veredicto de Flink sí llegó después, correcto (`monto_sobre_promedio`), pero con `tardio=true`. Es un comportamiento esperado del diseño (el puente de archivos prioriza viabilidad sobre latencia), no un error — pero vale la pena anotarlo: si se necesita latencia más baja en una demo real, ajustar `INTERVALO_DESCUBRIMIENTO_MS`/`INTERVALO_CHECKPOINT_MS` en `Backend/flink/main.py` o subir `TIMEOUT_VEREDICTO_SEGUNDOS`.

Stub apagado — `stub-veredicto` eliminado de Cloud Run (`gcloud run services delete`), confirmado que Flink solo también responde correctamente sin él (transacción `prueba-flink-solo-002`, veredicto `flink-v1` correcto).

Dataproc destruido al terminar esta sesión de nube

## Verificación final del bloque

- [X] `test.sh` completo pasando contra la nube real (confirmado 2026-10-09, tras el arreglo de `db_conexion.py`: los 5 casos + carga sostenida, "TODOS LOS CASOS PASARON")
- [X] Ningún `cc_num` en texto plano en logs del generador (confirmado por revisión de código: `Backend/generador/main.py` solo loguea `trans_num`/`monto` por transacción, nunca `cc_num` ni `cc_num_hash`)
- [X] `destroy.sh` corrido — nada quedó encendido de más (confirmado 2026-10-09)

**Bloque 2 (Juan) — CERRADO.** Las 4 piezas (generador, registro, cierre, Flink) funcionan de punta a punta contra la nube real, con Flink como único motor de detección (stub ya apagado/eliminado), Redis con sus 983 perfiles, y sin el bug de conexión de `cierre` bajo carga.
