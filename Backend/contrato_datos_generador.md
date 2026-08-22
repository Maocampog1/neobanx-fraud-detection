# Contrato de datos — Generador → Pub/Sub (para Juanes)

## Resumen
El consumidor (ya desplegado por Larry) espera que cada mensaje publicado en el
tópico `transacciones-neobanx` sea un JSON con **exactamente estos campos**,
en **inglés**, con los mismos nombres del CSV original (`fraudTrain.csv`).
No se traducen al español en este punto del pipeline — la traducción de
nombres solo aplica dentro de Cloud SQL (tablas `clientes`, `transacciones`,
`alertas`), que son responsabilidad de Larry.

## Formato exacto del mensaje (JSON)

```json
{
  "trans_num": "0b242abb623afc578575680df30655b9",
  "cc_num_hash": "80923ef013",
  "merchant": "fraud_Rippin, Kub and Mann",
  "category": "misc_net",
  "amt": 4.97,
  "trans_date_trans_time": "2019-01-01T00:00:18",
  "merch_lat": 36.011293,
  "merch_long": -82.048315,
  "is_fraud": 0
}
```

## Notas importantes (del perfilamiento de Camilo)

- **`trans_num`**: obligatorio siempre — es la llave de deduplicación e
  idempotencia aguas abajo. No lo omitas nunca.
- **`cc_num_hash`**: el generador debe aplicar hash (con salt) sobre `cc_num`
  antes de publicar — el número de tarjeta real **nunca** debe salir a
  Pub/Sub en texto plano (PII de alta sensibilidad).
- **`trans_date_trans_time`**: usar el timestamp real del CSV
  (`trans_date_trans_time`), en formato ISO 8601. **No usar `unix_time`** —
  tiene un desfase de ~7 años frente al valor real (hallazgo del
  perfilamiento de Camilo).
- **`amt`**: número (float), sin formatear como texto ni con símbolo de moneda.
- **`is_fraud`**: se conserva del dataset base solo para fines de validación
  del pipeline durante el sprint — en un escenario real de producción no
  llegaría en el evento de streaming.
- Campos de perfil del cliente (`first`, `last`, `gender`, `street`, `city`,
  `state`, `zip`, `lat`, `long`, `city_pop`, `job`, `dob`) **NO van en este
  mensaje** — esos ya están precargados en la tabla `clientes` de Cloud SQL
  (Larry los inserta por separado, no vienen del streaming).

## Cadencia
Publicar un mensaje cada 4 segundos, respetando el orden cronológico de
`trans_date_trans_time` del CSV (no orden aleatorio).

## Checklist antes de dar por listo el generador
- [ ] Ordena el CSV por `trans_date_trans_time` antes de empezar a publicar.
- [ ] Cada mensaje tiene los 9 campos de arriba, sin campos extra ni faltantes.
- [ ] `cc_num` nunca se publica en texto plano (solo el hash).
- [ ] Se usa `trans_date_trans_time`, nunca `unix_time`, para cualquier lógica
      de tiempo.
- [ ] Probado contra el tópico real `transacciones-neobanx` del proyecto
      (no solo local).