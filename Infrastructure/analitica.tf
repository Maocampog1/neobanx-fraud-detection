// ============================================================================
// analitica.tf — modelo en estrella en BigQuery (dataset `analitica`)
// ============================================================================
//
// QUÉ CREA
//   1. La API de BigQuery Data Transfer (la de las consultas programadas).
//   2. La tabla analitica.festivos_us, cargada desde Nager.Date.
//   3. La cuenta de servicio sa-analitica, con la que corre la consulta.
//   4. Una consulta programada que reconstruye el modelo en estrella cada
//      15 minutos ejecutando sql/modelo_estrella.sql.
//
// POR QUÉ TERRAFORM NO CREA LAS TABLAS DEL MODELO DIRECTAMENTE
//   Las tablas de hechos y dimensiones leen de `raw`, y Datastream solo crea
//   una tabla en `raw` cuando le llega su primera fila. Justo después de un
//   deploy todavía no hay transacciones, así que crear esas tablas aquí haría
//   fallar el deploy. En cambio, la consulta programada se crea sin depender
//   de `raw`: sus corridas fallan sin daño hasta que entran transacciones, y
//   desde ahí construyen el modelo solas.
//
// POR QUÉ UNA CUENTA DE SERVICIO PROPIA
//   Una consulta programada corre sin nadie presente, así que necesita una
//   identidad. Creada desde Terraform no puede usar la cuenta personal de quien
//   despliega (el API responde "Failed to find a valid credential"), y además
//   no conviene: la consulta dejaría de funcionar si esa persona pierde acceso.
//   sa-analitica solo puede leer/escribir en BigQuery y ejecutar consultas.
//
// Para reconstruirlo al instante (demo): scripts/construir_analitica.sh



resource "google_project_service" "bigquery_data_transfer" {
  service            = "bigquerydatatransfer.googleapis.com"
  disable_on_destroy = false
}

// Al habilitar la API, Google crea su agente de servicio
// (service-<numero>@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com).
// Se espera un momento para que exista antes de darle permisos.
resource "time_sleep" "esperar_api_data_transfer" {
  create_duration = "60s"
  depends_on      = [google_project_service.bigquery_data_transfer]
}

// ---------------------------------------------------------------------------
// Cuenta de servicio de la consulta programada (permisos mínimos)
// ---------------------------------------------------------------------------
resource "google_service_account" "analitica" {
  account_id   = "sa-analitica"
  display_name = "Consulta programada del modelo en estrella"
}

resource "google_project_iam_member" "analitica_roles" {
  for_each = toset([
    "roles/bigquery.dataEditor", // leer raw, escribir analitica
    "roles/bigquery.jobUser",    // ejecutar consultas
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.analitica.email}"
}

// El servicio de Data Transfer necesita poder "hablar en nombre" de
// sa-analitica para ejecutar la consulta con su identidad.
resource "google_service_account_iam_member" "data_transfer_usa_sa_analitica" {
  service_account_id = google_service_account.analitica.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.actual.number}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"

  depends_on = [time_sleep.esperar_api_data_transfer]
}

// ---------------------------------------------------------------------------
// Festivos (Nager.Date) -> analitica.festivos_us
// ---------------------------------------------------------------------------
resource "null_resource" "cargar_festivos" {
  depends_on = [google_bigquery_dataset.analitica]

  triggers = {
    script_hash = filesha256("${path.module}/cargar_festivos.sh")
    dataset     = google_bigquery_dataset.analitica.dataset_id
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]

    environment = {
      PROJECT_ID = var.project_id
      DATASET    = google_bigquery_dataset.analitica.dataset_id
    }

    // `bash`, no `sh`: el script usa `set -o pipefail` (ver el mismo
    // comentario en cloudsql.tf).
    command = "bash ${path.module}/cargar_festivos.sh"
  }
}

// ---------------------------------------------------------------------------
// Consulta programada: reconstruye el modelo en estrella
// ---------------------------------------------------------------------------
resource "google_bigquery_data_transfer_config" "modelo_estrella" {
  display_name         = "neobanx-modelo-estrella"
  location             = var.bq_location
  data_source_id       = "scheduled_query"
  schedule             = "every 15 minutes"
  service_account_name = google_service_account.analitica.email

  // Sin destination_dataset_id a propósito: el script usa DDL
  // (CREATE OR REPLACE TABLE) y define él mismo dónde escribe.
  params = {
    query = file("${path.module}/sql/modelo_estrella.sql")
  }

  depends_on = [
    google_project_iam_member.analitica_roles,
    google_service_account_iam_member.data_transfer_usa_sa_analitica,
    null_resource.cargar_festivos,
  ]
}