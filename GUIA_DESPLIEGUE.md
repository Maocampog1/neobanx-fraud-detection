# Guía rápida — Desplegar y probar NeobanX de punta a punta

Esta guía es el camino más corto para llegar de "acabo de clonar el repo" a
"veo transacciones reales pasando por el pipeline". Para el detalle de cada
pieza (qué es cada script, qué hace cada recurso de Terraform), ver el
[README.md](README.md) principal y
[Documentation/docker_terraform_explicado.md](Documentation/docker_terraform_explicado.md).

## Antes de empezar

- `gcloud` CLI, `terraform` >= 1.7, `psql` instalados.
- **Git Bash** en Windows (los scripts `.sh` no corren en PowerShell/CMD).
- Acceso a un proyecto GCP (el del equipo, o uno propio nuevo).
- **No hace falta** Docker instalado, ni Python localmente, ni descargar
  ningún dataset de Kaggle a mano — todo eso lo resuelve lo de abajo.

## Paso 1 — Clonar y configurar

```bash
git clone <url-del-repo>
cd neobanx-fraud-detection
cp .env.example .env
```

Edita `.env` con los valores reales del equipo: `DB_PASSWORD` y
`GENERATOR_SALT` se piden por el documento privado del equipo, nunca por
chat abierto.

## Paso 2 — Permisos de ejecución (una sola vez por máquina)

```bash
chmod +x scripts/bootstrap.sh scripts/deploy.sh scripts/destroy.sh scripts/test.sh
```

## Paso 3 — Bootstrap: autentica gcloud y genera `terraform.tfvars`

```bash
./scripts/bootstrap.sh
```

Si el login por navegador falla (común en Windows/Git Bash), usa el flujo
manual documentado en el [README.md](README.md#paso-3--bootstrap-autentica-gcloud-y-genera-terraformtfvars-automáticamente).

## Paso 4 — Desplegar toda la infraestructura

```bash
./scripts/deploy.sh --yes
```

Esto crea (o actualiza) **todo**: BigQuery, la instancia de Cloud SQL, el
tópico/suscripción de Pub/Sub, la Cloud Function consumidora, el frontend de
demo, y el generador dockerizado (construye la imagen en Cloud Build y crea
el Cloud Run Job — sin ejecutarlo todavía). La primera vez tarda varios
minutos porque Cloud SQL y el build de las imágenes toman su tiempo.

## Paso 5 — Probar que el pipeline funciona de punta a punta

```bash
./scripts/test.sh
```

Esto ejecuta el generador en una ventana corta (30 transacciones, unos
segundos de duración), y confirma automáticamente que llegaron a BigQuery
con su veredicto calculado. Si termina con `OK: ...`, el pipeline completo
(generador → Pub/Sub → Cloud Function → BigQuery) está funcionando.

Para correr una ventana distinta (más transacciones, otro rango de fechas),
sin tocar el `.env`:

```bash
TEST_MAX_FILAS=100 TEST_FECHA_INICIO="2019-02-25 22:00:00" TEST_FECHA_FIN="2019-02-26 00:00:00" ./scripts/test.sh
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

```bash
./scripts/destroy.sh          # borra TODO lo gestionado por Terraform, incluida la base de datos
```

O, si solo quieres pausar sin borrar nada, apaga la instancia de Cloud SQL
(ver [README.md](README.md#paso-5--destruir-toda-la-infraestructura-cuando-termines-de-trabajar)).
