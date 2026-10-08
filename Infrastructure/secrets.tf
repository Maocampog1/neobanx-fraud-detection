// ============================================================================
// Secret Manager, contraseñas generadas y cuentas de servicio
// ============================================================================
//
// QUÉ RESUELVE ESTE ARCHIVO
//
// En el Sprint 1 los secretos los escribía cada persona a mano en su `.env`:
// `DB_PASSWORD` y `GENERATOR_SALT`. Eso tenía tres problemas:
//
//   1. Circulaban por chat / documento compartido.
//   2. Si dos personas usaban un `GENERATOR_SALT` distinto, los `cc_num_hash`
//      no coincidían y el join entre `cuentas` y `transacciones` quedaba roto
//      sin que nadie lo notara.
//   3. `Documentation/reglas_calidad_neobanx.md` exige HMAC con clave fija en
//      Secret Manager, no un salt en variable de entorno.
//
// Ahora Terraform genera los valores, los guarda en Secret Manager y le da
// acceso a cada cuenta de servicio solo a los secretos que necesita. Ningún
// humano tiene que conocerlos.
//
// ADVERTENCIA SOBRE LA CLAVE HMAC
//
// `random_password.hmac_key` es estable mientras viva en el estado de
// Terraform. Un `destroy` seguido de `apply` genera una clave NUEVA, y eso
// invalida todos los `cc_num_hash` ya almacenados: habría que recargar
// `clientes`, `cuentas` y `transacciones`. Es aceptable porque los datos se
// recargan del CSV, pero no es algo que deba pasar sin querer.

// ---------------------------------------------------------------------------
// Contraseñas y claves generadas
// ---------------------------------------------------------------------------

locals {
  // Roles de PostgreSQL que necesitan contraseña propia (ver schema.sql).
  roles_db = [
    "app_registro",
    "app_cierre",
    "datastream",
    "agente_ro",
    "frontend_ro",
  ]
}

// Los caracteres especiales se restringen a un conjunto seguro: estas
// contraseñas viajan como argumentos de `gcloud` y de `psql` dentro de los
// provisioners, y caracteres como `$`, backtick o comilla romperían el
// escapado del shell.
resource "random_password" "postgres" {
  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 2
  override_special = "-_=+:?#%"
}

resource "random_password" "roles_db" {
  for_each = toset(local.roles_db)

  length           = 32
  min_lower        = 4
  min_upper        = 4
  min_numeric      = 4
  min_special      = 2
  override_special = "-_=+:?#%"
}

// Clave HMAC para tokenizar cc_num. Sin caracteres especiales: se usa como
// material criptográfico, no necesita complejidad tipográfica, y así se evita
// cualquier problema de codificación al leerla desde Python.
resource "random_password" "hmac_key" {
  length  = 64
  special = false
}

// ---------------------------------------------------------------------------
// ALTERNATIVA DESCARTADA — variable para fijar la clave HMAC
// ---------------------------------------------------------------------------
//
// Se consideró ofrecer una variable `hmac_key_override` (alimentada desde el
// `.env` de cada persona) para que la clave fuera estable entre un `destroy` y
// un `apply`. Se descartó por dos razones:
//
// 1. NO HACE FALTA. La clave solo tendría que ser estable si los hashes
//    almacenados sobrevivieran a la regeneración de la clave. Eso no pasa en
//    el ciclo normal: `destroy.sh` borra Cloud SQL y el dataset de BigQuery a
//    la vez, así que al reaplicar se recargan `clientes`, `cuentas` y las
//    transacciones con la clave nueva, de forma consistente. Los joins siguen
//    funcionando porque ambos lados se rehashean juntos.
//
// 2. ERA UN RIESGO MAYOR QUE EL PROBLEMA QUE RESOLVÍA. Con el estado de
//    Terraform compartido, una variable por persona que alimenta un secreto
//    compartido es un vector de divergencia: si una persona aplica sin el
//    override y otra aplica con él, Terraform detecta el cambio en
//    `secret_data`, crea una versión nueva del secreto, y en ese momento todos
//    los `cc_num_hash` ya almacenados quedan huérfanos — sin ningún error
//    visible. Es exactamente la clase de fallo silencioso que el paso a Secret
//    Manager vino a eliminar (antes era el `GENERATOR_SALT` distinto entre
//    `.env`).
//
// Conclusión: la clave la genera siempre Terraform. `random_password` es
// estable mientras viva en el estado, así que un `apply` repetido NO la
// cambia; solo un `destroy` + `apply` genera una nueva, y eso es aceptable
// porque los datos se recargan del CSV de todas formas.
//
// Si algún día hiciera falta estabilidad real entre recreaciones (por ejemplo
// si BigQuery pasara a conservar histórico que sobreviva al destroy), el camino
// correcto NO es una variable de entorno: sería crear el secreto una sola vez
// fuera del ciclo de vida de Terraform (como se hizo con el bucket del estado)
// y leerlo aquí con un `data source`.

// ---------------------------------------------------------------------------
// Secretos
// ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "postgres_password" {
  secret_id = "neobanx-db-postgres"

  labels = {
    componente = "cloudsql"
    gestionado = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "postgres_password" {
  secret      = google_secret_manager_secret.postgres_password.id
  secret_data = random_password.postgres.result
}

resource "google_secret_manager_secret" "roles_db" {
  for_each = toset(local.roles_db)

  secret_id = "neobanx-db-${replace(each.value, "_", "-")}"

  labels = {
    componente = "cloudsql"
    rol        = replace(each.value, "_", "-")
    gestionado = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "roles_db" {
  for_each = toset(local.roles_db)

  secret      = google_secret_manager_secret.roles_db[each.value].id
  secret_data = random_password.roles_db[each.value].result
}

// El nombre por defecto que busca Backend/common/hmac_util.py.
resource "google_secret_manager_secret" "hmac_key" {
  secret_id = "neobanx-hmac-cc-num"

  labels = {
    componente = "tokenizacion"
    gestionado = "terraform"
  }

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "hmac_key" {
  secret      = google_secret_manager_secret.hmac_key.id
  secret_data = random_password.hmac_key.result
}

// ---------------------------------------------------------------------------
// Cuentas de servicio — una por componente, sin reutilizar la cuenta por
// defecto de Compute (que trae roles/editor sobre todo el proyecto).
// ---------------------------------------------------------------------------

locals {
  cuentas_servicio = {
    generador = "Generador de transacciones (Cloud Run Job)"
    registro  = "Servicio de registro y preselección (Cloud Run)"
    cierre    = "Servicio de cierre de veredictos y timeouts (Cloud Run)"
    flink     = "Job de Apache Flink en Dataproc"
    agente    = "Agente de investigación de alertas (Vertex AI)"
    frontend  = "Frontend de demo (Cloud Run)"
  }
}

resource "google_service_account" "componentes" {
  for_each = local.cuentas_servicio

  account_id   = "sa-${each.key}"
  display_name = each.value

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// Acceso a secretos — a nivel de SECRETO, no de proyecto
// ---------------------------------------------------------------------------
//
// Se usa `google_secret_manager_secret_iam_member` en vez de un binding de
// proyecto: así `sa-generador` puede leer la clave HMAC pero NO las
// contraseñas de la base de datos. Un `roles/secretmanager.secretAccessor` a
// nivel de proyecto le habría dado acceso a todo.

// Quién necesita la clave HMAC:
//   generador -> tokeniza cc_num antes de publicar la transacción
//   registro  -> valida/recalcula el token al recibirla
//   flink     -> el job batch de perfiles hashea los cc_num de fraudTrain para
//                escribir las claves `perfil:{cc_num_hash}` en Redis. Si no
//                usara la MISMA clave, los hashes no coincidirían con los de
//                `cuentas` y Flink nunca encontraría el perfil de nadie.
resource "google_secret_manager_secret_iam_member" "hmac_lectores" {
  for_each = toset(["generador", "registro", "flink"])

  secret_id = google_secret_manager_secret.hmac_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.componentes[each.value].email}"
}

// Cada servicio lee solo la contraseña del rol de base de datos que le toca.
locals {
  password_por_servicio = {
    registro = "app_registro"
    cierre   = "app_cierre"
    agente   = "agente_ro"
    frontend = "frontend_ro"
  }
}

resource "google_secret_manager_secret_iam_member" "password_lectores" {
  for_each = local.password_por_servicio

  secret_id = google_secret_manager_secret.roles_db[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.componentes[each.key].email}"
}

// ---------------------------------------------------------------------------
// Roles de proyecto — el mínimo que cada componente necesita
// ---------------------------------------------------------------------------

locals {
  // Mapa plano "componente|rol" para poder usar for_each con claves únicas.
  roles_componentes = merge(
    // Generador: publica a Pub/Sub (vía el servicio de registro por HTTP) y
    // escribe logs.
    { for r in [
      "roles/logging.logWriter",
      "roles/run.invoker", // invoca el servicio de registro
    ] : "generador|${r}" => { componente = "generador", rol = r } },

    // Registro: publica las preseleccionadas y conecta a Cloud SQL.
    { for r in [
      "roles/pubsub.publisher",
      "roles/cloudsql.client",
      "roles/logging.logWriter",
    ] : "registro|${r}" => { componente = "registro", rol = r } },

    // Cierre: consume veredictos y actualiza Cloud SQL.
    { for r in [
      "roles/pubsub.subscriber",
      "roles/cloudsql.client",
      "roles/logging.logWriter",
    ] : "cierre|${r}" => { componente = "cierre", rol = r } },

    // Flink: consume preseleccionadas, publica veredictos, usa el bucket de
    // checkpoints y necesita ser worker de Dataproc.
    { for r in [
      "roles/pubsub.subscriber",
      "roles/pubsub.publisher",
      "roles/dataproc.worker",
      "roles/logging.logWriter",
    ] : "flink|${r}" => { componente = "flink", rol = r } },

    // Agente: invoca Gemini en Vertex AI y lee Cloud SQL en solo lectura.
    { for r in [
      "roles/aiplatform.user",
      "roles/cloudsql.client",
      "roles/logging.logWriter",
    ] : "agente|${r}" => { componente = "agente", rol = r } },

    // Frontend: lee Cloud SQL y consulta BigQuery para el tablero.
    { for r in [
      "roles/cloudsql.client",
      "roles/bigquery.dataViewer",
      "roles/bigquery.jobUser",
      "roles/logging.logWriter",
    ] : "frontend|${r}" => { componente = "frontend", rol = r } },
  )
}

resource "google_project_iam_member" "componentes" {
  for_each = local.roles_componentes

  project = var.project_id
  role    = each.value.rol
  member  = "serviceAccount:${google_service_account.componentes[each.value.componente].email}"
}
