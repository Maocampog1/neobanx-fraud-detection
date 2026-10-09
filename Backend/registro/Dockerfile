# Build context: la RAIZ del repo (no esta carpeta) -- este servicio importa
# codigo compartido de Backend/common/ y contracts/, que viven fuera de
# Backend/registro/. Por eso el build real es:
#
#   gcloud builds submit --config=... (ver Infrastructure/run.tf)
#   docker build -f Backend/registro/Dockerfile .    (equivalente local)
#
# La estructura de carpetas DENTRO de la imagen replica exactamente la del
# repo (contracts/, Backend/common/, Backend/registro/) a proposito: asi el
# sys.path.insert relativo que hace main.py (parents[2] para la raiz,
# ../common para lo compartido) funciona sin ningun caso especial para la nube.
FROM python:3.12-slim

WORKDIR /app

COPY Backend/registro/requirements.txt Backend/registro/requirements.txt
RUN pip install --no-cache-dir -r Backend/registro/requirements.txt

COPY contracts/ contracts/
COPY Backend/common/ Backend/common/
COPY Backend/registro/main.py Backend/registro/main.py

WORKDIR /app/Backend/registro

# Cloud Run inyecta PORT; `python -m uvicorn` (no el binario `uvicorn` a
# secas) agrega el directorio actual a sys.path, igual que en las pruebas
# locales de esta misma sesion.
CMD ["sh", "-c", "python -m uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
