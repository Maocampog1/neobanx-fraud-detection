// ============================================================================
// agente.tf — Asistente de fraude (Google ADK + Gemini en Vertex AI)
// ============================================================================
//
// QUÉ CREA
//   1. La imagen (mismo patrón que run.tf: construir_imagen.sh).
//   2. El servicio `agente` en Cloud Run, con la identidad sa-agente, que ya
//      tiene desde secrets.tf: aiplatform.user (llamar a Gemini),
//      cloudsql.client y la contraseña del rol agente_ro (solo lectura de 3
//      vistas, sin datos personales).
//   3. Permiso para que SOLO sa-frontend lo invoque. El servicio es privado:
//      nadie más puede llamarlo, ni siquiera con el enlace.
//   4. El output `agente_url`.
//
// MODELO
//   Gemini Flash: el más simple y barato que soporta llamadas a herramientas.
//   Si Google retira la versión, se cambia aquí `modelo_agente` y se vuelve a
//   correr deploy.sh (no hay que tocar código).
//
// COSTO: escala 0 -> 1. Cada pregunta cuesta fracciones de centavo en Vertex AI.

locals {
  agente_imagen = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.servicios.repository_id}/agente:latest"
  modelo_agente = "gemini-2.5-flash"
}

// ---------------------------------------------------------------------------
// Imagen
// ---------------------------------------------------------------------------
resource "null_resource" "build_agente" {
  triggers = {
    main_hash         = filesha256("${path.module}/../Backend/agente/main.py")
    herramientas_hash = filesha256("${path.module}/../Backend/agente/herramientas.py")
    guardrails_hash   = filesha256("${path.module}/../Backend/agente/guardrails.py")
    requirements_hash = filesha256("${path.module}/../Backend/agente/requirements.txt")
    dockerfile_hash   = filesha256("${path.module}/../Backend/agente/Dockerfile")
    db_hash           = filesha256("${path.module}/../Backend/common/db_conexion.py")
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    command     = "'${path.module}/construir_imagen.sh' agente Backend/agente/Dockerfile '${local.agente_imagen}'"
  }

  depends_on = [google_artifact_registry_repository.servicios]
}

// ---------------------------------------------------------------------------
// Servicio
// ---------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "agente" {
  name     = "agente"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.componentes["agente"].email
    timeout         = "120s"

    // Una sola instancia: las conversaciones (sesiones de ADK) viven en
    // memoria, así una pregunta de seguimiento llega al mismo servidor.
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = local.agente_imagen

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = var.region
      }
      env {
        name  = "GOOGLE_GENAI_USE_VERTEXAI"
        value = "TRUE"
      }
      env {
        name  = "MODELO_AGENTE"
        value = local.modelo_agente
      }
      env {
        name  = "DB_USER"
        value = "agente_ro"
      }
      env {
        name  = "DB_NAME"
        value = google_sql_database.neobanx.name
      }
      env {
        name  = "INSTANCE_CONNECTION_NAME"
        value = google_sql_database_instance.transaccional.connection_name
      }
      env {
        name  = "DB_PASSWORD_SECRET"
        value = google_secret_manager_secret.roles_db["agente_ro"].secret_id
      }
      env {
        name  = "IMAGEN_VERSION"
        value = null_resource.build_agente.id
      }
    }
  }

  deletion_protection = false

  depends_on = [null_resource.build_agente]
}

// Solo el frontend puede hacerle preguntas al agente.
resource "google_cloud_run_v2_service_iam_member" "frontend_invoca_agente" {
  project  = var.project_id
  location = google_cloud_run_v2_service.agente.location
  name     = google_cloud_run_v2_service.agente.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.componentes["frontend"].email}"
}

output "agente_url" {
  value = google_cloud_run_v2_service.agente.uri
}