// ============================================================================
// Cloud Storage
// ============================================================================
//
// El bucket del estado de Terraform (`neobanx-fraud-detection-tfstate`) NO se
// declara aquí: tiene que existir antes de que Terraform pueda inicializarse
// con él como backend. Se creó una sola vez a mano; los comandos están
// documentados en backend.tf.
//
// El bucket de datasets (`neobanx-fraud-detection-datasets`, con los CSV de
// Sparkov) tampoco se gestiona aquí, a propósito: Terraform no debe ser dueño
// del contenido de archivos de ~350 MB que se suben una sola vez. Está
// documentado como paso manual del equipo en Infrastructure/README.md.

// Checkpoints del job de Flink. Flink los usa para poder reanudar exactamente
// donde quedó si el job se reinicia; sin esto, un reinicio reprocesa o pierde
// mensajes.
resource "google_storage_bucket" "flink_checkpoints" {
  name     = "${var.project_id}-flink-checkpoints"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  // Permite destruir el bucket aunque tenga checkpoints dentro: son estado
  // transitorio del job, no datos de negocio.
  force_destroy = true

  // Los checkpoints viejos no sirven para nada y ocupan espacio.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    componente = "flink"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// Mismo par de roles que los buckets de Dataproc: el conector de GCS que usa
// Flink para los checkpoints también consulta los metadatos del bucket.
resource "google_storage_bucket_iam_member" "flink_checkpoints_rw" {
  for_each = toset(["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"])

  bucket = google_storage_bucket.flink_checkpoints.name
  role   = each.value
  member = "serviceAccount:${google_service_account.componentes["flink"].email}"
}

// Staging de los jobs de Dataproc (JAR del job de Flink, scripts de la carga
// batch de perfiles a Redis).
resource "google_storage_bucket" "dataproc_staging" {
  name     = "${var.project_id}-dataproc-staging"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  labels = {
    componente = "dataproc"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// Bucket temporal de Dataproc.
//
// POR QUÉ SE DECLARA EXPLÍCITAMENTE
//
// Si no se le indica un `temp_bucket`, Dataproc crea uno solo con un nombre
// generado del tipo `dataproc-temp-us-central1-1025672131483-kjxjguw7`. Eso
// pasó en el primer despliegue: el bucket quedó huérfano después del
// `terraform destroy`, porque Terraform no era su dueño y por tanto no lo
// borraba. Resultado: basura acumulándose en el proyecto con cada ciclo de
// despliegue, con un nombre que nadie puede rastrear a su origen.
//
// Declarándolo aquí, el destroy se lo lleva junto con todo lo demás.
resource "google_storage_bucket" "dataproc_temp" {
  name     = "${var.project_id}-dataproc-temp"
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  // Los datos temporales de los jobs no sirven para nada pasado un día.
  lifecycle_rule {
    condition {
      age = 2
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    componente = "dataproc"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// Dataproc necesita DOS niveles de permiso sobre sus buckets, y es un detalle
// que cuesta un despliegue fallido descubrir:
//
//   objectAdmin         -> leer y escribir OBJETOS (los JAR, los temporales)
//   legacyBucketReader  -> leer los METADATOS del bucket (storage.buckets.get)
//
// Con solo objectAdmin, la creación del clúster falla con:
//   "missing permissions: [storage.buckets.get] on the staging_bucket"
//
// Se usa legacyBucketReader en lugar de storage.admin para no dar permisos de
// administración (borrar el bucket, cambiar su IAM) a una cuenta que solo
// necesita leer su configuración.
locals {
  roles_bucket_dataproc = ["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]

  buckets_dataproc = {
    staging = google_storage_bucket.dataproc_staging.name
    temp    = google_storage_bucket.dataproc_temp.name
  }

  // Producto cartesiano bucket × rol, con claves únicas para el for_each.
  permisos_buckets_dataproc = {
    for par in setproduct(keys(local.buckets_dataproc), local.roles_bucket_dataproc) :
    "${par[0]}|${par[1]}" => {
      bucket = local.buckets_dataproc[par[0]]
      rol    = par[1]
    }
  }
}

resource "google_storage_bucket_iam_member" "dataproc_buckets_rw" {
  for_each = local.permisos_buckets_dataproc

  bucket = each.value.bucket
  role   = each.value.rol
  member = "serviceAccount:${google_service_account.componentes["flink"].email}"
}
