// ============================================================================
// Red — VPC, Private Service Access y Cloud NAT
// ============================================================================
//
// POR QUÉ HACE FALTA UNA RED PROPIA
//
// El Sprint 1 no declaraba nada de red: todo era serverless y hablaba por
// internet público. El Sprint 2 introduce dos servicios que NO funcionan así:
//
//   - Memorystore (Redis) solo tiene IP privada. Para que alguien le hable,
//     ese alguien tiene que estar en la misma VPC, y la VPC tiene que tener un
//     rango reservado para servicios gestionados de Google (eso es Private
//     Service Access).
//   - Dataproc corre en VM reales dentro de una subred.
//
// Se crea una VPC propia en lugar de usar la `default`. La red default trae
// reglas de firewall permisivas preconfiguradas (entre ellas SSH abierto al
// mundo en algunos proyectos) y su rango no se controla. Para un proyecto que
// maneja una base de datos, aunque sea con datos sintéticos, una red explícita
// es más defendible y además es lo que se puede mostrar como decisión de
// arquitectura.

resource "google_compute_network" "vpc" {
  name                    = "neobanx-vpc"
  auto_create_subnetworks = false
  description             = "VPC de NeobanX: Dataproc y Memorystore. Subredes explícitas, sin las reglas permisivas de la red default."

  depends_on = [google_project_service.apis]
}

resource "google_compute_subnetwork" "principal" {
  name          = "neobanx-subnet-${var.region}"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc.id

  // Necesario para que las VM de Dataproc puedan alcanzar APIs de Google
  // (Pub/Sub, Storage, Secret Manager) sin IP pública.
  private_ip_google_access = true

  // Deja rastro de las conexiones para poder diagnosticar por qué Flink no
  // alcanza Redis, que es el fallo más probable al montar esto.
  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

// ---------------------------------------------------------------------------
// Private Service Access — requisito de Memorystore
// ---------------------------------------------------------------------------
//
// Google aloja Redis en un proyecto suyo (un "productor de servicios") y lo
// conecta a tu VPC por peering. Para eso hay que cederle de antemano un rango
// de IP que no choque con tus subredes. Eso es lo que hacen estos dos
// recursos: reservar el rango y crear el peering.
//
// Aprovisionar el peering puede tomar varios minutos la primera vez.

resource "google_compute_global_address" "psa_rango" {
  name          = "neobanx-psa-rango"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id

  // /16 separado del /20 de la subred para que no haya solapamiento.
  address = "10.20.0.0"
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_rango.name]

  depends_on = [google_project_service.apis]
}

// ---------------------------------------------------------------------------
// Cloud NAT — salida a internet sin IP públicas
// ---------------------------------------------------------------------------
//
// Las VM de Dataproc se crean sin IP pública (ver dataproc.tf). Sin NAT no
// podrían salir a internet, y el enriquecimiento de Flink consulta la API
// externa de Nager.Date para la bandera de festivo. `private_ip_google_access`
// solo cubre APIs de Google, no terceros, así que el NAT es lo que permite esa
// llamada.
//
// La alternativa (darle IP pública a cada VM) expondría los nodos
// innecesariamente.

resource "google_compute_router" "router" {
  name    = "neobanx-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name   = "neobanx-nat"
  router = google_compute_router.router.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

// ---------------------------------------------------------------------------
// Firewall
// ---------------------------------------------------------------------------
//
// Reglas mínimas y explícitas. No se abre SSH al mundo (0.0.0.0/0): para
// entrar a un nodo de Dataproc se usa
// `gcloud compute ssh --tunnel-through-iap`, que no requiere IP pública ni
// puerto abierto.

// Dataproc necesita que sus nodos se hablen entre sí sin restricción de
// puerto: el maestro coordina a los workers por varios puertos dinámicos.
resource "google_compute_firewall" "interno" {
  name        = "neobanx-permitir-interno"
  network     = google_compute_network.vpc.name
  description = "Tráfico entre nodos del clúster de Dataproc."

  source_ranges = [google_compute_subnetwork.principal.ip_cidr_range]

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }
}

// Acceso administrativo por IAP (Identity-Aware Proxy). 35.235.240.0/20 es el
// rango fijo desde el que IAP origina las conexiones; permitirlo no abre el
// puerto a internet, porque IAP exige autenticación IAM antes de reenviar.
resource "google_compute_firewall" "iap_ssh" {
  name        = "neobanx-permitir-ssh-iap"
  network     = google_compute_network.vpc.name
  description = "SSH solo a través de IAP, nunca desde internet abierto."

  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
