# Sprint 2 — Bloque 2 (Juan) — Seguimiento

> Checklist de trabajo en progreso. Se actualiza a medida que avanzamos.
> Plan completo y razones de cada decisión en el plan aprobado de la sesión
> (si hace falta releer el detalle técnico, pedirlo).

## Paso 0 — Preparación

- [X] Imagen Docker reconstruida (`cloud-sql-proxy` + `python3` confirmados)
- [X] Estado local de Terraform borrado (`.tfstate*`, `.terraform/`, incluido el residuo de `bamboo-test`)
- [X] `.env` actualizado (`DB_PASSWORD`/`GENERATOR_SALT`/`TOPIC_ID` fuera; `ALERT_EMAIL`, `BILLING_ACCOUNT`, `BUDGET_USD` dentro)
- [X] Verificado `roles/billing.costsManager` en la cuenta de facturación para `juanes1771@gmail.com`

## Fase local (sin costo de nube)

- [x] Contratos v2 en `/contracts` (evento transacción con `cc_num_hash` de 64 chars, evento veredicto) — probados con pydantic en local, incluyendo caso de validación que debe fallar
- [x] `Backend/contrato_datos_generador.md` actualizado a v2
- [X] Generador v2 (`Backend/generador/main.py`): lee `fraudTest`, usa `hmac_util`, HTTP autenticado al registro, `TX_POR_SEGUNDO`, reintentos
- [X] Servicio de registro (`Backend/registro/`): INSERT `recibida`, preselección, `deadline_at`, publish a `tx-preseleccionadas` — probado con Postgres local (`neobanx-pg-local`, puerto 5555) y rol real `app_registro`: a tiempo/sin preselección, preselección por umbral, duplicado (`ON CONFLICT DO NOTHING`), `cc_num_hash` inexistente → 422 sin dejar fila a medias. Historial vía trigger confirmado correcto.
- [X] Generador + registro probados juntos en local (Postgres Docker + `schema.sql`) — 20 transacciones de una muestra real de `fraudTrain.csv`, con `clientes`/`cuentas` cargados vía el mismo patrón de `cargar_maestros.sh` (tablas temporales + JOIN). Resultado: 3 `umbral_monto`, 3 `muestreo_aleatorio`, 14 `sin_analizar`, 0 atascadas en `recibida`, sin duplicados ni violaciones de FK.
- [X] Servicio de cierre (`Backend/cierre/`): pull loop de veredictos + monitor de timeouts con `SKIP LOCKED`, log `{"evento":"pendientes_vencidas","cantidad":N}`
- [X] Cierre probado en local (incluyendo condición de carrera con 2 procesos): veredicto a tiempo (`tardio=false`), timeout puro (monitor cierra 5 pendientes vencidas), veredicto tardío sobre fila ya cerrada (`tardio=true`, estado no cambia), y `SKIP LOCKED` confirmado con una fila bloqueada manualmente en otra sesión de `psql` (el monitor no esperó el lock, la cerró en la corrida siguiente tras liberarse). `/salud` y arranque sin `GOOGLE_CLOUD_PROJECT` (modo local) verificados.
- [X] Stub de veredicto (`Backend/stub_veredicto/`): regla baseline (monto alto / categoría de riesgo), llena `reglas_disparadas`, retraso configurable vía `RETRASO_SEGUNDOS`, `version_reglas="stub-v1"`
- [X] Stub probado en local: 4 casos de la regla (aprobada, monto alto, categoría riesgo, categoría riesgo sin disparar), callback completo con retraso simulado + `ack`, y mensaje corrupto → `nack` sin crashear. `/salud` y arranque sin `GOOGLE_CLOUD_PROJECT` verificados.
- [X] `scripts/test.sh` v2 diseñado (5 casos + carga sostenida) y pasando contra el stack local (Postgres Docker + emulador de Pub/Sub, generador+registro+stub+cierre reales corriendo juntos). Fixture committeado en `scripts/fixtures/carga_local.csv` (100 filas reales de `fraudTrain.csv`).

## Fase nube — sesión 1 (registro + cierre + stub)

- [ ] `Infrastructure/run.tf` escrito (3 `google_cloud_run_v2_service`, `deletion_protection=false`)
- [ ] `terraform apply` — **confirmar NO al migrar estado local** si pregunta
- [ ] `test.sh` corrido contra la nube real — 5 casos + carga sostenida pasando
- [ ] `cierre`/`stub` apagados o destruidos al terminar la sesión (cobran por estar encendidos)

## Fase Flink

- [ ] Investigación: cómo se somete un job a Dataproc con componente Flink (sin cluster encendido)
- [ ] Lógica de reglas en PyFlink local (MiniCluster): monto vs. promedio, ráfaga, ubicación imposible, monto alto en festivo
- [ ] Enriquecimiento: festivo (Nager.Date, reutiliza `holidays.py`) probado en local
- [ ] Enriquecimiento: perfil de Redis (Async I/O) — diseño listo antes de encender Dataproc
- [ ] Clúster Dataproc encendido, job sometido, confirmado `RUNNING`
- [ ] Veredictos de Flink llegando con `reglas_disparadas` lleno
- [ ] Stub apagado (ya no hace falta con Flink corriendo)
- [ ] Dataproc destruido al terminar

## Verificación final del bloque

- [ ] `test.sh` completo pasando contra la nube real
- [ ] Ningún `cc_num` en texto plano en logs del generador
- [ ] `destroy.sh` corrido — nada quedó encendido de más
