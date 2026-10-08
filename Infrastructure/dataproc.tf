// ============================================================================
// Dataproc — clúster con Apache Flink
// ============================================================================
//
// POR QUÉ FLINK Y NO SPARK
//
// Decisión del equipo, registrada en el plan del sprint: el objetivo es
// streaming y Spark Structured Streaming trabaja por micro-lotes, mientras
// Flink procesa evento por evento con estado nativo. Para las reglas que
// necesitan estado por cliente (ráfaga de transacciones, ubicación imposible
// entre dos operaciones consecutivas), el modelo de Flink encaja directamente.
//
// POR QUÉ DATAPROC Y NO DATAFLOW
//
// Dataflow es el servicio de streaming nativo de GCP y sería más simple de
// operar (serverless, sin clúster que administrar), pero corre Apache Beam, no
// Flink. El equipo priorizó Flink porque el código del job es portable a otras
// nubes (Kinesis Data Analytics en AWS corre Flink administrado), lo cual era
// un criterio explícito del proyecto. El costo de esa portabilidad es tener
// que administrar un clúster.
//
// ADVERTENCIA DE COSTO — LO MÁS CARO DEL PROYECTO
//
// Este clúster cobra por minuto encendido, haya o no transacciones. A
// diferencia de Cloud SQL (que se puede apagar) y de Pub/Sub o Cloud Run (que
// cobran por uso), un clúster de Dataproc inactivo sigue facturando igual.
//
// Mitigaciones aplicadas:
//   - La máquina más pequeña que admite Flink.
//   - Dos workers, el mínimo para que el clúster arranque.
//   - Discos pequeños.
//   - `idle_delete_ttl`: el clúster SE AUTODESTRUYE tras un rato sin trabajo.
//     Esto es lo que evita la factura sorpresa por dejarlo prendido un fin de
//     semana. Si se autodestruye, el siguiente `terraform apply` lo recrea.

resource "google_dataproc_cluster" "flink" {
  name   = "neobanx-flink"
  region = var.region

  labels = {
    componente = "deteccion"
    motor      = "flink"
    gestionado = "terraform"
  }

  cluster_config {
    // Staging y temporal explícitos. Los DOS son necesarios: declarar solo el
    // staging hizo que Dataproc creara su propio bucket temporal con nombre
    // generado, que después sobrevivió al destroy como basura huérfana (ver el
    // comentario de google_storage_bucket.dataproc_temp en storage.tf).
    staging_bucket = google_storage_bucket.dataproc_staging.name
    temp_bucket    = google_storage_bucket.dataproc_temp.name

    gce_cluster_config {
      // `null` activa la colocación automática de zona: Dataproc elige una
      // zona de la región con capacidad disponible. Fijar una zona concreta
      // hizo fallar el primer despliegue con ZONE_RESOURCE_POOL_EXHAUSTED
      // (Google sin capacidad de n2-standard-2 en us-central1-a). Ver la
      // descripción de `var.zona` en variables.tf.
      zone            = var.zona != "" ? var.zona : null
      subnetwork      = google_compute_subnetwork.principal.id
      service_account = google_service_account.componentes["flink"].email

      // Sin IP pública: los nodos salen a internet por Cloud NAT (necesario
      // para la API de Nager.Date) y alcanzan las APIs de Google por
      // private_ip_google_access.
      internal_ip_only = true

      service_account_scopes = ["cloud-platform"]

      tags = ["neobanx-dataproc"]
    }

    master_config {
      num_instances = 1
      machine_type  = var.dataproc_machine_type

      disk_config {
        boot_disk_type    = "pd-standard"
        boot_disk_size_gb = 50
      }
    }

    worker_config {
      // 2 es el mínimo: Dataproc no admite un clúster de 1 worker en modo
      // estándar, y el modo de un solo nodo no sirve para un job de streaming
      // de larga duración.
      num_instances = 2
      machine_type  = var.dataproc_machine_type

      disk_config {
        boot_disk_type    = "pd-standard"
        boot_disk_size_gb = 50
      }
    }

    software_config {
      // La imagen 2.2 trae Flink como componente opcional.
      image_version = "2.2-debian12"

      optional_components = ["FLINK"]

      override_properties = {
        // Dependencias de Python para el job batch de perfiles. Se instalan al
        // crear el clúster, no en cada job, así que el job arranca sin esperar.
        //   redis                        -> escribir los perfiles
        //   google-cloud-secret-manager  -> leer la clave HMAC y el auth de Redis
        //
        // Los secretos se leen DENTRO del job, no se pasan como argumentos:
        // los argumentos quedan visibles en la consola de Dataproc y en el
        // historial de jobs.
        "dataproc:pip.packages" = "redis==5.0.1,google-cloud-secret-manager==2.20.2"

        // Flink corre sobre YARN en Dataproc.
        "flink:taskmanager.numberOfTaskSlots" = "2"

        // Checkpoints en GCS: permiten que el job reanude exactamente donde
        // quedó si se reinicia. Sin esto, un reinicio reprocesaría o perdería
        // mensajes, y la garantía de "un veredicto por transacción" se caería.
        "flink:state.backend"                      = "rocksdb"
        "flink:state.checkpoints.dir"              = "gs://${google_storage_bucket.flink_checkpoints.name}/checkpoints"
        "flink:state.savepoints.dir"               = "gs://${google_storage_bucket.flink_checkpoints.name}/savepoints"
        "flink:execution.checkpointing.interval"   = "10s"
        "flink:execution.checkpointing.mode"       = "EXACTLY_ONCE"
        "flink:state.backend.incremental"          = "true"

        // Reintentos acotados: si el job falla de forma persistente, preferimos
        // que se detenga y dispare la alerta antes que reintentar en bucle
        // consumiendo cuota de Pub/Sub.
        "flink:restart-strategy"                             = "fixed-delay"
        "flink:restart-strategy.fixed-delay.attempts"        = "3"
        "flink:restart-strategy.fixed-delay.delay"           = "30s"

        // Evita que YARN mate contenedores por exceso de memoria virtual, un
        // fallo habitual y confuso al correr Flink sobre Dataproc.
        "yarn:yarn.nodemanager.vmem-check-enabled" = "false"
      }
    }

    // SALVAVIDAS DE COSTO: si el clúster pasa este tiempo sin ningún job, se
    // destruye solo. Es la diferencia entre gastar unos pesos y quemar los
    // créditos del semestre por un olvido.
    //
    // 30 minutos es corto a propósito durante el sprint. Para una demo larga,
    // súbelo temporalmente o relanza el clúster con `terraform apply`.
    lifecycle_config {
      idle_delete_ttl = "1800s"
    }

    endpoint_config {
      // Da acceso por HTTPS autenticado a las interfaces web de YARN y Flink,
      // sin abrir puertos ni usar túneles SSH. Es como se revisa si el job
      // está RUNNING y se miran sus métricas.
      enable_http_port_access = true
    }
  }

  depends_on = [
    google_project_service.apis,
    google_service_networking_connection.psa,
    google_storage_bucket_iam_member.dataproc_buckets_rw,
    google_storage_bucket_iam_member.flink_checkpoints_rw,

    // Cloud NAT es un requisito REAL, no una conveniencia: los nodos tienen
    // `internal_ip_only = true`, así que su única salida a internet es el NAT.
    // Y `dataproc:pip.packages` instala desde PyPI, que es internet.
    //
    // Sin esta dependencia explícita, Terraform puede crear el clúster en
    // paralelo al NAT; si el clúster arranca primero, el pip install no alcanza
    // pypi.org y la creación del clúster falla. `private_ip_google_access`
    // no ayuda aquí porque solo cubre APIs de Google, no PyPI.
    google_compute_router_nat.nat,

    // Los ROLES de sa-flink, no solo la cuenta. Dataproc valida al crear el
    // clúster que la cuenta de servicio tenga `roles/dataproc.worker`; si el
    // binding no existe todavía, la creación falla con
    // "Custom Service Account ... is missing required permissions".
    //
    // Referenciar `google_service_account.componentes["flink"].email` NO crea
    // esta dependencia: Terraform solo sabe que necesita la cuenta, no sus
    // roles. En un apply completo esto funcionaba por azar en el orden.
    google_project_iam_member.componentes,

    // La regla de firewall interna. El maestro y los workers se coordinan por
    // puertos dinámicos; sin ella el clúster arranca pero los nodos nunca se
    // registran y la creación muere con:
    //   "Cannot start master: Timed out waiting for 2 nodes. This usually
    //    happens when VM to VM communications are blocked by firewall rules."
    google_compute_firewall.interno,
  ]

  // NOTA GENERAL SOBRE ESTOS depends_on
  //
  // Dataproc tiene varios requisitos de infraestructura que Terraform NO puede
  // inferir del código, porque el recurso del clúster no los referencia:
  //
  //   firewall interno          -> los nodos se hablan entre sí
  //   Cloud NAT                 -> pip install desde PyPI
  //   roles de la cuenta        -> validación de dataproc.worker al crear
  //   IAM de los buckets        -> staging y temp
  //   peering de PSA            -> la red donde viven los nodos
  //
  // Cada uno de estos, omitido, produce un error distinto y ninguno evidente.
  // Hay que declararlos a mano o el despliegue funciona solo por azar en el
  // orden que elija Terraform.
}
