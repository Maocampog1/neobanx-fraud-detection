# Build context: la RAIZ del repo, igual que Backend/registro/Dockerfile.
# El frontend importa codigo compartido de contracts/ y Backend/common/
# (contrato del evento, HMAC de la tarjeta y conexion a Cloud SQL), asi que la
# estructura dentro de la imagen replica la del repo:
#
#   docker build -f Frontend/Dockerfile .      (equivalente local)
FROM python:3.12-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY Frontend/requirements.txt Frontend/requirements.txt
RUN pip install --no-cache-dir -r Frontend/requirements.txt

COPY contracts/ contracts/
COPY Backend/common/ Backend/common/
COPY Frontend/app.py Frontend/app.py

WORKDIR /app/Frontend

# Cloud Run inyecta PORT. headless: sin abrir navegador; sin estadisticas de uso.
CMD ["sh", "-c", "streamlit run app.py --server.port ${PORT:-8080} --server.address 0.0.0.0 --server.headless true --browser.gatherUsageStats false"]