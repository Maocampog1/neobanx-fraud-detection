// ============================================================================
// Carga batch del perfil histórico del cliente a Redis
// ============================================================================
//
// Último paso de la plataforma: deja Redis poblado para que el job de Flink
// pueda enriquecer transacciones desde el primer mensaje.
//
// POR QUÉ CORRE EN DATAPROC Y NO EN LA MÁQUINA DEL DESPLIEGUE
//
// Memorystore tiene IP privada (Private Service Access), así que solo es
// alcanzable desde dentro de la VPC. La máquina que ejecuta `terraform apply`
// está fuera. Los nodos de Dataproc sí están en la subred, así que son el
// único lugar desde donde se puede escribir en Redis.
//
// Es la diferencia con la carga de `clientes`/`cuentas`: esa va a Cloud SQL,
// que sí se alcanza por el Auth Proxy desde fuera de la VPC.

// El código del job tiene que estar en GCS: Dataproc no lee del disco local de
// quien lanza el job.
resource "google_storage_bucket_object" "job_perfiles" {
  name   = "jobs/perfiles_redis.py"
  bucket = google_storage_bucket.dataproc_staging.name
  source = "${path.module}/../Backend/carga/perfiles_redis.py"

  // Si cambia el script, se sube de nuevo y el job se vuelve a ejecutar.
  source_md5hash = filemd5("${path.module}/../Backend/carga/perfiles_redis.py")
}

resource "google_dataproc_job" "perfiles_redis" {
  region = var.region

  placement {
    cluster_name = google_dataproc_cluster.flink.name
  }

  // Si el job falla, el apply falla: no tiene sentido entregar la plataforma
  // con Redis vacío, porque el enriquecimiento de Flink no tendría nada que
  // consultar.
  force_delete = true

  pyspark_config {
    main_python_file_uri = "gs://${google_storage_bucket.dataproc_staging.name}/${google_storage_bucket_object.job_perfiles.name}"

    // Solo parámetros, ningún secreto: los argumentos de un job quedan
    // visibles en la consola de Dataproc y en el historial. La clave HMAC y el
    // auth de Redis los lee el propio job desde Secret Manager usando las
    // credenciales de sa-flink.
    args = [
      "--csv", replace(var.dataset_url, "https://storage.googleapis.com/", "gs://"),
      "--redis-host", google_redis_instance.perfil_cliente.host,
      "--redis-port", tostring(google_redis_instance.perfil_cliente.port),
      "--proyecto", var.project_id,
      "--secreto-hmac", google_secret_manager_secret.hmac_key.secret_id,
      "--secreto-redis", google_secret_manager_secret.redis_auth.secret_id,
    ]

    properties = {
      // ~1000 perfiles de salida: no hace falta paralelismo alto y reducirlo
      // evita el sobrecosto de coordinar particiones vacías.
      "spark.sql.shuffle.partitions" = "8"
      "spark.executor.memory"        = "2g"

      // Sin esto, PySpark usa por defecto el Python de CONDA
      // (/opt/conda/default/bin, via PYSPARK_PYTHON que Dataproc exporta
      // solo), no el de sistema -- confirmado contra la doc oficial
      // ("Configure the Dataproc Python environment"). Pero
      // instalar_dependencias_flink.sh instala las dependencias de este
      // job (`google-cloud-secret-manager`, `redis`, etc.) en
      // /usr/bin/python3 (el de sistema), porque eso es lo que necesita
      // Flink -- ver ese script. Sin forzar esta propiedad, el job falla
      // con "ImportError: cannot import name 'secretmanager' from
      // 'google.cloud'" porque busca el paquete en el Python de conda,
      // donde nunca se instaló. Apuntando ambos (driver y executors) al
      // mismo Python de sistema, el job encuentra lo que ya se instaló
      // para Flink, sin duplicar nada.
      "spark.pyspark.python"        = "/usr/bin/python3"
      "spark.pyspark.driver.python" = "/usr/bin/python3"
    }
  }

  depends_on = [
    google_redis_instance.perfil_cliente,
    google_secret_manager_secret_version.hmac_key,
    google_secret_manager_secret_version.redis_auth,
    google_secret_manager_secret_iam_member.redis_auth_flink,
    google_secret_manager_secret_iam_member.hmac_lectores,
  ]
}
