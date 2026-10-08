// ============================================================================
// Cloud SQL (PostgreSQL) — capa transaccional
// ============================================================================
//
// CAMBIOS FRENTE AL SPRINT 1
//
//   1. Se eliminó `authorized_networks = 0.0.0.0/0`. La instancia ya no acepta
//      conexiones desde cualquier IP. Las personas y Terraform entran por el
//      Cloud SQL Auth Proxy; los servicios, por el conector de Cloud SQL.
//
//   2. Se agregó `cloudsql.logical_decoding = on`, requisito de Datastream
//      para leer el WAL por replicación lógica. OJO: agregar este flag a una
//      instancia existente provoca un REINICIO.
//
//   3. El esquema se aplica con `aplicar_schema.sh` (a través del proxy y
//      pasando las contraseñas de los roles), no con un `psql` inline contra
//      la IP pública.
//
//   4. La contraseña de postgres la genera Terraform (ver secrets.tf), ya no
//      viene de un `.env` que cada persona escribía a mano.

resource "google_sql_database_instance" "transaccional" {
  name             = var.db_instancia
  database_version = "POSTGRES_18"
  region           = var.region

  // Datos sintéticos y reproducibles desde el repo: no hace falta protección
  // contra borrado, y tenerla activa estorba al reciclar el entorno.
  deletion_protection = false

  depends_on = [google_project_service.apis]

  settings {
    tier              = var.db_tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"

    // `activation_policy` no se declara: el API de Cloud SQL no permite crear
    // una instancia directamente en estado NEVER (falla con
    // "invalidOperation"), solo nace en ALWAYS. Se ignora en el lifecycle de
    // abajo para que apagarla a mano (ahorro de créditos) no produzca un diff.

    disk_size       = 10
    disk_type       = "PD_SSD"
    disk_autoresize = true

    deletion_protection_enabled = false
    enable_dataplex_integration = true
    retain_backups_on_delete    = true

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"

      // Ya NO hay un `0.0.0.0/0` como en el Sprint 1. Las personas y Terraform
      // entran por el Cloud SQL Auth Proxy y los servicios por el conector de
      // Cloud SQL, ambos autenticados con IAM en vez de depender de la IP de
      // origen.
      //
      // La única excepción es Datastream: se conecta desde un conjunto fijo de
      // IP públicas de Google y no soporta el Auth Proxy, así que hay que
      // autorizarlas. Son 5 direcciones /32 concretas de la región, no un
      // rango abierto. Ver `local.datastream_ips` en variables.tf.
      dynamic "authorized_networks" {
        for_each = local.datastream_ips

        content {
          name  = "datastream-${authorized_networks.key}"
          value = "${authorized_networks.value}/32"
        }
      }
    }

    backup_configuration {
      enabled                        = true
      location                       = "us"
      start_time                     = "12:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    // Requisito de Datastream para CDC. Cambiarlo reinicia la instancia.
    database_flags {
      name  = "cloudsql.logical_decoding"
      value = "on"
    }

    // Datastream mantiene un slot de replicación abierto. Con el default de
    // 10 alcanza, pero se sube un poco para dejar margen a reconexiones que
    // dejen el slot anterior ocupado unos minutos.
    database_flags {
      name  = "max_replication_slots"
      value = "20"
    }

    database_flags {
      name  = "max_wal_senders"
      value = "20"
    }

    password_validation_policy {
      enable_password_policy      = true
      complexity                  = "COMPLEXITY_DEFAULT"
      disallow_username_substring = true
      min_length                  = 8
      reuse_interval              = 0
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].disk_size,
      settings[0].activation_policy,
    ]
  }
}

// No se declara un `google_sql_user` para "postgres": Cloud SQL ya crea ese
// usuario al crear la instancia, y el API de PostgreSQL exige contraseña en la
// misma llamada de creación, así que "crearlo" de nuevo con Terraform falla con
// "Missing user password" en un proyecto nuevo. Se le fija la contraseña con
// gcloud, que además evita el bug conocido del provider con contraseñas de
// usuarios PostgreSQL (necesita un proxy local en 127.0.0.1:5432 que no está
// disponible en todos los entornos).
resource "null_resource" "set_postgres_password" {
  depends_on = [google_sql_database_instance.transaccional]

  triggers = {
    password_hash = sha256(random_password.postgres.result)
    instancia     = google_sql_database_instance.transaccional.name
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]
    environment = {
      NEOBANX_DB_PASSWORD = random_password.postgres.result
    }
    command = <<-EOT
      gcloud sql users set-password postgres \
        --instance=${google_sql_database_instance.transaccional.name} \
        --password="$NEOBANX_DB_PASSWORD" \
        --project=${var.project_id}
    EOT
  }
}

resource "google_sql_database" "neobanx" {
  name     = var.db_nombre
  instance = google_sql_database_instance.transaccional.name
}

// ---------------------------------------------------------------------------
// Aplicación del esquema
// ---------------------------------------------------------------------------
//
// Se dispara cuando cambia `schema.sql` o el propio script. Ojo con el detalle
// que costó un diagnóstico en el Sprint 1: el esquema v1 usaba
// `CREATE TABLE IF NOT EXISTS`, así que al cambiar el archivo las tablas ya
// existentes NO se actualizaban y Postgres no emitía ningún error — Terraform
// reportaba éxito y la base seguía con el esquema viejo. El v2 empieza con
// DROP explícito justamente por eso.

resource "null_resource" "aplicar_schema" {
  depends_on = [
    google_sql_database.neobanx,
    null_resource.set_postgres_password,
  ]

  triggers = {
    schema_hash = filesha256("${path.module}/schema.sql")
    script_hash = filesha256("${path.module}/aplicar_schema.sh")
    // Si se regeneran las contraseñas, hay que volver a aplicar los ALTER ROLE.
    passwords_hash = sha256(join(",", [
      for rol in local.roles_db : random_password.roles_db[rol].result
    ]))
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]

    environment = {
      INSTANCE_CONNECTION_NAME = google_sql_database_instance.transaccional.connection_name
      DB_NAME                  = google_sql_database.neobanx.name
      SCHEMA_FILE              = "${path.module}/schema.sql"

      PGPASSWORD       = random_password.postgres.result
      PWD_APP_REGISTRO = random_password.roles_db["app_registro"].result
      PWD_APP_CIERRE   = random_password.roles_db["app_cierre"].result
      PWD_DATASTREAM   = random_password.roles_db["datastream"].result
      PWD_AGENTE_RO    = random_password.roles_db["agente_ro"].result
      PWD_FRONTEND_RO  = random_password.roles_db["frontend_ro"].result
    }

    // Se invoca con `bash`, no con `sh`, a propósito: en Debian /bin/sh es
    // dash, que no soporta `set -o pipefail` ni los arrays y la expansión
    // indirecta que usa el script. Invocarlo como `sh script.sh` pisaría el
    // shebang y fallaría con "Illegal option -o pipefail".
    //
    // Se usa `bash script.sh` en vez de ejecutarlo directo porque un checkout
    // desde Windows suele perder el bit de ejecución del archivo.
    command = "bash ${path.module}/aplicar_schema.sh"
  }
}

// ---------------------------------------------------------------------------
// Carga de datos maestros (clientes y cuentas)
// ---------------------------------------------------------------------------
//
// POR QUÉ ESTO ES PARTE DEL DESPLIEGUE Y NO UN PASO MANUAL
//
// `transacciones.cc_num_hash` es llave foránea de `cuentas.cc_num_hash`. Con
// `cuentas` vacía, el servicio de registro NO puede insertar ninguna
// transacción: PostgreSQL las rechaza todas. Y el perfil del titular no puede
// llegar por el stream, porque `Backend/contrato_datos_generador.md` excluye
// la PII del mensaje a propósito.
//
// Es decir: sin esta carga el sistema no procesa nada. Dejarla como paso
// manual significaría que un `deploy.sh` exitoso entrega un entorno que
// rechaza el 100 % de las transacciones. Como el equipo destruye y recrea el
// entorno en cada sesión, tiene que quedar automático.
//
// Esto NO precarga transacciones: `transacciones`, `veredictos` e
// `historial_estados` se llenan solo por el flujo. Aquí van únicamente las
// dimensiones.

resource "null_resource" "cargar_maestros" {
  depends_on = [null_resource.aplicar_schema]

  triggers = {
    script_hash = filesha256("${path.module}/cargar_maestros.sh")
    python_hash = filesha256("${path.module}/../Backend/carga/cargar_maestros.py")
    hmac_hash   = filesha256("${path.module}/../Backend/common/hmac_util.py")
    // Si cambia el esquema se recrean las tablas: hay que recargar.
    schema_hash = filesha256("${path.module}/schema.sql")
    // Si cambia la clave HMAC, todos los hashes cambian y la carga anterior
    // deja de servir.
    clave_hmac = sha256(random_password.hmac_key.result)
  }

  provisioner "local-exec" {
    interpreter = ["sh", "-c"]

    environment = {
      INSTANCE_CONNECTION_NAME = google_sql_database_instance.transaccional.connection_name
      DB_NAME                  = google_sql_database.neobanx.name
      PGPASSWORD               = random_password.postgres.result
      PROJECT_ID               = var.project_id
      HMAC_SECRET_ID           = google_secret_manager_secret.hmac_key.secret_id
      DATASET_URL              = var.dataset_url
      DATASET_TEST_URL         = var.dataset_test_url
      CARGA_DIR                = "${path.module}/../Backend/carga"
    }

    command = "bash ${path.module}/cargar_maestros.sh"
  }
}
