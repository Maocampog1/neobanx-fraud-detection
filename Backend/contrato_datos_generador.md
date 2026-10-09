# Contratos de datos del flujo transaccional (Sprint 2 — v2)

> Reemplaza la versión v1 de este documento (publicación directa a Pub/Sub al
> tópico `transacciones-neobanx`). Esa versión queda obsoleta junto con el
> `consumidor` viejo — ver `Documentation/CONTEXTO_SPRINT2_NEOBANX.md`.

## Resumen del flujo

```
Generador --HTTP POST autenticado--> Servicio de registro
    (INSERT 'recibida' en Cloud SQL, decide preseleccion)
    --si se preselecciona--> Pub/Sub tx-preseleccionadas
                                  --> Flink (o el stub, mientras tanto)
                                  --> Pub/Sub tx-veredictos
                                  --> Servicio de cierre (UPDATE condicional)
```

Dos contratos, dos mecanismos de transporte distintos:

| Contrato | De → A | Transporte |
|---|---|---|
| Evento de transacción | Generador → Registro | HTTP POST (JSON) |
| Evento de veredicto | Stub/Flink → Cierre | Pub/Sub (`tx-veredictos`) |

Los modelos — la fuente de verdad real, no solo esta descripción — viven en
[`contracts/`](../contracts/): [`transaccion.py`](../contracts/transaccion.py)
y [`veredicto.py`](../contracts/veredicto.py), como clases `pydantic`. Si hay
alguna diferencia entre este documento y el código, **gana el código**.

## Contrato 1 — Evento de transacción (generador → registro)

Los nombres de campo ya coinciden con las columnas de `transacciones` en
`Infrastructure/schema.sql`, para que el registro inserte casi sin traducir.

```json
{
  "trans_num": "0b242abb623afc578575680df30655b9",
  "cc_num_hash": "9f3a7c1e2b5d8046f1a2c3e4b5d6f708192a3b4c5d6e7f8091a2b3c4d5e6f701",
  "comercio": "Rippin, Kub and Mann",
  "categoria": "misc_net",
  "monto": 4.97,
  "fecha_hora_transaccion": "2021-01-01T00:00:18",
  "lat_comercio": 36.011293,
  "long_comercio": -82.048315,
  "is_fraud_real": 0
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `trans_num` | string | Llave de deduplicación/idempotencia. El registro hace `INSERT ... ON CONFLICT DO NOTHING` sobre esta columna. |
| `cc_num_hash` | string, 64 hex | **Cambio frente a v1**: ya no es `sha256(salt+cc_num)` truncado a 10 — es HMAC-SHA256 completo, sin truncar, vía [`Backend/common/hmac_util.hash_cc_num`](../Backend/common/hmac_util.py). La clave la genera Terraform y vive en Secret Manager (`neobanx-hmac-cc-num`); el generador nunca debe traer su propia clave. |
| `comercio` | string | Nombre del comercio (sin el prefijo `fraud_` del dataset original — límpialo antes de enviarlo). |
| `categoria` | string | Tal cual el CSV. |
| `monto` | float, > 0 | Sin formatear ni símbolo de moneda. |
| `fecha_hora_transaccion` | string ISO 8601 | Del CSV. **Nunca** uses `unix_time` — tiene un desfase de ~7 años frente al valor real (hallazgo del perfilamiento, Sprint 1). |
| `lat_comercio` / `long_comercio` | float | Tal cual el CSV (`merch_lat`/`merch_long` en el dataset original). |
| `is_fraud_real` | 0 ó 1 | Se conserva del dataset base **solo para medir falsos positivos** después. **Nunca** es entrada de una regla de detección — usarlo así sería fuga de información (el dato no existiría en un caso real). |

Campos de perfil del cliente (nombre, dirección, trabajo, fecha de
nacimiento, ubicación del hogar) **no van en este mensaje** — ya están
cargados en `clientes`/`cuentas` (Cloud SQL) desde el batch de
`cargar_maestros.py`, y el perfil agregado para las reglas vive en Redis
(`perfil:{cc_num_hash}`), cargado por `perfiles_redis.py`.

## Contrato 2 — Evento de veredicto (stub/Flink → cierre)

Publicado en el tópico `tx-veredictos`, consumido por el servicio de cierre
vía la suscripción `sub-cierre-veredictos`.

```json
{
  "trans_num": "0b242abb623afc578575680df30655b9",
  "resultado": "bloqueada",
  "reglas_disparadas": ["monto_sobre_promedio", "festivo_monto_alto"],
  "evaluado_at": "2021-01-01T00:00:21",
  "version_reglas": "stub-v1"
}
```

| Campo | Tipo | Notas |
|---|---|---|
| `trans_num` | string | FK a `transacciones`. |
| `resultado` | `"aprobada"` \| `"bloqueada"` | Único enum válido — coincide con el CHECK de la columna `resultado` en `veredictos`. |
| `reglas_disparadas` | lista de strings | Identificadores de las reglas que dispararon el resultado. Vacía si `resultado="aprobada"`. Se guarda tal cual en la columna JSONB `reglas_disparadas`. |
| `evaluado_at` | string ISO 8601 | Cuándo se evaluó, no cuándo se publicó el mensaje. |
| `version_reglas` | string | Identifica quién evaluó — `"stub-v1"` mientras el stub esté activo, `"flink-v1"` (o la versión que corresponda) una vez Flink esté corriendo. Sirve para auditar qué reglas produjeron qué veredicto si cambian con el tiempo. |

**No incluye `tardio`** — ese campo lo calcula el propio servicio de cierre
según si la transacción seguía `pendiente_analisis` cuando el veredicto
llegó, no algo que decida quien publica el veredicto.

## Notas importantes que siguen aplicando de v1

- `trans_num` es obligatorio siempre, nunca se omite.
- El `cc_num` real (sin hashear) **nunca** debe aparecer en ningún log, en
  ningún mensaje, en ningún lado — ni siquiera en texto de depuración.
- Usar siempre `fecha_hora_transaccion`/`evaluado_at` para cualquier lógica
  de tiempo, nunca `unix_time`.

## Cadencia

El generador publica respetando el orden cronológico de
`fecha_hora_transaccion` del CSV (`fraudTest.csv`, no `fraudTrain.csv` — ver
`Documentation/CONTEXTO_SPRINT2_NEOBANX.md`, sección de diseño). La cadencia
es configurable vía `TX_POR_SEGUNDO` (reemplaza el `INTERVALO_SEGUNDOS` fijo
de 4s de v1).

## Checklist antes de dar por listo el flujo

- [ ] El generador ordena `fraudTest.csv` por `fecha_hora_transaccion` antes de empezar a enviar.
- [ ] Cada evento de transacción valida contra `contracts.TransaccionEvento` antes de enviarse.
- [ ] `cc_num_hash` se genera con `Backend/common/hmac_util.hash_cc_num`, nunca con una implementación local nueva.
- [ ] `cc_num` en texto plano nunca sale del generador (ni al log, ni al payload).
- [ ] Cada evento de veredicto valida contra `contracts.VeredictoEvento` antes de publicarse.
- [ ] Probado localmente (Postgres + emulador de Pub/Sub) antes de desplegar a la nube.
