// ============================================================================
// calidad.tf — reglas de calidad programadas -> analitica.dq_resultados
// ============================================================================
//
// Una segunda consulta programada, separada del modelo en estrella, que corre
// sql/calidad.sql cada 15 minutos. Reusa la cuenta sa-analitica y sus permisos
// (analitica.tf): puede leer las columnas con policy tag que la regla R4
// necesita, y solo publica conteos.
//
// Por qué separada del modelo: si una regla falla o la tabla de calidad tiene
// un problema, el modelo en estrella sigue construyéndose, y viceversa.
//
// Para correrla al instante (demo): scripts/correr_calidad.sh

resource "google_bigquery_data_transfer_config" "calidad" {
  display_name         = "neobanx-calidad-datos"
  location             = var.bq_location
  data_source_id       = "scheduled_query"
  schedule             = "every 15 minutes"
  service_account_name = google_service_account.analitica.email

  // Sin destination_dataset_id: el script escribe con DDL/DML explícito.
  params = {
    query = file("${path.module}/sql/calidad.sql")
  }

  depends_on = [
    google_project_iam_member.analitica_roles,
    google_service_account_iam_member.data_transfer_usa_sa_analitica,
  ]
}

// Lo lee scripts/correr_calidad.sh.
output "calidad" {
  value = {
    consulta_programada = google_bigquery_data_transfer_config.calidad.name
  }
}