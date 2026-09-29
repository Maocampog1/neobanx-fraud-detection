# Guía rápida — Desplegar y probar NeobanX de punta a punta

Esta guía es el camino más corto para llegar de "acabo de clonar el repo" a
"veo transacciones reales pasando por el pipeline". Para el detalle de cada
pieza (qué es cada script, qué hace cada recurso de Terraform), ver el
[README.md](README.md) principal y
[Documentation/docker_terraform_explicado.md](Documentation/docker_terraform_explicado.md).

## Antes de empezar

Hay dos formas de correr esta guía. **Se recomienda la vía con Docker**,
porque no requiere instalar nada salvo Docker mismo — ideal para replicar
el despliegue en un proyecto GCP nuevo sin importar el sistema operativo.

### Opción A (recomendada) — Con Docker

- Solo necesitas **Docker** instalado ([docs de instalación](https://docs.docker.com/get-docker/)).
- No necesitas instalar `gcloud`, `terraform`, `psql`, Git Bash, ni Python.
- Acceso a un proyecto GCP (el del equipo, o uno propio nuevo).

Todos los comandos de esta guía tienen su equivalente en Docker — se
muestran juntos en cada paso. La imagen de herramientas
(`Infrastructure/Dockerfile`) trae `terraform`, `gcloud` CLI y `psql` ya
instalados; nunca contiene código de la app ni credenciales.

Constrúyela una vez, desde la raíz del repo:

```powershell
docker build -t neobanx-deploy -f Infrastructure/Dockerfile .
```

Crea también, una sola vez, el volumen donde va a persistir tu sesión de
`gcloud` entre ejecuciones del contenedor (se llama `neobanx-gcloud-config`,
vive solo en tu máquina, aislado del de cualquier otra persona):

```powershell
docker volume create neobanx-gcloud-config
```

A partir de aquí, cada comando de esta guía se corre así, montando el
volumen de credenciales y la carpeta del repo (`${PWD}` en PowerShell,
`$(pwd)` en bash/Git Bash/macOS/Linux):

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  neobanx-deploy -c "<comando-a-ejecutar>"
```

En bash/macOS/Linux la única diferencia es la sintaxis de continuación de
línea y la variable de la carpeta actual:

```bash
docker run -it --rm \
  -v neobanx-gcloud-config:/root/.config/gcloud \
  -v $(pwd):/workspace \
  neobanx-deploy -c "<comando-a-ejecutar>"
```

Debajo de cada paso se muestra el `<comando-a-ejecutar>` exacto.

### Opción B — Sin Docker (instalación local)

- `gcloud` CLI, `terraform` >= 1.7, `psql` instalados.
- **Git Bash** en Windows (los scripts `.sh` no corren en PowerShell/CMD).
- Acceso a un proyecto GCP (el del equipo, o uno propio nuevo).
- No hace falta Python localmente ni descargar ningún dataset de Kaggle a
  mano — todo eso lo resuelve lo de abajo.

## Paso 1 — Clonar y configurar

```bash
git clone <url-del-repo>
cd neobanx-fraud-detection
cp .env.example .env
```

Edita `.env` con los valores reales del equipo: `DB_PASSWORD` y
`GENERATOR_SALT` se piden por el documento privado del equipo, nunca por
chat abierto. Este paso es igual con o sin Docker — `.env` vive siempre en
tu carpeta real del repo (con Docker, gracias al volumen `-v ${PWD}:/workspace`,
el contenedor lee y escribe directamente sobre ese mismo archivo, nunca
sobre una copia aislada).

## Paso 2 — Permisos de ejecución (una sola vez por máquina, solo Opción B)

```bash
chmod +x scripts/bootstrap.sh scripts/deploy.sh scripts/destroy.sh scripts/test.sh
```

Con Docker (Opción A) este paso no es necesario — la imagen corre los
scripts con `bash`, sin depender de permisos de ejecución del archivo en
el host.

## Paso 3 — Bootstrap: autentica gcloud y genera `terraform.tfvars`

**Opción B (sin Docker):**

```bash
./scripts/bootstrap.sh
```

Si el login por navegador falla (común en Windows/Git Bash), usa el flujo
manual documentado en el [README.md](README.md#paso-3--bootstrap-autentica-gcloud-y-genera-terraformtfvars-automáticamente).

**Opción A (con Docker):**

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  neobanx-deploy -c "cd /workspace && ./scripts/bootstrap.sh"
```

La primera vez, el script crea `.env` desde `.env.example` y se detiene —
sale del contenedor, edita `.env` en tu editor normal (el archivo ya quedó
en tu disco real gracias al volumen), y vuelve a correr el mismo comando.
Esta segunda vez sí sigue de largo: te pide el login de `gcloud` (se abre
un link para autenticar desde tu navegador normal, aunque el comando corra
dentro del contenedor) y genera `Infrastructure/terraform.tfvars` — ese
archivo también queda en tu disco real, no dentro del contenedor.

Como la sesión de `gcloud` se guarda en el volumen `neobanx-gcloud-config`,
no tienes que volver a autenticarte en los pasos siguientes, ni la próxima
vez que despliegues, mientras la sesión no expire.

## Paso 4 — Desplegar toda la infraestructura

**Opción B (sin Docker):**

```bash
./scripts/deploy.sh --yes
```

**Opción A (con Docker):**

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  neobanx-deploy -c "cd /workspace && ./scripts/deploy.sh --yes"
```

Esto crea (o actualiza) **todo**: BigQuery, la instancia de Cloud SQL, el
tópico/suscripción de Pub/Sub, la Cloud Function consumidora, el frontend de
demo, y el generador dockerizado (construye la imagen en Cloud Build y crea
el Cloud Run Job — sin ejecutarlo todavía). La primera vez tarda varios
minutos porque Cloud SQL y el build de las imágenes toman su tiempo.

> Nota: `deploy.sh` invoca `gcloud builds submit`, que sube el código de
> `Frontend/` y `Backend/generador/` a Cloud Build para construir *esas*
> imágenes (la del frontend y la del generador) — esto es independiente de
> la imagen `neobanx-deploy` de esta guía, que solo contiene las
> herramientas de despliegue, no el código de la app.

## Paso 5 — Probar que el pipeline funciona de punta a punta

**Opción B (sin Docker):**

```bash
./scripts/test.sh
```

**Opción A (con Docker):**

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  neobanx-deploy -c "cd /workspace && ./scripts/test.sh"
```

Esto ejecuta el generador en una ventana corta (30 transacciones, unos
segundos de duración), y confirma automáticamente que llegaron a BigQuery
con su veredicto calculado. Si termina con `OK: ...`, el pipeline completo
(generador → Pub/Sub → Cloud Function → BigQuery) está funcionando.

Para correr una ventana distinta (más transacciones, otro rango de fechas),
sin tocar el `.env`:

**Opción B (sin Docker):**

```bash
TEST_MAX_FILAS=100 TEST_FECHA_INICIO="2019-02-25 22:00:00" TEST_FECHA_FIN="2019-02-26 00:00:00" ./scripts/test.sh
```

**Opción A (con Docker)** — las variables se pasan con `-e` para que
lleguen dentro del contenedor:

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  -e TEST_MAX_FILAS=100 `
  -e TEST_FECHA_INICIO="2019-02-25 22:00:00" `
  -e TEST_FECHA_FIN="2019-02-26 00:00:00" `
  neobanx-deploy -c "cd /workspace && ./scripts/test.sh"
```

## Paso 6 — Ver las transacciones

Cuatro formas, de más visual a más técnica:

1. **Demo en vivo (recomendado)**: abre la URL que imprime `deploy.sh` al
   final (`terraform output frontend_url`) — tabla en vivo con las últimas
   20 transacciones, resaltando en rojo las marcadas como `alerta`.
2. **Consola de Cloud Run**: `console.cloud.google.com` → "Cloud Run" →
   pestaña "Jobs" → `neobanx-generador` → historial de ejecuciones y logs.
3. **Consola de BigQuery**: `console.cloud.google.com` → "BigQuery" → tu
   proyecto → dataset `raw` → tabla `transacciones_raw` → pestaña "Preview".
4. **Por consola**, sin abrir el navegador:
   ```bash
   bq query --project_id=<tu-project-id> --use_legacy_sql=false \
     "SELECT trans_num, merchant, amt, veredicto, ingestion_timestamp FROM \`<tu-project-id>.raw.transacciones_raw\` ORDER BY ingestion_timestamp DESC LIMIT 10"
   ```

## Paso 7 — Terminar (destruir o apagar)

**Opción B (sin Docker):**

```bash
./scripts/destroy.sh          # borra TODO lo gestionado por Terraform, incluida la base de datos
```

**Opción A (con Docker):**

```powershell
docker run -it --rm `
  -v neobanx-gcloud-config:/root/.config/gcloud `
  -v ${PWD}:/workspace `
  neobanx-deploy -c "cd /workspace && ./scripts/destroy.sh"
```

O, si solo quieres pausar sin borrar nada, apaga la instancia de Cloud SQL
(ver [README.md](README.md#paso-5--destruir-toda-la-infraestructura-cuando-termines-de-trabajar)) —
este comando de `gcloud sql instances patch` puedes correrlo igual dentro
del contenedor, reemplazando el `-c "..."` por el comando de esa nota.
