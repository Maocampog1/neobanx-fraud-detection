# Arquitectura — NeobanX (Detección de Fraude en Streaming)
 
<img width="1311" height="779" alt="image" src="https://github.com/user-attachments/assets/f765937d-8d69-40b8-8116-26ce8de71ea4" />

 
## Leyenda de componentes
 
### Flujo Transaccional
 
| Componente | Qué hace |
|---|---|
| **Generador de transacción (Python)** | Cloud Function invocada por Cloud Scheduler cada 4 segundos; toma una transacción del dataset base y la expone como respuesta de una API. |
| **Preselección de análisis** | Cloud Function que decide si una transacción se analiza (muestreo aleatorio o si el monto supera un umbral). Si se selecciona, la envía en paralelo a "Espera veredicto" y al Pub/Sub de inicio del flujo de análisis; si no, la envía directo a Cloud SQL. |
| **Espera veredicto del flujo de detección** | Cloud Function que retiene la transacción preseleccionada a la espera del veredicto, con un timeout: si no llega a tiempo, la transacción se persiste como "no preseleccionada". |
| **Cloud SQL (PostgreSQL)** | Base de datos transaccional donde se guardan todas las transacciones, preseleccionadas o no, con su estado final. |
 
### Flujo Analítico y de Detección
 
| Componente | Qué hace |
|---|---|
| **Pub/Sub — Transacciones preseleccionadas** | Cola que recibe las transacciones seleccionadas para análisis, garantizando que no se pierdan si el flujo de detección está caído o saturado. |
| **Redis / Memorystore** | Almacén de baja latencia con el perfil histórico de cada cliente (montos promedio, ubicaciones frecuentes), consultado durante el enriquecimiento. |
| **API Nager.Date** | Servicio externo que indica si la fecha de la transacción es festivo en Colombia; se usa como una de las reglas de detección. |
| **Spark Structured Streaming (Dataproc)** | Job de streaming que consume las transacciones del Pub/Sub, las enriquece con el perfil del cliente y la bandera de festivo, y aplica las reglas de fraude. |
| **Veredicto de la transacción** | Cloud Function que formaliza el resultado del análisis (aprobada o alerta) y lo publica en dos Pub/Sub distintos: uno hacia el flujo transaccional, otro hacia analítica. |
| **Pub/Sub — Veredicto hacia flujo transaccional** | Cola que entrega el veredicto de vuelta a "Espera veredicto", para que la transacción se actualice con su estado final. |
| **Pub/Sub — Veredicto hacia analítica** | Cola que entrega el veredicto hacia BigQuery, de forma independiente al envío hacia el flujo transaccional. |
| **BigQuery** | Almacena el modelo analítico en estrella con las transacciones que sí pasaron por análisis y su resultado. |
| **Looker Studio** | Dashboard que consume las tablas de BigQuery, mostrando únicamente las transacciones preseleccionadas para análisis. |
 
## Flujo de una transacción
 
Cada 4 segundos, Cloud Scheduler dispara la función **Generador de transacción**, que toma la siguiente transacción del dataset base y la entrega a la función **Preselección de análisis**. Esta función decide si la transacción se analiza — por muestreo aleatorio o porque su monto supera un umbral definido — y a partir de ahí el flujo se bifurca. Si **no** es preseleccionada, se envía directamente a **Cloud SQL** con estado "no preseleccionada", sin pasar por el flujo de análisis. Si **sí** es preseleccionada, se envía simultáneamente a dos destinos: a la función **Espera veredicto**, que la retiene mientras llega una decisión, y al **Pub/Sub de transacciones preseleccionadas**, que marca el inicio del flujo analítico.
 
Del lado analítico, **Spark Structured Streaming sobre Dataproc** consume la transacción desde ese Pub/Sub, la enriquece consultando el perfil histórico del cliente en **Redis/Memorystore** y la bandera de día festivo desde **Nager.Date**, y aplica las reglas de detección de fraude. El resultado enriquecido llega a la función **Veredicto de la transacción**, que formaliza si la transacción queda aprobada o genera una alerta, y publica ese resultado en dos Pub/Sub en paralelo: uno regresa al flujo transaccional, y el otro va hacia **BigQuery** para alimentar el dashboard de **Looker Studio** (que solo muestra transacciones que pasaron por análisis).
 
De vuelta en el flujo transaccional, la función **Espera veredicto** recibe el veredicto desde su Pub/Sub y lo compara con la transacción que tiene retenida; si coincide, actualiza el estado con el resultado del análisis (aprobada / bloqueada) y lo persiste en **Cloud SQL**. Si el veredicto no llega dentro del tiempo límite establecido, la función deja de esperar y persiste la transacción en Cloud SQL como "no preseleccionada" — y si el veredicto llega después de ese punto, se descarta, porque esa transacción ya quedó resuelta.
