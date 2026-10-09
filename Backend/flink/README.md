# Flink — job de detección (Bloque 2, Juan)

Job de PyFlink que consume `tx-preseleccionadas`, enriquece cada transacción
(perfil de Redis + festivo) y aplica 4 reglas de detección, publicando el
veredicto en `tx-veredictos`. Mientras este job no esté listo, el `stub de
veredicto` (`Backend/stub_veredicto/`) cumple su mismo rol con una regla
mucho más simple — ver `Backend/contrato_datos_generador.md`.

**Probado end-to-end en local**: emulador de Pub/Sub + Redis real + MiniCluster,
un mensaje publicado en `tx-preseleccionadas` produce el veredicto correcto
en `sub-cierre-veredictos`, con el contrato exacto que espera `cierre`.

**Probado end-to-end contra el CLÚSTER REAL de Dataproc** (2026-10-09): job
sometido con `venv.zip` (ver más abajo), estado `RUNNING` sin reinicios,
una transacción de prueba publicada a mano en `tx-preseleccionadas` llegó
hasta el servicio `cierre` real (Cloud Run) como un veredicto bien formado
— el único error fue una violación de llave foránea esperada (la
transacción de prueba nunca pasó por `registro`, así que no existe en
`transacciones`; es un artefacto de la prueba, no un bug). Confirma que las
4 piezas (Flink, los 2 puentes, Pub/Sub, `cierre`) funcionan juntas de
verdad, no solo en MiniCluster.

## Archivos

| Archivo | Qué hace |
|---|---|
| `reglas.py` | Las 4 reglas, lógica pura, sin Flink ni estado |
| `job.py` | `EvaluarReglas` (`KeyedProcessFunction`, conecta las reglas con `ValueState`/`ListState` reales) + `construir_pipeline`/`construir_pipeline_completo`, usados por los scripts de prueba |
| `enriquecimiento.py` | `EnriquecerPerfilRedis`/`EnriquecerFestivo` (`MapFunction`, llamadas síncronas — ver "Por qué síncrono, no Async I/O" más abajo) |
| `main.py` | **Punto de entrada real del job** — `FileSource` → parseo → enriquecimiento → reglas → `FileSink` |
| `puente_entrada.py` / `puente_salida.py` | Traducen Pub/Sub ↔ archivos (ver sección siguiente) |
| `probar_job_local.py` / `probar_pipeline_completo.py` | Scripts de prueba manual, no se despliegan |

## Por qué hay un "puente de archivos" entre Pub/Sub y Flink

PyFlink **no permite implementar un Source/Sink en Python puro** — confirmado
leyendo el código fuente: incluso la API moderna (`pyflink.datastream.
connectors.base.Source`/`Sink`) son `JavaFunctionWrapper`, solo envuelven
conectores ya compilados en Java. Existe un conector oficial de Pub/Sub para
Flink (`apache/flink-connector-gcp-pubsub`), pero sin binding de Python — usarlo
exigiría compilarlo con Maven y manejar la JVM a mano vía `py4j`, sin ningún
precedente documentado. Se descartó por el riesgo de tiempo frente al bloque
que queda.

En su lugar, dos procesos Python chicos (mismo patrón *worker* que
`Backend/cierre/`/`Backend/stub_veredicto/`) hacen de traductor:

```
tx-preseleccionadas (Pub/Sub)
  → puente_entrada.py (pull loop)         -- SOLO Python, sin Flink
  → archivos .jsonl nuevos en entrada/
  → Flink FileSource (monitoreo continuo) -- conector REAL de Flink, con Python
  → [parseo, enriquecimiento, reglas]
  → Flink FileSink
  → archivos .jsonl nuevos en salida/
  → puente_salida.py (poll + publish)     -- SOLO Python, sin Flink
  → tx-veredictos (Pub/Sub)
```

`FileSource`/`FileSink` **sí** son conectores reales de Flink con binding de
Python (`pyflink.datastream.connectors.file_system`) — no hay nada "simulado"
aquí, es el mismo mecanismo de checkpointing/exactly-once que usaría cualquier
job de Flink leyendo de un `FileSystem`. Los archivos nunca se les agrega una
línea a uno viejo (Flink solo detecta archivos *nuevos*): cada puente escribe
siempre a un nombre nuevo.

En la nube: el bucket es `Infrastructure/storage.tf` → `flink_puente`
(`gs://.../entrada/`, `gs://.../salida/`). En local: rutas `file:///...`
normales (ver `probar_*` y las variables `DIRECTORIO_ENTRADA`/`DIRECTORIO_SALIDA`).
Los dos puentes corren en el mismo nodo master de Dataproc junto al job, con
la identidad de `sa-flink` (ya tiene los roles de Pub/Sub necesarios) — no son
Cloud Run aparte, para no sumar otro servicio que cobre por estar siempre
encendido.

## Decisiones de diseño

### Por qué síncrono, no Async I/O

El diseño original usaba `AsyncFunction`/`AsyncDataStream` (Async I/O real
de Flink) para las llamadas a Redis y Nager.Date. Se probó en local, pasó
todos los casos... y al someter el job al clúster real, falló:
`ImportError: cannot import name 'AsyncDataStream'`.

**La causa**: el clúster corre **Flink 1.17.0** (Dataproc
`image_version="2.2-debian12")`), y esa API de Python simplemente no existe
en esa versión — se agregó en una versión de PyFlink mucho más reciente.
`pip install apache-flink` sin fijar versión instala la última disponible
(2.3.0 al momento de escribir esto), que es lo que probamos en local
originalmente, sin darnos cuenta de que no coincidía con el clúster real.
Confirmado leyendo por SSH el `pyflink.zip` bundleado del clúster: no
aparece ninguna mención de `Async` salvo en docstrings de conectores
Kinesis, que no tienen nada que ver.

**La solución**: `enriquecimiento.py` usa `MapFunction` normal — cada
llamada a Redis/Nager.Date bloquea hasta tener respuesta, en vez de varias
en vuelo a la vez. Esto **no** vuelve síncrono el flujo de detección
completo (eso sigue desacoplado por Pub/Sub, sin cambios); solo cambia el
rendimiento interno de este paso del job, y a nuestra escala no es un
cuello de botella real (Flink sigue paralelizando entre instancias).

**Lección aplicada en todo lo demás**: `Dockerfile.dev` ahora fija
`apache-flink==1.17.0` explícitamente (no "la última"), para que las
pruebas locales representen de verdad lo que corre en la nube. Esa versión
además:
- No tiene wheels de `numpy` para Python 3.11+ → la imagen usa Python 3.10.
- Usa reflexión interna (`ClosureCleaner`) que Java 17+ bloquea por defecto
  → `Dockerfile.dev` fija `JDK_JAVA_OPTIONS` con los `--add-opens`
  necesarios (Java 11, lo que Flink 1.17 espera, ya no está disponible en
  los repos de Debian 12, y Debian 11 quedó sin soporte).

### Bloqueador de `pyflink` en los TaskManagers — RESUELTO, confirmado en la nube real

**Estado**: el job llega a `RUNNING` en YARN, pero cada TaskManager (donde
corre el enriquecimiento de verdad) falla con:

```
Caused by: java.io.IOException: Failed to execute the command:
  python -c import pyflink;import os;print(os.path.join(os.path.abspath(os.path.dirname(pyflink.__file__)), 'bin'))
ModuleNotFoundError: No module named 'pyflink'
```

**Por qué pasa**: Flink arranca cada worker Python con un chequeo propio
que asume que `pyflink` es un paquete de `pip` instalado de verdad (usa
`pyflink.__file__` para ubicar su carpeta `bin/`, donde vive el script del
runner de UDFs). Eso es verdad del lado del *cliente* (`flink run`, que sí
resuelve `pyflink` correctamente porque usa el `.zip` bundleado vía
`-pyfs`/classpath) pero NO del lado del *TaskManager*: ese chequeo lanza un
subproceso `python` nuevo, sin el `PYTHONPATH` que Flink arma para sí mismo,
así que necesita que `pyflink` esté genuinely `pip install`eado en el
Python que use.

**Por qué no es trivial**: `pip install apache-flink==1.17.0` (la única
versión que trae `pyflink`con el "bin" que este chequeo busca, y la que
coincide con el clúster) exige `numpy<1.22`, que no tiene wheels para
Python 3.11+ — y el Python de sistema del clúster (`/usr/bin/python3`,
Debian 12) es 3.11.2. El mismo problema que ya resolvimos en
`Dockerfile.dev` bajando a Python 3.10 ahí, pero en el clúster no podemos
simplemente cambiar la imagen de Dataproc.

**La solución, oficial y ya validada en local**: empaquetar un venv
COMPLETO (con `apache-flink==1.17.0` de verdad instalado) en un `.zip`, y
que Flink mismo lo distribuya a cada TaskManager, apuntando tanto el lado
cliente como el de cada worker al intérprete DENTRO de ese zip. Esto ya no
depende del Python de sistema del clúster ni de sincronizar master/workers
a mano, y sobrevive a que el clúster se destruya y se recree, porque viaja
con el propio `flink run`.

1. **`Backend/flink/empaquetar_venv.sh`** (nuevo) construye el venv dentro
   de un contenedor de la misma imagen `Dockerfile.dev` que ya validamos
   contra MiniCluster — Python 3.10 + `apache-flink==1.17.0` + `numpy<1.22`,
   para no repetir el problema de versión — con `python -m venv --copies`
   (`--copies` es obligatorio: copia binarios reales, no symlinks, para que
   sea portable al empaquetarlo) y `pip install` de las mismas dependencias
   que ya usa el pipeline (`pydantic`, `requests`, `redis`, `cloudpickle`).
   Genera `Backend/flink/venv.zip` (~350 MB — pesado por `apache-beam`, que
   `apache-flink` arrastra como dependencia; no se commitea, ver
   `.gitignore`).
2. **`desplegar_job.sh`** sube `venv.zip` al bucket de staging junto con el
   código; **`run_en_master.sh`** lo descarga y somete el job con:
   ```bash
   flink run -d -m yarn-cluster \
     -pyarch venv.zip \
     -pyclientexec venv.zip/venv/bin/python3 \
     -pyexec venv.zip/venv/bin/python3 \
     -pyfs "$(pwd)/Backend/flink,$(pwd)/Backend/common,$(pwd)/contracts" \
     -py "$(pwd)/Backend/flink/main.py"
   ```
   (`-py`/`-pyfs` con ruta ABSOLUTA, no relativa: con `-pyarch` presente,
   Flink resuelve esos dos relativos a un directorio de staging interno
   que no es el directorio desde donde se somete — confirmado con
   `can't open file '.../python-archives/Backend/flink/main.py'` al usar
   rutas relativas, que sí funcionaban bien ANTES de agregar `-pyarch`.)
   Esto reemplaza la necesidad de `instalar_dependencias_flink.sh` para las
   dependencias de Flink — ese script sigue haciendo falta solo para
   `puente_entrada.py`/`puente_salida.py` (procesos Python normales, NO
   workers de Flink, corren con el Python de sistema) y para
   `perfiles_redis.py`/PySpark.

**Por qué esto resuelve el bloqueador de raíz**: el venv empaquetado trae
un `apache-flink==1.17.0` genuinamente instalado con `pip`, así que
`pyflink.__file__` apunta a un `bin/` real dentro del zip descomprimido —
exactamente lo que el chequeo interno de Flink busca. Y como Flink lo
distribuye él mismo a cada nodo antes de ejecutar, ya no importa qué Python
de sistema tenga el clúster, ni si master y workers están sincronizados.

**Validado en local, con costo $0, sin tocar la nube**
(`Backend/flink/probar_venv_empaquetado.py`, descartable): se levantó un
clúster Flink **standalone real** dentro del contenedor de
`Dockerfile.dev` (`start-cluster.sh` — un `StandaloneSessionClusterEntrypoint`
y un `TaskManagerRunner` de verdad, procesos JVM separados, no un
MiniCluster en el mismo proceso) y se sometió un job mínimo con
`flink run -pyarch venv.zip -pyclientexec venv.zip/venv/bin/python3 -pyexec
venv.zip/venv/bin/python3 -py probar_venv_empaquetado.py`. Resultado:
`Job has been submitted...Program execution finished...Job Runtime: 23918
ms`, exit code 0. Esto ejercita el mismo mecanismo de arranque de worker
Python que fallaba en YARN con `ModuleNotFoundError`, y aquí termina sin
error — confirma que la causa raíz (necesitar un `pyflink` pip-instalado de
verdad) está resuelta antes de gastar una tercera sesión de nube en
probarlo.

(Nota aparte, solo de esta validación local: el `start-cluster.sh` dentro
del contenedor también necesitó agregar `--add-opens=java.base/sun.net.
util=ALL-UNNAMED` a `JDK_JAVA_OPTIONS` — un paquete interno de Java 17
distinto al que ya cubríamos. Es un detalle de arrancar un clúster
standalone a mano para esta prueba; el clúster real de Dataproc ya
gestiona sus propios flags de Java y llegó a `RUNNING` sin este ajuste en
las dos sesiones anteriores, así que no aplica a `dataproc.tf`.)

**2 problemas adicionales encontrados al probar `venv.zip` contra el
clúster real (la prueba local de arriba no los detectó), ambos
arreglados**:

1. **`python:3.10-slim` cambió de base sin aviso**: ese tag "flotante" pasó
   de Debian 12 (bookworm) a Debian 13 (trixie) entre la sesión en que se
   escribió `Dockerfile.dev` originalmente y esta — confirmado con
   `cat /etc/os-release` dentro de la imagen. El `venv.zip` construido ahí
   traía un `libpython3.10.so.1.0` compilado contra un glibc más nuevo
   (2.38) que el del clúster real (Debian 12), y el binario ni cargaba:
   `version 'GLIBC_2.38' not found`. Arreglado fijando
   `FROM python:3.10-slim-bookworm` explícito en `Dockerfile.dev`.
2. **`venv --copies` no empaqueta un Python de verdad autónomo**: solo
   copia el ejecutable, NO la librería compartida (`libpython3.10.so.1.0`,
   resuelta por el cache de `ldconfig` del contenedor de build, que no
   existe en otra máquina) ni la librería estándar (los `.py` de
   `encodings`, `os`, etc., que viven en el prefix BASE, no dentro del
   venv). Confirmado en 2 intentos reales seguidos contra el clúster:
   primero `cannot open shared object file` (faltaba la `.so`), después
   `ModuleNotFoundError: No module named 'encodings'` (faltaba la stdlib).
   Arreglado en `empaquetar_venv.sh`: copia `libpython3.10.so*` dentro del
   venv + usa `patchelf --set-rpath '$ORIGIN/../lib_externa'` para que el
   binario la busque ahí; copia la stdlib completa (`/usr/local/lib/
   python3.10/*`) dentro de `venv/lib/python3.10/`; y borra `pyvenv.cfg`
   (ese archivo le dice al intérprete que su "home" es la ruta del
   contenedor de build, que no existe en el host real — sin él, CPython
   cae a su búsqueda por defecto relativa al propio ejecutable, que es
   justo donde quedó todo).

Con estos 2 arreglos, la misma prueba de arriba (clúster standalone real,
`flink run` con las 3 flags) se repitió en un contenedor **`debian:12-slim`
completamente limpio** (sin Python 3.10 instalado, sin `libpython`, nada —
la simulación más fiel posible del master real) y terminó igual: exit
code 0, `Job Runtime: 27138 ms`.

**Confirmado contra el clúster real de Dataproc (2026-10-09)**: con el
`venv.zip` corregido, el job llegó a `RUNNING` en YARN y el job interno
`neobanx-flink-deteccion` también, sin reinicios (`flink list` →
`RUNNING`, no `RESTARTING`). Apareció un tercer problema, menor, al
procesar una transacción real: `ModuleNotFoundError: No module named
'contracts'` en los TaskManagers — `-pyfs` embarca cada directorio
(`Backend/flink`, `Backend/common`, `contracts`) añadiendo su CONTENIDO
directo al `PYTHONPATH` del worker (no su nombre como paquete), por eso
`job.py`/`holidays.py` ya se importaban planos (`from job import ...`)
pero `from contracts import ...` no podía resolver `contracts` como
paquete. Arreglado en `main.py`: `from transaccion import
TransaccionEvento` / `from veredicto import VeredictoEvento` (imports
planos, mismo patrón que ya funcionaba). Con este arreglo, una transacción
de prueba publicada a mano en `tx-preseleccionadas` llegó hasta el
servicio `cierre` real como un veredicto bien formado (único error:
violación de llave foránea esperada, la transacción de prueba nunca pasó
por `registro`) — **pipeline completo confirmado de punta a punta**.

**Confirmación final, con datos reales (2026-10-09, segunda corrida de
este mismo día)**: con Redis ya con sus 983 perfiles (ver
`Infrastructure/perfiles.tf`, arreglo de `spark.pyspark.python` — bug
separado, no de Flink), una transacción real vía `registro` con monto muy
por encima del promedio histórico de una tarjeta real produjo
correctamente `["monto_sobre_promedio"]` con `version_reglas="flink-v1"`.
Con el stub de veredicto ya eliminado (`gcloud run services delete
stub-veredicto` — Flink es ahora el único motor), se repitió la prueba y
Flink respondió solo, correcto, aunque con `tardio=true`: el puente de
archivos (descubrimiento cada 2s + checkpoint cada 10s + propagación de
Pub/Sub) acumula más latencia que el timeout por defecto de 30s de
`registro`. No es un bug — es la arquitectura del puente priorizando
viabilidad sobre latencia — pero si una demo real necesita respuesta más
rápida, hay que bajar `INTERVALO_DESCUBRIMIENTO_MS`/
`INTERVALO_CHECKPOINT_MS` en `main.py` o subir
`TIMEOUT_VEREDICTO_SEGUNDOS` en `registro`.

**Fuentes consultadas**:
- [PyFlink FAQ — Preparing Python Virtual Environment](https://nightlies.apache.org/flink/flink-docs-release-1.17/docs/dev/python/faq/) — script de conveniencia y `add_python_archive`/`set_python_executable`.
- [PyFlink — YARN deployment](https://pyflink.readthedocs.io/en/main/getting_started/installation/yarn.html) — sintaxis exacta de `-pyarch`/`-pyexec`/`-pyclientexec` en modo YARN.
- [PyFlink Configuration](https://nightlies.apache.org/flink/flink-docs-master/api/python/user_guide/configuration.html) — diferencia entre `python.client.executable` (lado cliente) y `python.executable` (lado TaskManager).

**Lo que NO hay que repetir** (ya descartado, con evidencia):
- `-pyexec` apuntando al conda actual (`/opt/conda/miniconda3`, Python
  3.11): rompe la resolucion de `pyflink` del lado cliente en vez de
  arreglar el del TaskManager.
- Instalar dependencias en cualquier Python que no sea exactamente donde
  Flink las busca: confirmado que master y workers son nodos
  **independientes** -- un `pip install` manual en el master NO alcanza a
  los workers, hay que repetirlo en los 3 (o resolverlo vía la accion de
  inicializacion de Terraform, que sí corre en los 3).

### Por qué `dataproc:pip.packages` no funciona (y qué se usa en su lugar)

Otro hallazgo del primer intento real: ningún paquete de la propiedad
`dataproc:pip.packages` quedaba instalado en el clúster (confirmado por
SSH: `pip3 show redis` no encontraba nada). La imagen `2.2-debian12` tiene
activa la protección PEP 668 ("externally-managed-environment"), y el
mecanismo de Dataproc para esa propiedad no pasa `--break-system-packages`.
Se reemplazó por una **acción de inicialización** explícita
(`Infrastructure/instalar_dependencias_flink.sh`, referenciada en
`dataproc.tf`) que sí instala los paquetes correctamente en todos los
nodos.

### País de los festivos: EEUU, no Colombia

`Backend/common/holidays.py` (antes vivía en `Backend/generador/`, se movió
aquí porque el generador v2 no lo usa) consulta Nager.Date contra
`/PublicHolidays/{año}/US`. La versión original (Sprint 1) usaba `/CO`.

**Por qué el cambio**: el dataset Sparkov es sintético, pero modela
transacciones de EEUU — comercios, direcciones y coordenadas
(`merch_lat`/`merch_long`) caen todas en territorio estadounidense. Evaluar
la regla "monto alto en festivo" contra el calendario de Colombia no tiene
ningún sentido para estos datos: un 20 de julio (festivo colombiano) no es
un día especial para un comercio en Ohio.

### Las 4 reglas viven en un solo `KeyedProcessFunction`

No una función por regla: las 4 comparten la misma llave (`cc_num_hash`) y
dos de ellas (ráfaga, ubicación imposible) comparten el mismo estado por
tarjeta. Separarlas en funciones distintas obligaría a mantener ese estado
duplicado o a encadenar varios `keyBy`, sin ninguna ventaja real.

### Qué dato vive dónde

| Dato | Dónde vive | Por qué |
|---|---|---|
| Línea base histórica (`monto_promedio`, `monto_desviacion`, ...) | Redis, solo lectura | Job batch (`perfiles_redis.py`) la calcula una vez desde `fraudTrain`. Si Flink la actualizara con cada transacción evaluada, se envenenaría la línea base (ver comentario en `perfiles_redis.py`). |
| Última ubicación/hora conocida por tarjeta | Estado de Flink (`ValueState`) | Es información *reciente y mutable*, por definición no pertenece a una línea base estable. |
| Transacciones recientes (ráfaga) | Estado de Flink (`ListState`) | Mismo motivo — ventana deslizante, no un agregado histórico. |
| Festivo del día | Nager.Date (llamada HTTP síncrona), cacheado por año en memoria del proceso | Llamada pública, sin estado que mantener entre reinicios. |

### Reglas, resumen

1. **Monto vs. promedio**: z-score contra el perfil de Redis. Sin perfil (cuenta no vista en `fraudTrain`), la regla no se evalúa — no hay línea base.
2. **Ráfaga**: conteo de transacciones de la misma tarjeta en una ventana deslizante reciente.
3. **Ubicación imposible**: velocidad implícita (Haversine / tiempo) contra la transacción anterior de la misma tarjeta.
4. **Monto alto en festivo**: festivo (Nager.Date, EEUU) + monto sobre umbral.

## Entorno de desarrollo local

`apache-flink` no instala con Python 3.13 en Windows (una dependencia,
`grpcio-tools`, todavía no publica binarios para esa combinación). Se usa
Docker en su lugar — ver `Dockerfile.dev`, que fija **Flink 1.17.0 exacto**
(Python 3.10 + Java 17 con `--add-opens`) para que coincida con el clúster
real — ver "Por qué síncrono, no Async I/O" más arriba para la historia
completa de por qué esto importa:

```powershell
docker build -t neobanx-flink-dev -f Backend/flink/Dockerfile.dev Backend/flink/
docker run --rm -v ${PWD}:/workspace neobanx-flink-dev python /workspace/Backend/flink/mi_script.py
```

`Dockerfile.dev` es **solo para desarrollo local** (MiniCluster) — no se
despliega a ningún lado. El job real corre en el Flink que ya viene
instalado en el clúster de Dataproc (`Infrastructure/dataproc.tf`,
componente opcional `FLINK`).
