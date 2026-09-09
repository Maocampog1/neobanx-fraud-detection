# Frontend — Demo NeobanX

App en Streamlit desplegada en Cloud Run (`Infrastructure/main.tf`,
`google_cloud_run_v2_service.frontend`). Es una herramienta interna de
validación del pipeline, no un producto para clientes del neobanco: sirve
para simular una transacción con un clic y ver en vivo qué veredicto le
asigna el consumidor.

## Qué hace

- Botón **"Simular transacción"**: genera una transacción de prueba
  (montos y categorías al azar) y la publica directamente al tópico
  Pub/Sub `transacciones-neobanx` — es un segundo publicador, independiente
  del generador de `Backend/generador/` (ese usa datos reales del CSV
  Sparkov; este usa datos sintéticos solo para demo rápida).
- Tabla con las últimas 20 transacciones en `raw.transacciones_raw`,
  resaltando en rojo las que el consumidor marcó como `alerta`.
- Contadores de aprobadas vs. alertas.
- Casilla de auto-refresco cada 5 segundos.

## Usar la versión ya desplegada

La URL pública queda expuesta como output de Terraform después de
`terraform apply` (ver `Infrastructure/README.md`):

```bash
cd Infrastructure
terraform output frontend_url
```

O en la consola web: Cloud Run → `neobanx-demo` → URL en la parte superior.
El servicio es público (`allUsers`) — no requiere login.

## Correrla en local (para desarrollo)

1. Autenticarse: `gcloud auth application-default login`
2. Instalar dependencias:
   ```powershell
   cd Frontend
   pip install -r requirements.txt
   ```
3. Ejecutar:
   ```powershell
   streamlit run app.py
   ```
   Abre automáticamente `http://localhost:8501`.

## Variables de entorno

Ninguna requerida — `PROJECT_ID` y `TOPIC_ID` están fijos en `app.py`
(`neobanx-fraud-detection` / `transacciones-neobanx`), igual que en
`Backend/generador/main.py`.
