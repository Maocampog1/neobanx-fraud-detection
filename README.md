# Plataforma de Detección de Fraude en Tiempo Real para NeobanX
 
Proyecto de la trayectoria en Ingeniería de Datos — Universidad EAFIT
Asignatura: SI4002 - Proyecto de Ingeniería de Datos
Semestre: 2026-2
 
## Descripción
 
NeobanX es un neobanco digital ficticio (caso de estudio simulado) que actualmente detecta transacciones fraudulentas de forma tardía, después de que la operación ya se completó. Este proyecto diseña e implementa una arquitectura de datos en streaming sobre GCP capaz de ingerir, enriquecer y evaluar cada transacción en el momento en que ocurre, reduciendo tanto las pérdidas económicas como los bloqueos injustificados a clientes legítimos.
 
## Equipo
 
| Nombre | Rol |
|---|---|
| Juan Esteban Alzate | Arquitecto de Datos / Líder Técnico |
| Camilo Salazar Acevedo | Ingeniero de Datos |
| María Alejandra Ocampo | Responsable de Gobernanza |
 
## Arquitectura
 
```
Fuentes ──▶ Ingesta ──▶ Procesamiento ──▶ Almacenamiento ──▶ Visualización
```
 
| Capa | Tecnología | Rol |
|---|---|---|
| Fuentes | Dataset Sparkov (Kaggle), API Nager.Date | Base de transacciones y perfil de cliente; calendario de festivos |
| Ingesta | Google Pub/Sub | Streaming de eventos de transacciones, publicados respetando la cadencia temporal original |
| Procesamiento | Dataproc / Spark Structured Streaming | Enriquecimiento (perfil del cliente, festivo) y aplicación de reglas de detección de fraude |
| Almacenamiento — Transaccional | Cloud SQL (PostgreSQL) | Registro y bloqueo de operaciones con garantías ACID |
| Almacenamiento — Analítico | BigQuery (modelo en estrella) | Consultas agregadas para el dashboard |
| Almacenamiento — Distribuido | Redis / Memorystore | Perfil del cliente en clave-valor, consultas de baja latencia durante el streaming |
| Visualización | Looker Studio | Dashboard de estadísticas de fraude |
 
## Fuentes de datos
 
1. **Dataset base de transacciones — Sparkov** ([Kaggle](https://www.kaggle.com/datasets/kartik2112/fraud-detection/data)): dataset sintético de transacciones con tarjeta de crédito, incluye transacción, perfil de cliente y geolocalización en un solo registro.
2. **Generador de streaming propio**: script en Python que ordena el dataset por `trans_date_trans_time`/`unix_time` y publica cada evento a Pub/Sub respetando los intervalos de tiempo reales.
3. **API Nager.Date** (`date.nager.at`): calendario de festivos de Colombia, cacheado para enriquecer las reglas de detección.
## Modelos de datos
 
El proyecto implementa tres modelos, cada uno resolviendo un requisito técnico distinto:
 
- **Transaccional (ER, normalizado)**: clientes, cuentas, transacciones, alertas — con integridad referencial y transacciones ACID.
- **Analítico (estrella)**: tabla de hechos de transacciones con dimensiones de cliente, tiempo, ubicación y canal.
- **Distribuido (clave-valor)**: perfil histórico del cliente en Redis, para lecturas de baja latencia durante el streaming.
## KPIs y SLAs
 
| Pregunta de Negocio | KPI | SLA Técnico |
|---|---|---|
| ¿Detectamos el fraude a tiempo? | % de transacciones fraudulentas detectadas en tiempo real | Latencia del pipeline < 5 segundos |
| ¿Cuántos clientes buenos bloqueamos por error? | % de falsos positivos | Precisión de las reglas de detección en Spark |
| ¿Qué operación es más riesgosa? | Ranking de operaciones por tasa de fraude | Tiempo de respuesta del dashboard < 5 segundos |
| ¿Los datos son confiables? | % de transacciones con datos completos | Completitud de datos > 95% |
 
## Metodología
 
El proyecto sigue una cadencia ágil (Scrum) apoyada en CRISP-DM (comprensión del dominio y los datos), DataOps (versionamiento y monitoreo básico del pipeline) y DAMA-DMBOK (gobernanza de datos, a nivel introductorio).
 
## Cronograma
 
| Sprint | Semanas | Entregable |
|---|---|---|
| Sprint 0 | 1 – 3 | Propuesta de proyecto |
| Sprint 1 | 4 – 7 | Producto Alfa (Walking Skeleton) |
| Sprint 2 | 8 – 15 | Producto Beta (modelado + gobernanza) |
| Sprint Final | 16 – 17 | Producto Final (dashboard + sustentación) |
 
## Alcance
 
**Incluye:** arquitectura de datos en GCP, ingesta streaming desde 3 fuentes, procesamiento con Spark Structured Streaming, los tres modelos de datos descritos arriba, gobernanza básica (diccionario, linaje, calidad), y dashboard en Looker Studio.
 
**No incluye:** entrenamiento de modelos de ML/DL, desarrollo de frontend/backend para el neobanco, implementación completa de DAMA-DMBOK, ni conexión con datos financieros reales.
 
## Referencias
 
- SCARFF: Scalable Real-time Fraud Finder — [arxiv.org/pdf/1709.08920](https://arxiv.org/pdf/1709.08920)
- Detección de Fraude en Tiempo Real con Spark: Micro-Batch vs. Continuo — [gprjournals.org](https://gprjournals.org/journals/index.php/ajt/article/view/465)
- Credit Card Fraud Detection con PySpark — [github.com/Akak0o0y/credit-card-fraud-detection-spark](https://github.com/Akak0o0y/credit-card-fraud-detection-spark)
