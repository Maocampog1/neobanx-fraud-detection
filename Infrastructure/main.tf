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
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- APIs necesarias para el proyecto ---

resource "google_project_service" "cloudfunctions" {
  service            = "cloudfunctions.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudbuild" {
  service            = "cloudbuild.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "eventarc" {
  service            = "eventarc.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

# --- BigQuery: capa Raw ---

resource "google_bigquery_dataset" "raw" {
  dataset_id = "raw"
  location   = "US"
}

resource "google_bigquery_table" "transacciones_raw" {
  dataset_id = google_bigquery_dataset.raw.dataset_id
  table_id   = "transacciones_raw"

  time_partitioning {
    type  = "DAY"
    field = "trans_date_trans_time"
  }

  schema = jsonencode([
    { name = "trans_num", type = "STRING" },
    { name = "cc_num_hash", type = "STRING" },
    { name = "merchant", type = "STRING" },
    { name = "category", type = "STRING" },
    { name = "amt", type = "NUMERIC" },
    { name = "trans_date_trans_time", type = "TIMESTAMP" },
    { name = "merch_lat", type = "FLOAT" },
    { name = "merch_long", type = "FLOAT" },
    { name = "is_fraud", type = "INTEGER" },
    { name = "ingestion_timestamp", type = "TIMESTAMP" },
    { name = "pubsub_message_id", type = "STRING" }
  ])
}

# --- Cloud SQL: base de datos lógica + tablas ---

data "google_sql_database_instance" "transaccional" {
  name = "neobanx-transaccional"
}

resource "google_sql_database" "neobanx" {
  name     = "neobanx"
  instance = data.google_sql_database_instance.transaccional.name
}

resource "null_resource" "aplicar_schema" {
  depends_on = [google_sql_database.neobanx]

  triggers = {
    schema_hash = filesha256("${path.module}/schema.sql")
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    environment = {
      PGPASSWORD = var.db_password
    }
    command = "psql -h ${data.google_sql_database_instance.transaccional.public_ip_address} -p 5432 -U postgres -d ${google_sql_database.neobanx.name} --set=sslmode=require -f schema.sql"
  }
}

# --- Consumidor: Cloud Function conectada a Pub/Sub ---

resource "google_storage_bucket" "function_source" {
  name                        = "${var.project_id}-function-source"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

data "archive_file" "consumidor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../Backend/consumidor"
  output_path = "${path.module}/consumidor.zip"
}

resource "google_storage_bucket_object" "consumidor_source" {
  name   = "consumidor-${data.archive_file.consumidor_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.consumidor_zip.output_path
}

resource "google_cloudfunctions2_function" "consumidor" {
  name     = "consumidor"
  location = var.region

  depends_on = [
    google_project_service.cloudfunctions,
    google_project_service.cloudbuild,
    google_project_service.run,
    google_project_service.eventarc,
    google_project_service.artifactregistry,
  ]

  build_config {
    runtime     = "python312"
    entry_point = "consumidor"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.consumidor_source.name
      }
    }
  }

  service_config {
    max_instance_count = 3
    available_memory    = "256M"
    timeout_seconds       = 60
    environment_variables = {
      GOOGLE_CLOUD_PROJECT = var.project_id
      BQ_DATASET           = google_bigquery_dataset.raw.dataset_id
      BQ_TABLE             = google_bigquery_table.transacciones_raw.table_id
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = "projects/${var.project_id}/topics/transacciones-neobanx"
    retry_policy   = "RETRY_POLICY_RETRY"
  }
}