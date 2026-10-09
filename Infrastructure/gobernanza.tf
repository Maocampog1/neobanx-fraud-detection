// ============================================================================
// gobernanza.tf — clasificación de PII con policy tags (control por columna)
// ============================================================================
//
// QUÉ CREA
//   - Una taxonomía de Data Catalog con dos policy tags:
//       PII_alta            -> datos personales directos (nombre, fecha de
//                              nacimiento, ocupación, ubicación del hogar...)
//       Cuasi_identificador -> no identifican solos, sí combinados (ciudad,
//                              código postal). Ver reglas_calidad_neobanx.md, §6.
//   - Quién ve qué en raw.public_clientes:
//       sa-analitica y Datastream -> datos reales (FineGrainedReader)
//       cualquier otra cuenta     -> ACCESO DENEGADO a esas columnas
//
// POR QUÉ NO HAY ENMASCARAMIENTO DINÁMICO
//   Las "data policies" de BigQuery (maskedReader) exigen que el proyecto
//   pertenezca a una organización (Workspace / Cloud Identity). Este proyecto
//   es de una cuenta personal, así que la API responde:
//     "The project needs to belong to an organization to manage DataPolicies."
//   En su lugar se enmascara de forma ESTÁTICA en el pipeline: la consulta
//   programada (sa-analitica, que sí puede leer la PII) genera
//   analitica.clientes_enmascarados con los datos generalizados
//   (ver sql/modelo_estrella.sql). Esa es la capa que consume el equipo.
//
// CÓMO SE APLICAN LOS TAGS A LAS COLUMNAS
//   raw.public_clientes la crea Datastream, no Terraform, y solo existe tras
//   la carga inicial. Por eso las etiquetas se pegan a las columnas con
//   scripts/aplicar_policy_tags.sh, que corre construir_analitica.sh.

locals {
  // La taxonomía debe estar en la misma ubicación que los datasets (US -> us).
  region_gobernanza = lower(var.bq_location)

  lectores_datos_reales = {
    analitica  = "serviceAccount:${google_service_account.analitica.email}"
    datastream = "serviceAccount:service-${data.google_project.actual.number}@gcp-sa-datastream.iam.gserviceaccount.com"
  }
}

// La API de data policies se habilitó en un intento anterior. Ya no se usa:
// este bloque le dice a Terraform que la deje de administrar SIN apagarla,
// para que el plan no muestre un "destroy".
removed {
  from = google_project_service.bigquery_datapolicy

  lifecycle {
    destroy = false
  }
}

// ---------------------------------------------------------------------------
// Taxonomía y etiquetas
// ---------------------------------------------------------------------------
resource "google_data_catalog_taxonomy" "pii" {
  region                 = local.region_gobernanza
  display_name           = "neobanx-clasificacion-pii"
  description            = "Clasificación de datos personales (Ley 1581 de 2012)."
  activated_policy_types = ["FINE_GRAINED_ACCESS_CONTROL"]

  depends_on = [google_project_service.apis]
}

resource "google_data_catalog_policy_tag" "pii_alta" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "PII_alta"
  description  = "Identifica directamente a una persona: nombre, apellido, género, ocupación, fecha de nacimiento, ubicación del hogar."
}

resource "google_data_catalog_policy_tag" "cuasi_identificador" {
  taxonomy     = google_data_catalog_taxonomy.pii.id
  display_name = "Cuasi_identificador"
  description  = "No identifica sola, pero sí combinada con otros datos: ciudad, código postal."
}

// ---------------------------------------------------------------------------
// Quién lee los datos reales (nadie más)
// ---------------------------------------------------------------------------
resource "google_data_catalog_policy_tag_iam_member" "lectores_pii_alta" {
  for_each   = local.lectores_datos_reales
  policy_tag = google_data_catalog_policy_tag.pii_alta.name
  role       = "roles/datacatalog.categoryFineGrainedReader"
  member     = each.value
}

resource "google_data_catalog_policy_tag_iam_member" "lectores_cuasi" {
  for_each   = local.lectores_datos_reales
  policy_tag = google_data_catalog_policy_tag.cuasi_identificador.name
  role       = "roles/datacatalog.categoryFineGrainedReader"
  member     = each.value
}

// Lo leen los scripts de scripts/ (aplicar_policy_tags.sh, construir_analitica.sh).
output "gobernanza" {
  value = {
    policy_tag_pii_alta = google_data_catalog_policy_tag.pii_alta.name
    policy_tag_cuasi    = google_data_catalog_policy_tag.cuasi_identificador.name
    consulta_programada = google_bigquery_data_transfer_config.modelo_estrella.name
  }
}