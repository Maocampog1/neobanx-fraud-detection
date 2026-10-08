// ============================================================================
// Variables de entrada
// ============================================================================
//
// CAMBIO IMPORTANTE FRENTE AL SPRINT 1
//
// Ya NO existen las variables `db_password` ni `generator_salt`. En el Sprint 1
// cada persona las escribía en su `.env`, `bootstrap.sh` las copiaba a
// `terraform.tfvars`, y había que compartirlas por un documento aparte. Eso
// significaba secretos circulando por chat y el riesgo de que dos personas
// desplegaran con valores distintos (lo que rompía los hashes de `cc_num`).
//
// Ahora Terraform GENERA todas las contraseñas y la clave HMAC, y las guarda en
// Secret Manager (ver secrets.tf). Los servicios las leen de ahí en tiempo de
// ejecución. Nadie tiene que conocerlas ni pasárselas.

variable "project_id" {
  description = "ID del proyecto de GCP."
  type        = string
  default     = "neobanx-fraud-detection"
}

variable "region" {
  description = "Región principal para todos los recursos regionales."
  type        = string
  default     = "us-central1"
}

variable "zona" {
  description = <<-EOT
    Zona para el clúster de Dataproc. Déjala VACÍA (el default) para usar la
    colocación automática: Dataproc elige una zona de la región que tenga
    capacidad disponible.

    Por qué el default es vacío y no una zona concreta: fijar `us-central1-a`
    hizo fallar el primer despliegue con
    `ZONE_RESOURCE_POOL_EXHAUSTED` — Google no tenía capacidad de
    `n2-standard-2` en esa zona en ese momento. Es un fallo transitorio pero
    puede durar horas, y cambiar a otra zona fija solo mueve el problema. Con
    colocación automática, Dataproc busca una zona con capacidad por su cuenta.

    Solo conviene fijarla si hace falta que el clúster quede en la misma zona
    que otro recurso zonal.
  EOT
  type        = string
  default     = ""
}

variable "dataset_url" {
  description = <<-EOT
    URL pública del CSV de entrenamiento (fraudTrain). Lo usa el generador
    para descargarlo si no lo tiene en disco, de modo que reproducir el repo no
    exija bajar nada de Kaggle a mano.
  EOT
  type        = string
  default     = "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTrain.csv"
}

variable "dataset_test_url" {
  description = <<-EOT
    URL pública del CSV de prueba (fraudTest). El generador del Sprint 2 lee
    este archivo y no fraudTrain, para que el histórico cargado en Cloud SQL y
    el stream en vivo no sean los mismos registros.
  EOT
  type        = string
  default     = "https://storage.googleapis.com/neobanx-fraud-detection-datasets/fraudTest.csv"
}

// --- Cloud SQL ---------------------------------------------------------------

// --- BigQuery y Datastream ---------------------------------------------------

variable "bq_location" {
  description = <<-EOT
    Ubicación de los datasets de BigQuery. `US` (multirregión) es compatible
    con `us-central1` y es donde estaba el dataset del Sprint 1.

    Ojo: la ubicación de un dataset NO se puede cambiar después de crearlo. Si
    se modifica esta variable, Terraform tiene que destruir y recrear los
    datasets, perdiendo su contenido.
  EOT
  type        = string
  default     = "US"
}

variable "bq_data_freshness" {
  description = <<-EOT
    Segundos de retraso máximo con que Datastream consolida los cambios en
    BigQuery. Es el principal mando de costo/latencia de la replicación: más
    fresco significa más operaciones de merge, y cada merge se cobra.

    300 s (5 min) es un punto medio razonable para la demo: suficiente para que
    el dashboard se sienta vivo, sin pagar la consolidación continua que exigiría
    un valor cercano a 0.

    No confundir con el SLA de detección de fraude (< 5 s): ese se cumple en el
    flujo transaccional (Cloud SQL), que es donde se bloquea una transacción.
    BigQuery es la capa analítica y no está en el camino crítico de la decisión.
  EOT
  type        = number
  default     = 300
}

variable "datastream_ips_override" {
  description = <<-EOT
    IP públicas de Datastream a autorizar en Cloud SQL. Normalmente se deja
    vacío y se usan las de `local.datastream_ips` según la región.

    Solo hace falta llenarlo si se despliega en una región que no esté en ese
    mapa. Las direcciones de cada región están publicadas en:
    https://cloud.google.com/datastream/docs/ip-allowlists-and-regions
  EOT
  type        = list(string)
  default     = []
}

locals {
  // IP públicas desde las que Datastream origina sus conexiones, por región.
  // Datastream no soporta el Cloud SQL Auth Proxy, así que estas direcciones
  // son la única excepción al cierre de `authorized_networks`.
  //
  // Son /32 concretas, no un rango abierto: muy distinto del 0.0.0.0/0 que
  // tenía el Sprint 1.
  //
  // Fuente oficial (verificar si cambian):
  // https://cloud.google.com/datastream/docs/ip-allowlists-and-regions
  datastream_ips_por_region = {
    "us-central1" = ["34.72.28.29", "34.67.234.134", "34.67.6.157", "34.72.239.218", "34.71.242.81"]
    "us-east1"    = ["34.74.216.163", "34.75.166.194", "104.196.6.24", "34.73.50.6", "35.237.45.20"]
    "us-east4"    = ["35.245.110.238", "34.85.182.28", "34.150.213.121", "34.150.171.115", "34.145.160.237"]
  }

  datastream_ips = length(var.datastream_ips_override) > 0 ? var.datastream_ips_override : lookup(local.datastream_ips_por_region, var.region, [])
}

// --- Dataproc ----------------------------------------------------------------

variable "dataproc_machine_type" {
  description = <<-EOT
    Tipo de máquina de los nodos de Dataproc (maestro y workers).

    El default es `e2-standard-2` por dos razones, ambas aprendidas en el
    primer despliegue:

      1. DISPONIBILIDAD. Con `n2-standard-2` el clúster falló con
         ZONE_RESOURCE_POOL_EXHAUSTED en us-central1-a y, tras activar la
         colocación automática, volvió a fallar en us-central1-f: la familia
         N2 estaba escasa en toda la región. La familia E2 es la más común y
         la que más capacidad tiene disponible.

      2. COSTO. E2 es la familia optimizada en costo de Compute Engine y sale
         más barata que N2 con los mismos 2 vCPU y 8 GB. Dado que este clúster
         es el recurso más caro del proyecto, es el ajuste de costo con más
         impacto.

    2 vCPU es el mínimo que admite Dataproc para nodos de un clúster estándar.
  EOT
  type        = string
  default     = "e2-standard-2"
}

variable "db_tier" {
  description = <<-EOT
    Tipo de máquina de Cloud SQL. `db-custom-2-8192` (2 vCPU / 8 GB) es lo que
    se usó en el Sprint 1 y es generoso para datos sintéticos; se deja como
    variable para poder bajarlo si los créditos educativos aprietan.
  EOT
  type        = string
  default     = "db-custom-2-8192"
}

variable "db_nombre" {
  description = "Nombre de la base de datos lógica."
  type        = string
  default     = "neobanx"
}

variable "db_instancia" {
  description = "Nombre de la instancia de Cloud SQL."
  type        = string
  default     = "neobanx-transaccional"
}

// --- Flujo transaccional -----------------------------------------------------

variable "timeout_veredicto_segundos" {
  description = <<-EOT
    Tiempo que el servicio de cierre espera un veredicto antes de cerrar la
    transacción como `no_preseleccionada_timeout`.

    El valor definitivo se calibra midiendo la latencia real con Flink
    corriendo (p99 + margen), según el plan del sprint. Este default es solo un
    punto de partida para que el flujo funcione end-to-end.
  EOT
  type        = number
  default     = 30
}

variable "umbral_monto_preseleccion" {
  description = "Monto por encima del cual una transacción se preselecciona siempre."
  type        = number
  default     = 200
}

variable "probabilidad_muestreo" {
  description = <<-EOT
    Probabilidad (0 a 1) de preseleccionar una transacción que no supera el
    umbral de monto. Mantiene un flujo de análisis constante aunque no haya
    montos altos.
  EOT
  type        = number
  default     = 0.15

  validation {
    condition     = var.probabilidad_muestreo >= 0 && var.probabilidad_muestreo <= 1
    error_message = "probabilidad_muestreo debe estar entre 0 y 1."
  }
}

// --- Operación ---------------------------------------------------------------

// NOTA — no existe una variable para fijar la clave HMAC, a propósito.
// Se consideró y se descartó: ver la explicación en secrets.tf, sección
// "Alternativa descartada".

variable "correo_alertas" {
  description = <<-EOT
    Correo que recibe las alertas de monitoreo (mensajes en DLQ, errores de
    Cloud Run, pendientes vencidas, presupuesto).

    Viene del `.env` de cada persona (`ALERT_EMAIL`), no fijo en el código: si
    estuviera hardcodeado, quien reproduzca el repo recibiría alertas de un
    despliegue ajeno o no recibiría ninguna.

    Si queda vacío, no se crea el canal de notificación y las políticas de
    alerta se crean sin destinatario. El despliegue funciona igual.
  EOT
  type        = string
  default     = ""
}

variable "billing_account" {
  description = <<-EOT
    ID de la cuenta de facturación, para crear la alerta de presupuesto.
    Formato: `XXXXXX-XXXXXX-XXXXXX`.

    Se obtiene con: `gcloud billing accounts list`

    OJO — permisos distintos: los presupuestos viven en la cuenta de
    facturación, no en el proyecto. Tener Owner del proyecto NO alcanza; hace
    falta `roles/billing.costsManager` sobre la cuenta de facturación, que solo
    puede conceder quien la administre.

    Si se deja vacío, el presupuesto se omite y el resto del despliegue
    funciona igual. Vale la pena llenarlo desde el primer despliegue: Dataproc,
    Redis y Cloud SQL cobran por tiempo encendido, así que el presupuesto es la
    red de seguridad contra un recurso olvidado.
  EOT
  type        = string
  default     = ""
}

variable "presupuesto_mensual_usd" {
  description = "Monto mensual del presupuesto, en USD enteros. Dispara avisos al 50 %, 90 % y 100 % pronosticado."
  type        = number
  default     = 100
}
