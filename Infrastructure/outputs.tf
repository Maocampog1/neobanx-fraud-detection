// ============================================================================
// Salidas — los nombres que el resto del equipo necesita
// ============================================================================
//
// Cumple el último punto del checklist de entrega: "un archivo de salidas en el
// repo con todos los nombres (conexión, topics, Redis, buckets, cuentas de
// servicio)". En vez de pasarse los nombres por chat, cualquiera corre:
//
//     terraform output
//     terraform output -json > salidas.json
//
// Ningún output expone un secreto. Las contraseñas y la clave HMAC viven solo
// en Secret Manager; aquí se publican los NOMBRES de los secretos para que los
// servicios sepan qué leer.

// --- Cloud SQL ---------------------------------------------------------------

output "cloudsql_connection_name" {
  description = "Cadena proyecto:region:instancia. La necesitan el Auth Proxy y el conector de Cloud SQL."
  value       = google_sql_database_instance.transaccional.connection_name
}

output "cloudsql_instancia" {
  description = "Nombre de la instancia de Cloud SQL."
  value       = google_sql_database_instance.transaccional.name
}

output "cloudsql_db" {
  description = "Nombre de la base de datos lógica."
  value       = google_sql_database.neobanx.name
}

// --- Pub/Sub -----------------------------------------------------------------

output "pubsub_topics" {
  description = "Topics de Pub/Sub, incluidas las colas de mensajes muertos."
  value = {
    preseleccionadas     = google_pubsub_topic.preseleccionadas.name
    veredictos           = google_pubsub_topic.veredictos.name
    preseleccionadas_dlq = google_pubsub_topic.preseleccionadas_dlq.name
    veredictos_dlq       = google_pubsub_topic.veredictos_dlq.name
  }
}

output "pubsub_suscripciones" {
  description = "Suscripciones de Pub/Sub por consumidor."
  value = {
    flink  = google_pubsub_subscription.flink_preseleccionadas.name
    cierre = google_pubsub_subscription.cierre_veredictos.name
    stub   = google_pubsub_subscription.stub_preseleccionadas.name
  }
}

// --- Red ---------------------------------------------------------------------

output "red" {
  description = "VPC y subred donde viven Dataproc y Memorystore."
  value = {
    vpc    = google_compute_network.vpc.name
    subred = google_compute_subnetwork.principal.name
    cidr   = google_compute_subnetwork.principal.ip_cidr_range
  }
}

// --- Redis -------------------------------------------------------------------

output "redis" {
  description = <<-EOT
    Datos de conexión a Memorystore. La cadena de autenticación NO se expone
    aquí: está en Secret Manager (`neobanx-redis-auth`) y la lee el job de
    Flink. Para probar a mano desde un nodo de Dataproc:

      redis-cli -h <host> -p <puerto> --tls -a "$(gcloud secrets versions access latest --secret=neobanx-redis-auth)" HGETALL perfil:<hash>
  EOT
  value = {
    host           = google_redis_instance.perfil_cliente.host
    puerto         = google_redis_instance.perfil_cliente.port
    secreto_auth   = google_secret_manager_secret.redis_auth.secret_id
    patron_clave   = "perfil:{cc_num_hash}"
  }
}

// --- Dataproc ----------------------------------------------------------------

output "dataproc" {
  description = <<-EOT
    Clúster de Flink. OJO: tiene `idle_delete_ttl` de 30 minutos, así que se
    autodestruye si no hay jobs corriendo. Si desapareció, recréalo con
    `terraform apply`.
  EOT
  value = {
    cluster           = google_dataproc_cluster.flink.name
    region            = google_dataproc_cluster.flink.region
    bucket_checkpoint = google_storage_bucket.flink_checkpoints.name
    autodestruccion   = "30 minutos sin jobs"
  }
}

// --- Buckets -----------------------------------------------------------------

output "buckets" {
  description = "Buckets gestionados por este Terraform."
  value = {
    flink_checkpoints = google_storage_bucket.flink_checkpoints.name
    dataproc_staging  = google_storage_bucket.dataproc_staging.name
    dataproc_temp     = google_storage_bucket.dataproc_temp.name
  }
}

// --- Cuentas de servicio -----------------------------------------------------

output "cuentas_servicio" {
  description = "Correos de las cuentas de servicio, una por componente."
  value       = { for k, sa in google_service_account.componentes : k => sa.email }
}

// --- Secretos ----------------------------------------------------------------

output "secretos" {
  description = <<-EOT
    Nombres (no valores) de los secretos en Secret Manager. Los servicios los
    leen en tiempo de ejecución; ninguna persona necesita conocer su contenido.

    Para consultar uno a mano, por ejemplo la contraseña de postgres:
      gcloud secrets versions access latest --secret=neobanx-db-postgres
  EOT
  value = merge(
    {
      postgres = google_secret_manager_secret.postgres_password.secret_id
      hmac_key = google_secret_manager_secret.hmac_key.secret_id
    },
    { for k, s in google_secret_manager_secret.roles_db : k => s.secret_id }
  )
}

// --- Configuración del flujo -------------------------------------------------

output "parametros_flujo" {
  description = "Parámetros del flujo transaccional, para que los servicios los lean desde un solo lugar."
  value = {
    timeout_veredicto_segundos = var.timeout_veredicto_segundos
    umbral_monto_preseleccion  = var.umbral_monto_preseleccion
    probabilidad_muestreo      = var.probabilidad_muestreo
  }
}
