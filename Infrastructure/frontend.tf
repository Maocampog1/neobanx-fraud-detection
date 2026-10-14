// ============================================================================
// frontend.tf — Frontend de demo (Streamlit en Cloud Run)
// ============================================================================
//
// QUÉ CREA
//   1. La contraseña del login, generada por Terraform y guardada en Secret
//      Manager (nadie la escribe a mano ni circula por chat).
//   2. Los permisos que le faltaban a sa-frontend para generar transacciones
//      desde la página: invocar al servicio de registro y leer la clave HMAC
//      (para tokenizar cc_num igual que el generador). Los de Cloud SQL y
//      BigQuery ya los tiene desde secrets.tf.
//   3. La imagen (mismo patrón que run.tf: construir_imagen.sh) y el servicio
//      de Cloud Run, público en la red pero protegido por el login de la app.
//   4. El output `frontend_url`, que imprime deploy.sh al final.
//
// Para ver la contraseña del login:
//   gcloud secrets versions access latest --secret=neobanx-frontend-login
//
// COSTO: escala 0 -> 1. Sin nadie usando la página, no cobra.

locals {
  frontend_imagen = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.servicios.repository_id}/frontend:latest"
}

// ---------------------------------------------------------------------------
// Login
// ---------------------------------------------------------------------------
resource "random_password" "frontend_login" {
  length  = 20
  special = false
}

resource "google_secret_manager_secret" "frontend_login" {
  secret_id = "neobanx-frontend-login"

  labels = {
    componente = "frontend"
    gestionado = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "frontend_login" {
  secret      = google_secret_manager_secret.frontend_login.id
  secret_data = random_password.frontend_login.result
}

// ---------------------------------------------------------------------------
// Permisos adicionales de sa-frontend (a nivel de recurso, no de proyecto)
// ---------------------------------------------------------------------------
resource "google_secret_manager_secret_iam_member" "frontend_lee_login" {
  secret_id = google_secret_manager_secret.frontend_login.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.componentes["frontend"].email}"
}

resource "google_secret_manager_secret_iam_member" "frontend_lee_hmac" {
  secret_id = google_secret_manager_secret.hmac_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.componentes["frontend"].email}"
}

// Solo puede invocar el servicio de registro, no cualquier Cloud Run.
resource "google_cloud_run_v2_service_iam_member" "frontend_invoca_registro" {
  project  = var.project_id
  location = google_cloud_run_v2_service.registro.location
  name     = google_cloud_run_v2_service.registro.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.componentes["frontend"].email}"
}

// ---------------------------------------------------------------------------
// Imagen
// ---------------------------------------------------------------------------
resource "null_resource" "build_frontend" {
  triggers = {
    app_hash          = filesha256("${path.module}/../Frontend/app.py")
    requirements_hash = filesha256("${path.module}/../Frontend/requirements.txt")
    dockerfile_hash   = filesha256("${path.module}/../Frontend/Dockerfile")
    db_hash           = filesha256("${path.module}/../Backend/common/db_conexion.py")
    hmac_hash         = filesha256("${path.module}/../Backend/common/hmac_util.py")
    contratos_hash    = filesha256("${path.module}/../contracts/transaccion.py")
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    command     = "'${path.module}/construir_imagen.sh' frontend Frontend/Dockerfile '${local.frontend_imagen}'"
  }

  depends_on = [google_artifact_registry_repository.servicios]
}

// ---------------------------------------------------------------------------
// Servicio
// ---------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "frontend" {
  name     = "frontend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.componentes["frontend"].email

    // Streamlit mantiene la sesión en memoria por conexión (websocket): con
    // una sola instancia y afinidad de sesión, la página nunca cambia de
    // servidor a mitad de la demo, y hay un único generador a la vez.
    session_affinity = true
    timeout          = "3600s"

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      image = local.frontend_imagen

      resources {
        // 2Gi: el CSV completo (~555 mil filas, 9 columnas) se carga en memoria
        // para filtrar por fecha al instante. CPU siempre asignada mientras la
        // instancia vive: el generador corre en un hilo de fondo.
        limits = {
          cpu    = "1"
          memory = "2Gi"
        }
        cpu_idle = false
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "REGISTRO_URL"
        value = google_cloud_run_v2_service.registro.uri
      }
      env {
        name  = "DB_USER"
        value = "frontend_ro"
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
        value = google_secret_manager_secret.roles_db["frontend_ro"].secret_id
      }
      env {
        name  = "LOGIN_SECRET"
        value = google_secret_manager_secret.frontend_login.secret_id
      }
      env {
        name  = "FRONTEND_USUARIO"
        value = "neobanx"
      }
            // Asistente de fraude (agente.tf). Es privado: sa-frontend lo invoca
      // con un token de identidad, igual que al servicio de registro.
      env {
        name  = "AGENTE_URL"
        value = google_cloud_run_v2_service.agente.uri
      }
      // Cambia cada vez que se reconstruye la imagen: obliga a Cloud Run a
      // crear una revisión nueva (la etiqueta :latest por sí sola no lo hace).
      env {
        name  = "IMAGEN_VERSION"
        value = null_resource.build_frontend.id
      }
    }
  }

  deletion_protection = false

    depends_on = [
    null_resource.build_frontend,
    google_secret_manager_secret_version.frontend_login,
    google_secret_manager_secret_iam_member.frontend_lee_login,
    google_secret_manager_secret_iam_member.frontend_lee_hmac,
    google_cloud_run_v2_service_iam_member.frontend_invoca_registro,
    google_cloud_run_v2_service_iam_member.frontend_invoca_agente,
  ]
}

// Cualquiera con el enlace puede abrir la página; los datos los protege el
// login de la app (y por debajo, frontend_ro solo puede leer).
resource "google_cloud_run_v2_service_iam_member" "frontend_publico" {
  project  = var.project_id
  location = google_cloud_run_v2_service.frontend.location
  name     = google_cloud_run_v2_service.frontend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

// Lo imprime scripts/deploy.sh al terminar.
output "frontend_url" {
  value = google_cloud_run_v2_service.frontend.uri
}