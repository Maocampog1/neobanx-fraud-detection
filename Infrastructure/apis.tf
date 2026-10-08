// ============================================================================
// APIs de Google Cloud
// ============================================================================
//
// En el Sprint 1 cada API era un `resource` suelto y tres de ellas
// (artifactregistry, cloudbuild, run) estaban declaradas DOS veces: una como
// recurso propio y otra dentro de un `for_each` llamado run_frontend_deps.
// Terraform lo tolera porque los `google_project_service` son idempotentes,
// pero el plan mostraba recursos duplicados y era fácil olvidar actualizar una
// de las dos copias. Aquí se consolidan en un solo `for_each`.
//
// `disable_on_destroy = false` a propósito: deshabilitar una API al destruir
// puede dejar recursos de otros proyectos del equipo en mal estado y, sobre
// todo, hace que el siguiente `apply` sea mucho más lento (rehabilitar una API
// y esperar su propagación toma varios minutos).

locals {
  apis_requeridas = [
    // Cómputo y despliegue
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "eventarc.googleapis.com",

    // Datos
    "sqladmin.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "datastream.googleapis.com",
    "redis.googleapis.com",
    "dataproc.googleapis.com",

    // Red (necesaria para Private Service Access de Redis y Dataproc)
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",

    // Seguridad y gobernanza
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "dataplex.googleapis.com",
    "datacatalog.googleapis.com",

    // Agente de IA
    "aiplatform.googleapis.com",

    // Observabilidad
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudbilling.googleapis.com",
    // billingbudgets es una API SEPARADA de cloudbilling. Sin ella, crear el
    // presupuesto falla con SERVICE_DISABLED y el mensaje despista hablando
    // del "quota project".
    "billingbudgets.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.apis_requeridas)

  service            = each.value
  disable_on_destroy = false
}
