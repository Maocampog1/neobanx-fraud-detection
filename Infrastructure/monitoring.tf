// ============================================================================
// Monitoreo y control de presupuesto
// ============================================================================
//
// QUÉ SE VIGILA Y POR QUÉ
//
// Tres cosas, elegidas porque son los fallos que se producen EN SILENCIO —
// los que no tumban nada pero hacen que los datos queden mal:
//
//   1. Mensajes en las DLQ. Si un mensaje llega a una cola de muertos, alguna
//      transacción no se procesó. Nada se cae, el sistema sigue andando, y la
//      pérdida solo se nota al cuadrar números después.
//
//   2. Errores en los servicios de Cloud Run. El servicio de cierre es el que
//      resuelve el estado final de cada transacción; si falla, quedan
//      transacciones colgadas en `pendiente_analisis` hasta que el monitor de
//      timeouts las cierre como no analizadas.
//
//   3. El presupuesto. El riesgo más concreto del proyecto: Dataproc, Redis y
//      Cloud SQL cobran por tiempo encendido, no por uso.

// ---------------------------------------------------------------------------
// Canal de notificación
// ---------------------------------------------------------------------------
//
// El correo viene del `.env` de cada persona, no fijo en el código: si
// estuviera hardcodeado, quien reproduzca el repo recibiría alertas de un
// despliegue ajeno, o no recibiría ninguna.
//
// Si `correo_alertas` está vacío, no se crea el canal y las políticas quedan
// sin destinatario. El despliegue funciona igual; simplemente nadie recibe
// aviso.

resource "google_monitoring_notification_channel" "correo" {
  count = var.correo_alertas != "" ? 1 : 0

  display_name = "Alertas NeobanX"
  type         = "email"

  labels = {
    email_address = var.correo_alertas
  }

  depends_on = [google_project_service.apis]
}

locals {
  canales_alerta = var.correo_alertas != "" ? [google_monitoring_notification_channel.correo[0].id] : []
}

// ---------------------------------------------------------------------------
// 1. Mensajes en las colas de muertos
// ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "dlq_con_mensajes" {
  display_name = "DLQ con mensajes sin procesar"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Llegaron mensajes a una cola de mensajes muertos (DLQ), lo que significa
      que al menos una transacción falló 5 veces y se apartó.

      Qué revisar:
        1. Logs del consumidor correspondiente (job de Flink o servicio de cierre).
        2. Contenido del mensaje:
           gcloud pubsub subscriptions pull sub-preseleccionadas-dlq --limit=5 --auto-ack
        3. Si la causa ya está corregida, los mensajes se pueden reinyectar al
           topic original.

      Este fallo NO tumba el sistema: el resto del flujo sigue operando con
      normalidad, y por eso hace falta la alerta para enterarse.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Mensajes retenidos en una DLQ"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"pubsub_subscription\"",
        "metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\"",
        "resource.label.subscription_id = monitoring.regex.full_match(\".*-dlq\")",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.canales_alerta

  alert_strategy {
    // Se cierra solo si la condición deja de cumplirse por 30 minutos, para no
    // recibir una alerta nueva por cada mensaje del mismo incidente.
    auto_close = "1800s"
  }

  depends_on = [
    google_project_service.apis,
    google_pubsub_subscription.preseleccionadas_dlq,
    google_pubsub_subscription.veredictos_dlq,
  ]
}

// ---------------------------------------------------------------------------
// 2. Errores en los servicios de Cloud Run
// ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "cloud_run_errores" {
  display_name = "Errores 5xx en servicios de Cloud Run"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      Un servicio de Cloud Run está devolviendo errores de servidor.

      Si es el servicio de REGISTRO: se están perdiendo transacciones que el
      generador no logra entregar. El generador reintenta con backoff, pero si
      el error persiste las transacciones no entran al sistema.

      Si es el servicio de CIERRE: hay transacciones que no reciben su estado
      final. Van a quedar en `pendiente_analisis` hasta que el monitor de
      timeouts las cierre como `no_preseleccionada_timeout`, es decir, se
      analizaron pero el veredicto se perdió.

      Revisar con:
        gcloud run services logs read SERVICIO --region=${var.region} --limit=50
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Tasa de 5xx por encima del umbral"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "metric.type = \"run.googleapis.com/request_count\"",
        "metric.label.response_code_class = \"5xx\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = local.canales_alerta

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// 3. Transacciones atascadas en pendiente_analisis
// ---------------------------------------------------------------------------
//
// Esta es la alerta más específica del dominio y la más útil para la
// sustentación: mide si la máquina de estados se está quedando trabada.
//
// Se implementa con una métrica basada en logs: el monitor de timeouts del
// servicio de cierre registra cuántas pendientes vencidas encuentra en cada
// pasada, y si ese número crece sostenidamente significa que los veredictos no
// están llegando (Flink caído, o el topic de veredictos sin consumir).
//
// La métrica necesita que el servicio de cierre emita la línea de log
// correspondiente; la escribe Juan Esteban en su bloque. La métrica se declara
// aquí de todas formas para que exista desde el primer despliegue.

resource "google_logging_metric" "pendientes_vencidas" {
  name        = "neobanx/pendientes_vencidas"
  description = "Transacciones que vencieron su deadline sin recibir veredicto, reportadas por el monitor de timeouts."

  filter = join(" AND ", [
    "resource.type = \"cloud_run_revision\"",
    "jsonPayload.evento = \"pendientes_vencidas\"",
  ])

  // Tiene que ser DISTRIBUTION, no INT64: la API de Cloud Logging solo acepta
  // `value_extractor` en métricas de tipo distribución
  // ("A value extractor can only be specified for a DISTRIBUTION value type").
  // Con INT64 solo se puede contar ocurrencias del log, no extraer el valor
  // que reporta — y acá lo que interesa es CUÁNTAS pendientes vencieron, no
  // cuántas veces el monitor escribió una línea.
  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "DISTRIBUTION"
    unit         = "1"
    display_name = "Pendientes vencidas"
  }

  value_extractor = "EXTRACT(jsonPayload.cantidad)"

  // Buckets exponenciales: resuelven con detalle los valores bajos (1, 2, 4
  // pendientes, que es lo normal) y agrupan los altos, que de todos modos
  // significan lo mismo: el flujo de detección no está respondiendo.
  bucket_options {
    exponential_buckets {
      num_finite_buckets = 10
      growth_factor      = 2
      scale              = 1
    }
  }

  depends_on = [google_project_service.apis]
}

// Las métricas basadas en logs no quedan consultables de inmediato: Cloud
// Monitoring tarda en registrarlas en su catálogo. Crear la política de alerta
// justo después falla con:
//
//   Error 404: Cannot find metric(s) that match type =
//   "logging.googleapis.com/user/neobanx/pendientes_vencidas".
//   If a metric was created recently, it could take up to 10 minutes...
//
// Esta espera evita que el `apply` falle por esa carrera. 90 segundos han
// bastado en las pruebas; el mensaje de Google menciona hasta 10 minutos, así
// que si vuelve a fallar el reintento del apply lo resuelve.
resource "time_sleep" "espera_metrica" {
  depends_on      = [google_logging_metric.pendientes_vencidas]
  create_duration = "90s"
}

resource "google_monitoring_alert_policy" "pendientes_vencidas" {
  display_name = "Transacciones venciendo sin veredicto"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      El monitor de timeouts está encontrando transacciones que vencen sin
      recibir veredicto. El flujo transaccional funciona (las cierra como
      `no_preseleccionada_timeout`), pero significa que el flujo de DETECCIÓN
      no está respondiendo.

      Causas probables, en orden:
        1. El job de Flink no está RUNNING. El clúster de Dataproc se
           autodestruye tras 30 minutos sin jobs, así que puede que ya no exista:
             gcloud dataproc clusters list --region=${var.region}
        2. El job corre pero no publica en `tx-veredictos`.
        3. El timeout configurado es más corto que la latencia real del
           análisis. Se calibra midiendo p99 de `finalizada_at - created_at`
           en la vista `linaje_transaccion`.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Pendientes vencidas sostenidas"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"cloud_run_revision\"",
        "metric.type = \"logging.googleapis.com/user/neobanx/pendientes_vencidas\"",
      ])

      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "600s"

      // La métrica es una distribución, así que el alineador tiene que
      // reducirla a un número. Se usa el percentil 99 en vez del máximo para
      // que un pico aislado no dispare la alerta: lo que interesa es un
      // problema sostenido.
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = local.canales_alerta

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [time_sleep.espera_metrica]
}

// ---------------------------------------------------------------------------
// 4. Presupuesto
// ---------------------------------------------------------------------------
//
// EL CONTROL MÁS IMPORTANTE DE TODO ESTE ARCHIVO.
//
// Dataproc, Memorystore y Cloud SQL cobran por TIEMPO ENCENDIDO, no por uso.
// Un clúster olvidado un fin de semana cuesta lo mismo que uno trabajando a
// plena carga.
//
// Requiere permisos sobre la CUENTA DE FACTURACIÓN, que son distintos de los
// del proyecto: tener Owner del proyecto NO alcanza. Si falta el permiso, este
// recurso falla con PERMISSION_DENIED y hay que pedir
// `roles/billing.costsManager` a quien administre la facturación.
//
// Por eso va con `count`: sin `billing_account` configurado, el presupuesto se
// omite y el resto del despliegue sigue funcionando.

data "google_billing_account" "cuenta" {
  count           = var.billing_account != "" ? 1 : 0
  billing_account = var.billing_account
}

resource "google_billing_budget" "presupuesto" {
  count = var.billing_account != "" ? 1 : 0

  billing_account = data.google_billing_account.cuenta[0].id
  display_name    = "Presupuesto NeobanX"

  budget_filter {
    projects = ["projects/${data.google_project.actual.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.presupuesto_mensual_usd)
    }
  }

  // Avisos en escalera: 50 % para enterarse, 90 % para reaccionar, 100 % para
  // apagar cosas. El de 100 % es sobre gasto PRONOSTICADO, así que avisa antes
  // de que el límite se alcance de verdad.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  dynamic "all_updates_rule" {
    for_each = local.canales_alerta

    content {
      monitoring_notification_channels = local.canales_alerta
      disable_default_iam_recipients   = false
    }
  }

  depends_on = [google_project_service.apis]
}
