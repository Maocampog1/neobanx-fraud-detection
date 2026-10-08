// ============================================================================
// BigQuery y Datastream — capa analítica
// ============================================================================
//
// CÓMO LLEGAN LOS DATOS A BIGQUERY
//
// En el Sprint 1 una Cloud Function escribía a BigQuery en paralelo a todo lo
// demás, así que el dashboard solo veía lo que esa función alcanzaba a insertar
// y nunca el estado final de una transacción.
//
// Ahora el camino es Datastream: replicación de cambios (CDC) desde Cloud SQL.
// Lee el WAL de PostgreSQL y refleja en BigQuery cada INSERT y cada UPDATE de
// las 5 tablas. Dos consecuencias importantes:
//
//   - El dashboard ve TODAS las transacciones, no solo las preseleccionadas,
//     porque replica la tabla completa.
//   - Ve el estado FINAL de cada una, porque los UPDATE de cierre también se
//     replican. Con el enfoque anterior una transacción quedaba congelada en
//     el estado que tenía al momento de insertarla.
//
// Y no hay código que mantener: la replicación es un servicio gestionado, no un
// consumidor que haya que escribir, desplegar y vigilar.
//
// Datastream necesita tres cosas que ya están en su sitio:
//   1. `cloudsql.logical_decoding = on`  -> cloudsql.tf
//   2. La publicación `neobanx_datastream_pub` -> schema.sql
//   3. El slot `neobanx_datastream_slot` -> aplicar_schema.sh

// ---------------------------------------------------------------------------
// Datasets
// ---------------------------------------------------------------------------

// Capa cruda: réplica fiel de Cloud SQL, tal como la escribe Datastream.
// No se modela aquí; es la materia prima del modelo en estrella.
resource "google_bigquery_dataset" "raw" {
  dataset_id    = "raw"
  friendly_name = "Capa cruda (réplica CDC de Cloud SQL)"
  description   = "Réplica de las 5 tablas transaccionales vía Datastream. No modificar a mano: Datastream la sobreescribe."
  location      = var.bq_location

  // Datos sintéticos reproducibles: no hace falta protección contra borrado,
  // y tenerla activa bloquearía `terraform destroy`.
  delete_contents_on_destroy = true

  labels = {
    capa       = "raw"
    origen     = "datastream"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// Capa analítica: modelo en estrella construido con consultas programadas
// sobre `raw`. Las tablas y dimensiones las crea el bloque de Camilo.
resource "google_bigquery_dataset" "analitica" {
  dataset_id    = "analitica"
  friendly_name = "Capa analítica (modelo en estrella)"
  description   = "Hechos y dimensiones derivados de raw. Fuente del dashboard de Looker Studio."
  location      = var.bq_location

  delete_contents_on_destroy = true

  labels = {
    capa       = "analitica"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// Perfiles de conexión de Datastream
// ---------------------------------------------------------------------------

resource "google_datastream_connection_profile" "postgres_origen" {
  display_name          = "Cloud SQL PostgreSQL (origen)"
  location              = var.region
  connection_profile_id = "neobanx-postgres-origen"

  postgresql_profile {
    hostname = google_sql_database_instance.transaccional.public_ip_address
    port     = 5432
    username = "datastream_user"
    password = random_password.roles_db["datastream"].result
    database = google_sql_database.neobanx.name
  }

  depends_on = [
    google_project_service.apis,
    null_resource.aplicar_schema, // la publicación y el slot deben existir
  ]
}

resource "google_datastream_connection_profile" "bigquery_destino" {
  display_name          = "BigQuery (destino)"
  location              = var.region
  connection_profile_id = "neobanx-bigquery-destino"

  bigquery_profile {}

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// Stream de replicación
// ---------------------------------------------------------------------------

resource "google_datastream_stream" "cloudsql_a_bigquery" {
  display_name  = "Cloud SQL -> BigQuery (CDC)"
  location      = var.region
  stream_id     = "neobanx-cdc-transaccional"
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.postgres_origen.id

    postgresql_source_config {
      // Deben coincidir exactamente con lo que crean schema.sql y
      // aplicar_schema.sh.
      publication      = "neobanx_datastream_pub"
      replication_slot = "neobanx_datastream_slot"

      // Solo el esquema public y solo las 5 tablas del modelo. Listar las
      // tablas explícitamente evita que una tabla nueva empiece a replicarse
      // sin que nadie lo haya decidido.
      include_objects {
        postgresql_schemas {
          schema = "public"

          postgresql_tables { table = "clientes" }
          postgresql_tables { table = "cuentas" }
          postgresql_tables { table = "transacciones" }
          postgresql_tables { table = "veredictos" }
          postgresql_tables { table = "historial_estados" }
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.bigquery_destino.id

    bigquery_destination_config {
      // Cada cuánto Datastream consolida los cambios en las tablas de
      // BigQuery. Es el principal mando de costo/latencia de este recurso:
      // más fresco significa más operaciones de merge. Ver var.bq_data_freshness.
      data_freshness = "${var.bq_data_freshness}s"

      // Todas las tablas van al dataset `raw`, en vez de que Datastream cree
      // un dataset por esquema de origen. Con un solo esquema (`public`) no
      // aporta nada tener jerarquía, y así el nombre del dataset lo controlamos
      // nosotros.
      single_target_dataset {
        dataset_id = google_bigquery_dataset.raw.id
      }
    }
  }

  // Carga inicial de las filas existentes además de los cambios en adelante.
  // Sin esto, BigQuery solo vería lo que cambie DESPUÉS de crear el stream, y
  // los clientes y cuentas precargados nunca aparecerían.
  backfill_all {}

  depends_on = [
    null_resource.aplicar_schema,
    // La carga de datos maestros va antes del stream a propósito: así el
    // backfill inicial ya encuentra `clientes` y `cuentas` poblados. Si el
    // stream se creara primero, esas filas llegarían igual (por CDC, como
    // INSERT), pero el orden quedaría a merced de los tiempos de cada paso.
    null_resource.cargar_maestros,
    google_sql_database_instance.transaccional,
  ]
}
