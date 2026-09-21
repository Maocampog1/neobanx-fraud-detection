# Backend — NeobanX

Dos componentes:

- `generador/` — script Python que lee `fraudTrain.csv`, lo ordena por
  `trans_date_trans_time` y publica una transaccion cada 4 segundos al
  topico Pub/Sub `transacciones-neobanx` (responsable: Juanes). **Probado
  end-to-end** contra el proyecto real: 268 transacciones publicadas
  (ventana 2019-02-25 22:00–00:00), 28 fraudes verificados en
  `raw.transacciones_raw`.
- `consumidor/` — Cloud Function que consume `transacciones-neobanx-sub` y
  carga cada mensaje en BigQuery Raw (responsable: Larry, ya desplegada).

## Contrato de datos del mensaje publicado

Detalle completo con las razones de cada campo en
[`contrato_datos_generador.md`](contrato_datos_generador.md). Resumen:

Cada mensaje en `transacciones-neobanx` es un JSON con exactamente estos 9
campos, en ingles, sin campos extra ni faltantes:

```json
{
  "trans_num": "0b242abb623afc578575680df30655b9",
  "cc_num_hash": "80923ef013",
  "merchant": "fraud_Rippin, Kub and Mann",
  "category": "misc_net",
  "amt": 4.97,
  "trans_date_trans_time": "2019-01-01T00:00:18",
  "merch_lat": 36.011293,
  "merch_long": -82.048315,
  "is_fraud": 0
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `trans_num` | string | llave de deduplicacion/idempotencia, obligatoria |
| `cc_num_hash` | string | `sha256(salt + cc_num)` truncado a 10 hex; `cc_num` nunca sale en texto plano |
| `merchant` | string | tal cual el CSV |
| `category` | string | tal cual el CSV |
| `amt` | float | sin formatear ni simbolo de moneda |
| `trans_date_trans_time` | string ISO 8601 | usar siempre esta columna, **nunca** `unix_time` (desfase de ~7 anios) |
| `merch_lat` / `merch_long` | float | tal cual el CSV |
| `is_fraud` | int (0/1) | solo para validar el pipeline durante el sprint |

Campos de perfil del cliente (`first`, `last`, `gender`, `street`, `city`,
`state`, `zip`, `lat`, `long`, `city_pop`, `job`, `dob`) no van en este
mensaje — ya estan precargados en la tabla `clientes` de Cloud SQL.

El consumidor agrega un campo mas al insertar en BigQuery, `veredicto`
(`aprobada`/`alerta`), calculado con una regla baseline simple (monto +
categoria) — no viene del generador ni es un modelo entrenado, es un
placeholder hasta que exista el flujo de Spark Structured Streaming.

## Generador — dos formas de correrlo

**No hace falta descargar `fraudTrain.csv` de Kaggle** — el generador lo
descarga solo la primera vez que corre, desde un bucket público
(`gs://neobanx-fraud-detection-datasets/fraudTrain.csv`, subido una única
vez por el equipo). Si ya tienes el archivo en
`Backend/generador/data/fraudTrain.csv`, lo usa tal cual sin descargar
nada.

### Opción A — Cloud Run Job (recomendado, no requiere Python local)

Terraform ya deja el Job `neobanx-generador` listo (construido vía Docker +
Cloud Build). Para una prueba corta y automática:

```bash
./scripts/test.sh
```

Para una corrida con tu propia ventana de fechas, sin tocar el `.env`:

```bash
gcloud run jobs execute neobanx-generador --region=us-central1 --project=neobanx-fraud-detection \
  --update-env-vars="FECHA_INICIO=2019-02-25 22:00:00,FECHA_FIN=2019-02-26 00:00:00,MAX_FILAS=268,INTERVALO_SEGUNDOS=4"
```

Detalle de por qué está dockerizado así (Docker, Terraform, Cloud Run Job)
en [`Documentation/docker_terraform_explicado.md`](../Documentation/docker_terraform_explicado.md).

### Opción B — uso local (para desarrollo/debug)

1. Autenticarse: `gcloud auth application-default login`
2. Instalar dependencias:
   ```powershell
   cd Backend/generador
   pip install -r requirements.txt
   ```
3. Definir el salt del hash (no se versiona):
   ```powershell
   $env:GENERATOR_SALT = "<tu-salt>"
   ```

   ⚠️ **Pendiente:** `Documentation/reglas_calidad_neobanx.md` ya especifica
   la tecnica correcta para `cc_num_hash` — HMAC-SHA256 con una clave secreta
   fija guardada en Secret Manager (un salt aleatorio por registro, como usa
   `hash_cc_num` hoy, no sirve porque el hash tiene que ser determinista para
   que el join con `clientes.cc_num_hash` funcione). Falta migrar
   `hash_cc_num` a esa tecnica y crear el secreto en Secret Manager. Mientras
   tanto, `clientes.cc_num_hash` en Cloud SQL solo tiene un valor de prueba
   (`abc123hash`), asi que cualquier salt local sirve para probar el
   generador de forma aislada sin romper nada.
4. Ejecutar:
   ```powershell
   python main.py
   ```

   El CSV completo tiene ~1.3M filas; a 4s/mensaje tomaria ~60 dias. Para
   pruebas rapidas o para acotar la prueba de carga, usa las variables
   opcionales `MAX_FILAS`, `FECHA_INICIO` y `FECHA_FIN` (acepta fecha u hora,
   ej. `2019-01-01` o `2019-01-01 08:00:00`), aplicadas sobre el CSV ya
   ordenado cronologicamente:

   ```powershell
   $env:FECHA_INICIO = "2019-01-01"
   $env:FECHA_FIN = "2019-01-02"
   $env:MAX_FILAS = "100"
   python main.py
   ```

   El fraude es solo ~0.58% de las filas en promedio, asi que una ventana
   corta al azar puede no traer ningun caso. `explorar_fraude.py` busca los
   dias y bloques de 2h con mas fraudes reales, para acotar a una ventana
   corta que si tenga varios casos que verificar:

   ```powershell
   python explorar_fraude.py
   ```

   (ej. `2019-02-25 22:00:00` a `2019-02-26 00:00:00` trae 268 transacciones
   con 28 fraudes reales, ~18 minutos a la cadencia real de 4s).
5. Verificar en Cloud Shell que los mensajes llegan:
   ```bash
   gcloud pubsub subscriptions pull transacciones-neobanx-sub --limit=5 --auto-ack
   ```

### Integracion con Nager.Date

`holidays.py` expone `es_festivo(fecha) -> bool`, consultando
`https://date.nager.at/api/v3/PublicHolidays/{anio}/CO` y cacheando el
resultado por anio (una sola llamada HTTP por anio del dataset, no por
transaccion). `main.py` la usa para loguear si cada transaccion cae en
festivo; no se agrega al payload de Pub/Sub porque el contrato de datos fija
exactamente 9 campos — el enriquecimiento con festivo ocurre mas adelante en
el flujo de Spark Structured Streaming.

Prueba rapida aislada:

```powershell
python holidays.py
```
