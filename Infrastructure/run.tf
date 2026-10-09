// ============================================================================
// run.tf — Cloud Run: registro, cierre, stub de veredicto
// ============================================================================
//
// Build: cada servicio se construye y publica con `gcloud builds submit`
// (via construir_imagen.sh -- ver ese archivo para por que hace falta un
// cloudbuild.yaml inline en vez de `--tag` directo). El trigger de cada
// null_resource es un hash del codigo fuente relevante: Terraform solo
// reconstruye la imagen cuando el codigo cambia, no en cada apply.
//
// Costo: `registro` escala 0->N (sin trafico, sin costo). `cierre` y
// `stub_veredicto` son *workers* persistentes (min_instance_count=1): cobran
// todo el tiempo que esten desplegados, tengan trafico o no. Apagarlos o
// destruirlos en cuanto termine la sesion de pruebas (ver
// Documentation/sprint2_progreso_juan.md, "Fase nube - sesion 1").

resource "google_artifact_registry_repository" "servicios" {
  repository_id = "neobanx-servicios"
  format        = "DOCKER"
  location      = var.region

  depends_on = [google_project_service.apis]
}

locals {
  registro_imagen = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.servicios.repository_id}/registro:latest"
  cierre_imagen   = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.servicios.repository_id}/cierre:latest"
  stub_imagen     = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.servicios.repository_id}/stub-veredicto:latest"
}

// ---------------------------------------------------------------------------
// Build de las 3 imagenes
// ---------------------------------------------------------------------------

resource "null_resource" "build_registro" {
  triggers = {
    main_hash         = filesha256("${path.module}/../Backend/registro/main.py")
    requirements_hash = filesha256("${path.module}/../Backend/registro/requirements.txt")
    dockerfile_hash   = filesha256("${path.module}/../Backend/registro/Dockerfile")
    comun_hash        = filesha256("${path.module}/../Backend/common/db_conexion.py")
    contratos_hash    = filesha256("${path.module}/../contracts/transaccion.py")
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    command     = "'${path.module}/construir_imagen.sh' registro Backend/registro/Dockerfile '${local.registro_imagen}'"
  }

  depends_on = [google_artifact_registry_repository.servicios]
}

resource "null_resource" "build_cierre" {
  triggers = {
    main_hash         = filesha256("${path.module}/../Backend/cierre/main.py")
    requirements_hash = filesha256("${path.module}/../Backend/cierre/requirements.txt")
    dockerfile_hash   = filesha256("${path.module}/../Backend/cierre/Dockerfile")
    comun_hash        = filesha256("${path.module}/../Backend/common/db_conexion.py")
    contratos_hash    = filesha256("${path.module}/../contracts/veredicto.py")
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    command     = "'${path.module}/construir_imagen.sh' cierre Backend/cierre/Dockerfile '${local.cierre_imagen}'"
  }

  depends_on = [google_artifact_registry_repository.servicios]
}

resource "null_resource" "build_stub_veredicto" {
  triggers = {
    main_hash         = filesha256("${path.module}/../Backend/stub_veredicto/main.py")
    requirements_hash = filesha256("${path.module}/../Backend/stub_veredicto/requirements.txt")
    dockerfile_hash   = filesha256("${path.module}/../Backend/stub_veredicto/Dockerfile")
    contratos_hash    = filesha256("${path.module}/../contracts/transaccion.py")
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    command     = "'${path.module}/construir_imagen.sh' stub_veredicto Backend/stub_veredicto/Dockerfile '${local.stub_imagen}'"
  }

  depends_on = [google_artifact_registry_repository.servicios]
}

// ---------------------------------------------------------------------------
// registro — escala 0->N, sin trafico no cobra
// ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "registro" {
  name     = "registro"
  location = var.region

  template {
    service_account = google_service_account.componentes["registro"].email

    containers {
      image = local.registro_imagen

      env {
        name  = "DB_USER"
        value = "app_registro"
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
        value = google_secret_manager_secret.roles_db["app_registro"].secret_id
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "TOPIC_PRESELECCIONADAS"
        value = google_pubsub_topic.preseleccionadas.name
      }
      env {
        name  = "TIMEOUT_VEREDICTO_SEGUNDOS"
        value = tostring(var.timeout_veredicto_segundos)
      }
      env {
        name  = "UMBRAL_MONTO_PRESELECCION"
        value = tostring(var.umbral_monto_preseleccion)
      }
      env {
        name  = "PROBABILIDAD_MUESTREO"
        value = tostring(var.probabilidad_muestreo)
      }
    }
  }

  deletion_protection = false

  depends_on = [null_resource.build_registro]
}

// ---------------------------------------------------------------------------
// cierre — worker persistente (min_instance_count=1): cobra siempre
// ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "cierre" {
  name     = "cierre"
  location = var.region

  template {
    service_account = google_service_account.componentes["cierre"].email

    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = local.cierre_imagen

      resources {
        // CPU siempre asignada: es un worker con dos loops en background, no
        // puede depender de recibir requests para que Cloud Run le de CPU.
        //
        // `limits` explicito a proposito: con un bloque `resources` que solo
        // traia cpu_idle = false, la revision se desplegaba SIN CPU siempre
        // asignada (confirmado el 2026-10-09: la anotacion
        // run.googleapis.com/cpu-throttling no aparecia, el stub no procesaba
        // ningun mensaje y cierre iba con minutos de retraso, asi que todas
        // las preseleccionadas terminaban en timeout). Con los limits
        // declarados, la configuracion se envia completa. Los valores son los
        // mismos que Cloud Run asigna por defecto (1 CPU, 512Mi).
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = false
      }

      env {
        name  = "DB_USER"
        value = "app_cierre"
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
        value = google_secret_manager_secret.roles_db["app_cierre"].secret_id
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "SUBSCRIPTION_VEREDICTOS"
        value = google_pubsub_subscription.cierre_veredictos.name
      }
      env {
        name  = "MONITOR_INTERVALO_SEGUNDOS"
        value = "10"
      }
    }
  }

  deletion_protection = false

  depends_on = [null_resource.build_cierre]
}

// ---------------------------------------------------------------------------
// stub_veredicto — worker persistente, temporal hasta que Flink este listo
// ---------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "stub_veredicto" {
  name     = "stub-veredicto"
  location = var.region

  template {
    service_account = google_service_account.componentes["stub"].email

    scaling {
      min_instance_count = 1
      max_instance_count = 1
    }

    containers {
      image = local.stub_imagen

      resources {
        // Mismo motivo que en cierre: sin `limits` explicitos, cpu_idle = false
        // no llegaba a la revision desplegada y el stub no procesaba mensajes.
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = false
      }

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "SUBSCRIPTION_PRESELECCIONADAS"
        value = google_pubsub_subscription.stub_preseleccionadas.name
      }
      env {
        name  = "TOPIC_VEREDICTOS"
        value = google_pubsub_topic.veredictos.name
      }
      env {
        name  = "RETRASO_SEGUNDOS"
        value = "0"
      }
    }
  }

  deletion_protection = false

  depends_on = [null_resource.build_stub_veredicto]
}