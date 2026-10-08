// ============================================================================
// NeobanX — configuración raíz de Terraform
// ============================================================================
//
// La infraestructura está repartida por dominio en archivos separados.
// Terraform lee TODOS los .tf del directorio, así que la división es solo
// organizativa: no cambia el comportamiento, pero hace el código revisable y
// reduce los conflictos de merge (tres personas trabajando sobre el mismo
// repo chocaban constantemente en un main.tf de 400 líneas).
//
//   backend.tf     Estado remoto en GCS
//   apis.tf        APIs de GCP habilitadas
//   secrets.tf     Secret Manager, contraseñas generadas y cuentas de servicio
//   pubsub.tf      Topics, suscripciones y DLQ
//   storage.tf     Buckets
//   cloudsql.tf    Instancia PostgreSQL y aplicación del esquema
//   variables.tf   Entradas
//   outputs.tf     Salidas (nombres de recursos para el resto del equipo)
//
// Pendientes del Sprint 2 (se agregan en su propio archivo):
//   network.tf     Private Service Access y Cloud NAT
//   redis.tf       Memorystore
//   dataproc.tf    Clúster con Flink
//   bigquery.tf    Datasets y Datastream
//   monitoring.tf  Alertas y presupuesto
//   run.tf         Servicios de Cloud Run (registro, cierre, frontend, generador)
// ============================================================================

terraform {
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  // POR QUÉ HACEN FALTA ESTAS DOS LÍNEAS
  //
  // Algunas APIs (billingbudgets entre ellas) exigen un "quota project"
  // explícito cuando se autentica con credenciales de usuario (ADC) en lugar
  // de una cuenta de servicio. Sin esto, la llamada se atribuye al proyecto
  // genérico del cliente de gcloud (764086051850) en vez de al nuestro, y
  // falla con un 403 SERVICE_DISABLED cuyo mensaje despista: habla del quota
  // project aunque la API sí esté habilitada en nuestro proyecto.
  //
  // `user_project_override` le dice al provider que use `billing_project` como
  // proyecto de cuota en esas llamadas.
  billing_project       = var.project_id
  user_project_override = true
}
