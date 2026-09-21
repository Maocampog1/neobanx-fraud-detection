# Docker, Terraform y gcloud — explicado para el equipo

Este documento es para que cualquiera del equipo (sin experiencia previa con
Docker) entienda qué se agregó al proyecto en esta ronda de cambios, por
qué, y cómo encajan estas piezas entre sí. No repite lo que ya está en los
demás README — es la capa de "por qué" y "cómo se relacionan las
herramientas".

## Los conceptos, de cero

### Docker: imagen, contenedor, Dockerfile

- **`Dockerfile`**: una receta de texto. Dice "parte de esta base, instala
  estas dependencias, copia este código, y al final corre este comando".
  Es solo un archivo de texto plano, no ejecuta nada por sí mismo.
- **Imagen**: el resultado de "cocinar" esa receta — un paquete que incluye
  Python, las librerías, y el código, listo para correr igual en cualquier
  máquina (tu laptop, un servidor de Google, la del profesor).
- **Contenedor**: una imagen *corriendo*. Es la diferencia entre una receta
  (Dockerfile), la comida ya preparada y empacada (imagen), y el plato
  servido en la mesa (contenedor).

El problema real que resuelve: sin esto, cada persona necesita instalar
exactamente las mismas versiones de Python, pandas, etc. a mano, y "en mi
máquina sí funciona" es un problema constante. Con Docker, se arma una sola
vez y corre igual en todos lados.

### Artifact Registry — NO es git/GitHub

Es una bodega **privada, dentro de tu propio proyecto de GCP**, donde se
guardan las imágenes ya armadas. No tiene commits, no tiene autores, no
tiene "contribuidores" — es un almacén de paquetes binarios, no un
repositorio de código fuente. Nadie fuera de tu proyecto GCP puede verlo. Es
un nombre desafortunadamente parecido a "repositorio de git", pero es un
concepto completamente distinto.

### Cloud Build

El servicio de GCP que efectivamente "cocina la receta" — toma el
`Dockerfile` y el código, arma la imagen, y la deja en Artifact Registry.
Corre en los servidores de Google, nunca en tu laptop.

### gcloud

La herramienta de línea de comandos para hablar con GCP directamente —
crear recursos, disparar un build, ejecutar un Job, consultar logs. Es el
"cocinero" que ejecuta órdenes puntuales.

### Terraform — el gerente, no el cocinero

Terraform no cocina nada él mismo. Es el plan maestro que describe **qué**
debe existir (una base de datos, un tópico de Pub/Sub, una imagen de
Docker, un Cloud Run Job), y cuando corres `terraform apply`, Terraform
revisa qué falta y llama a las herramientas necesarias por debajo —
incluyendo `gcloud builds submit` para construir imágenes, exactamente como
ya hacía para el frontend de María, y ahora también para el generador.

Analogía completa: **Docker es la receta, gcloud es el cocinero, Terraform
es el gerente del restaurante** que decide cuándo se cocina cada plato y
qué queda en el menú.

### Cloud Run: Service vs. Job

- **Service** (lo que ya existía, el frontend de María): queda corriendo
  indefinidamente, esperando peticiones web (como un mesero siempre
  disponible).
- **Job** (lo nuevo, el generador): corre una tarea de principio a fin y
  termina — no atiende peticiones. Es lo que le conviene al generador,
  que simula transacciones durante un rato y para.

## Qué se agregó en esta ronda de cambios (changelog explicado)

### 1. Cloud SQL y Pub/Sub ahora los crea Terraform (antes: manuales)

Antes, la instancia de Cloud SQL y el tópico de Pub/Sub se habían creado a
mano en la consola de GCP (Sprint 0), y Terraform solo los "miraba"
(`data source`) sin poder crearlos ni borrarlos. Esto significaba que si el
profesor clonaba el repo en un proyecto GCP nuevo, `terraform apply`
fallaría — esos recursos no existirían.

Ahora Terraform los crea, actualiza y destruye él mismo
(`resource` en vez de `data`), incluyendo habilitar las APIs necesarias.
Un proyecto GCP vacío puede levantar todo desde cero con `deploy.sh`.

Efecto secundario importante: `destroy.sh` ahora sí borra la base de datos
de verdad (antes no podía, porque no era dueño de ella).

### 2. El CSV ya no hay que descargarlo a mano de Kaggle

El dataset (`fraudTrain.csv`, 1.29M filas) se subió **una sola vez** a un
bucket público nuestro (`gs://neobanx-fraud-detection-datasets`). El código
del generador (`Backend/generador/main.py`) ahora revisa si el archivo ya
está local, y si no, lo descarga automáticamente desde esa URL pública. Ni
tú, ni un compañero, ni el profesor necesitan cuenta de Kaggle.

### 3. El generador se puede correr como Cloud Run Job (dockerizado)

Se agregaron `Backend/generador/Dockerfile` y `Backend/generador/.gcloudignore`
(este último evita que el CSV de 350MB se suba por accidente cada vez que
se reconstruye la imagen — sin él, cada build subiría el dataset completo
a Cloud Build, gastando tiempo y créditos sin necesidad).

En `Infrastructure/main.tf` se agregó: un repositorio de Artifact Registry
para el generador, la construcción automática de su imagen, y el Cloud Run
Job (`neobanx-generador`). El Job **no se ejecuta solo** en cada
`terraform apply` — correrlo es una acción aparte, a propósito (una corrida
sin acotar tomaría ~60 días y de todas formas excede el límite de 24h por
tarea que tienen los Cloud Run Jobs).

### 4. Lectura del CSV por bloques (no todo en memoria)

La primera vez que se corrió el Job, falló por quedarse sin memoria: cargar
el CSV completo (350MB en disco, bastante más una vez en memoria como
tabla) no cabía en el límite por defecto del contenedor. En vez de subirle
la memoria asignada (que cuesta más), se cambió `main.py` para leer el CSV
**por bloques** (chunks de 50,000 filas), filtrando por fecha bloque por
bloque — así nunca se tiene el archivo completo en memoria, sin importar
qué tan grande sea. Esto es más barato y más correcto que simplemente
darle más recursos al contenedor.

### 5. `scripts/test.sh` — prueba funcional automatizada

Dispara el Cloud Run Job con una ventana corta (30 transacciones, ~30
segundos), espera a que termine, y confirma en BigQuery que llegaron con su
veredicto. Es justo lo que el profesor pedía: un script que pruebe el
sistema funcionalmente, sin intervención manual.

### 6. Nueva variable `generator_salt`

El salt para el hash de tarjetas (`GENERATOR_SALT`) ahora también se pasa a
Terraform (antes solo se usaba localmente), para que el Cloud Run Job lo
reciba como variable de entorno. Se agregó a `variables.tf` y a
`scripts/bootstrap.sh`, siguiendo el mismo patrón que ya existía para
`db_password`.

## Cómo correr todo esto

Ver [GUIA_DESPLIEGUE.md](../GUIA_DESPLIEGUE.md) en la raíz del repo — es el
paso a paso completo, desde clonar hasta ver las transacciones.

## Qué queda pendiente (no se hizo en esta ronda)

- Cargar el perfil de clientes del CSV (nombre, dirección, trabajo, etc.) a
  la tabla `clientes` de Cloud SQL — hoy solo tiene un registro de prueba.
  Es un ETL aparte, ya identificado, no implementado todavía.
- Todo lo demás que ya estaba documentado como pendiente en
  `Infrastructure/README.md` (Spark Structured Streaming, Redis, modelo de
  ML real) sigue igual, sin cambios de esta ronda.
