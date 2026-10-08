// ============================================================================
// Memorystore (Redis) — perfil histórico del cliente
// ============================================================================
//
// QUÉ ROL CUMPLE
//
// Es el tercer modelo de datos del proyecto (clave-valor), además del
// transaccional en Cloud SQL y el analítico en BigQuery. No guarda histórico:
// guarda el ESTADO ACTUAL del comportamiento de cada cuenta, para que el job
// de Flink pueda enriquecer una transacción en milisegundos.
//
// Por qué no se resuelve con las otras dos capas:
//   - BigQuery es rápido para agregaciones sobre millones de filas, pero una
//     consulta puntual "dame el perfil de esta cuenta" tiene latencia de
//     cientos de milisegundos y costo por consulta. Hacerlo por cada
//     transacción del stream no es viable.
//   - Cloud SQL podría, pero cada lectura compite con las escrituras del
//     flujo transaccional, que es el camino crítico de la operación.
//
// Estructura de las claves (la escribe la carga batch de perfiles):
//
//   perfil:{cc_num_hash}  -> hash de Redis con los campos:
//       monto_promedio        media histórica de la cuenta
//       monto_desviacion      desviación estándar
//       categorias_frecuentes lista separada por comas
//       lat_habitual          centroide de ubicación
//       long_habitual
//       num_transacciones     tamaño de la muestra
//
// Se consulta con HGETALL, que es una sola ida y vuelta.

resource "google_redis_instance" "perfil_cliente" {
  name           = "neobanx-perfil-cliente"
  display_name   = "Perfil histórico del cliente para enriquecimiento en streaming"
  region         = var.region
  redis_version  = "REDIS_7_2"

  // BASIC = un solo nodo, sin réplica. Es lo correcto aquí: el contenido es
  // un derivado recomputable desde el CSV con la carga batch, así que la alta
  // disponibilidad de STANDARD_HA (que cuesta el doble) no se justifica. Si el
  // nodo se pierde, se recarga.
  tier = "BASIC"

  // 1 GB es el mínimo de Memorystore y sobra: ~1000 cuentas con media docena
  // de campos cada una son unos pocos cientos de KB. Dejarlo en el mínimo es
  // la decisión de costo relevante, porque Memorystore cobra por hora
  // encendido, no por uso.
  memory_size_gb = 1

  authorized_network = google_compute_network.vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  // Sin esto, cualquier cosa dentro de la VPC podría leer y escribir el perfil
  // de los clientes sin credencial alguna.
  auth_enabled = true

  // Cifrado en tránsito entre Flink y Redis.
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  // El perfil es un derivado recomputable: si Redis se queda sin memoria,
  // preferimos que descarte las claves menos usadas antes que empezar a
  // rechazar escrituras y tumbar el enriquecimiento.
  redis_configs = {
    maxmemory-policy = "allkeys-lru"
  }

  labels = {
    componente = "enriquecimiento"
    modelo     = "clave-valor"
    gestionado = "terraform"
  }

  // El peering de Private Service Access tiene que existir antes: sin él, la
  // instancia no tiene dónde tomar su IP privada.
  depends_on = [
    google_service_networking_connection.psa,
    google_project_service.apis,
  ]
}

// ---------------------------------------------------------------------------
// La cadena de autenticación de Redis, en Secret Manager
// ---------------------------------------------------------------------------
//
// Con `auth_enabled = true`, Google genera la cadena de autenticación y la
// expone como atributo de la instancia. Se guarda en Secret Manager para que
// el job de Flink y la carga batch la lean igual que cualquier otro secreto,
// en vez de pasarla como argumento del job (donde quedaría visible en los
// logs de Dataproc y en la consola).

resource "google_secret_manager_secret" "redis_auth" {
  secret_id = "neobanx-redis-auth"

  labels = {
    componente = "enriquecimiento"
    gestionado = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "redis_auth" {
  secret      = google_secret_manager_secret.redis_auth.id
  secret_data = google_redis_instance.perfil_cliente.auth_string
}

resource "google_secret_manager_secret_iam_member" "redis_auth_flink" {
  secret_id = google_secret_manager_secret.redis_auth.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.componentes["flink"].email}"
}
