// ============================================================================
// Pub/Sub — las dos colas que conectan los flujos
// ============================================================================
//
// La arquitectura tiene dos flujos (transaccional y analítico) unidos SOLO por
// Pub/Sub, para que la caída de uno no haga perder datos del otro:
//
//   registro ──> tx-preseleccionadas ──> Flink
//   Flink    ──> tx-veredictos       ──> cierre
//
// Cada suscripción tiene cola de mensajes muertos (DLQ). Sin DLQ, un mensaje
// que falla se reintenta indefinidamente y puede atascar el procesamiento; con
// DLQ, después de N intentos se aparta y queda visible para diagnóstico. La
// alerta de monitoreo se dispara cuando llega algo a una DLQ.

// ---------------------------------------------------------------------------
// Topics principales
// ---------------------------------------------------------------------------

resource "google_pubsub_topic" "preseleccionadas" {
  name = "tx-preseleccionadas"

  labels = {
    flujo      = "analitico"
    gestionado = "terraform"
  }

  // Retención: permite reprocesar (replay) si el job de Flink se cae y hay que
  // volver a leer desde un punto anterior.
  message_retention_duration = "86600s" // ~24 h

  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "veredictos" {
  name = "tx-veredictos"

  labels = {
    flujo      = "transaccional"
    gestionado = "terraform"
  }

  message_retention_duration = "86600s"

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// Topics de mensajes muertos
// ---------------------------------------------------------------------------

resource "google_pubsub_topic" "preseleccionadas_dlq" {
  name = "tx-preseleccionadas-dlq"

  labels = {
    flujo      = "analitico"
    tipo       = "dlq"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

resource "google_pubsub_topic" "veredictos_dlq" {
  name = "tx-veredictos-dlq"

  labels = {
    flujo      = "transaccional"
    tipo       = "dlq"
    gestionado = "terraform"
  }

  depends_on = [google_project_service.apis]
}

// Una suscripción por DLQ: sin suscriptor, los mensajes que llegan a un topic
// de Pub/Sub se descartan. Es decir, sin esto la DLQ no retendría nada y el
// propósito de tenerla se perdería.
resource "google_pubsub_subscription" "preseleccionadas_dlq" {
  name  = "sub-preseleccionadas-dlq"
  topic = google_pubsub_topic.preseleccionadas_dlq.name

  message_retention_duration = "604800s" // 7 días, el máximo
  retain_acked_messages      = false
  ack_deadline_seconds       = 60
}

resource "google_pubsub_subscription" "veredictos_dlq" {
  name  = "sub-veredictos-dlq"
  topic = google_pubsub_topic.veredictos_dlq.name

  message_retention_duration = "604800s"
  retain_acked_messages      = false
  ack_deadline_seconds       = 60
}

// ---------------------------------------------------------------------------
// Suscripciones de trabajo
// ---------------------------------------------------------------------------

// La lee el job de Flink.
resource "google_pubsub_subscription" "flink_preseleccionadas" {
  name  = "sub-flink-preseleccionadas"
  topic = google_pubsub_topic.preseleccionadas.name

  // Holgado porque el enriquecimiento consulta Redis y Nager.Date antes de
  // resolver; si el ack venciera durante el enriquecimiento, Pub/Sub
  // reentregaría el mensaje y se evaluaría dos veces.
  ack_deadline_seconds = 60

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.preseleccionadas_dlq.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }
}

// La lee el servicio de cierre (pull).
resource "google_pubsub_subscription" "cierre_veredictos" {
  name  = "sub-cierre-veredictos"
  topic = google_pubsub_topic.veredictos.name

  // El cierre hace un UPDATE condicional y confirma el ack DESPUÉS del commit.
  // 60 s da margen de sobra para eso.
  ack_deadline_seconds = 60

  // Permite reprocesar veredictos recientes si el servicio de cierre estuvo
  // caído un rato.
  message_retention_duration = "86600s"

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.veredictos_dlq.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
}

// Suscripción para el stub de veredicto: una regla simple que cierra el flujo
// transaccional mientras el job de Flink no esté listo. Permite probar el
// flujo completo sin depender de Dataproc, y se apaga cuando Flink entra.
resource "google_pubsub_subscription" "stub_preseleccionadas" {
  name  = "sub-stub-preseleccionadas"
  topic = google_pubsub_topic.preseleccionadas.name

  ack_deadline_seconds = 30

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.preseleccionadas_dlq.id
    max_delivery_attempts = 5
  }
}

// ---------------------------------------------------------------------------
// Permiso para que el reenvío a DLQ funcione
// ---------------------------------------------------------------------------
//
// Detalle fácil de pasar por alto: la `dead_letter_policy` no la ejecuta el
// suscriptor, la ejecuta el propio servicio de Pub/Sub usando su agente de
// servicio. Si ese agente no puede publicar en el topic de DLQ ni confirmar
// mensajes en la suscripción de origen, la política se declara pero NUNCA
// mueve nada: los mensajes fallidos siguen reintentándose para siempre.

data "google_project" "actual" {}

locals {
  agente_pubsub = "serviceAccount:service-${data.google_project.actual.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  for_each = {
    preseleccionadas = google_pubsub_topic.preseleccionadas_dlq.name
    veredictos       = google_pubsub_topic.veredictos_dlq.name
  }

  topic  = each.value
  role   = "roles/pubsub.publisher"
  member = local.agente_pubsub
}

resource "google_pubsub_subscription_iam_member" "dlq_subscriber" {
  for_each = {
    flink  = google_pubsub_subscription.flink_preseleccionadas.name
    cierre = google_pubsub_subscription.cierre_veredictos.name
    stub   = google_pubsub_subscription.stub_preseleccionadas.name
  }

  subscription = each.value
  role         = "roles/pubsub.subscriber"
  member       = local.agente_pubsub
}
