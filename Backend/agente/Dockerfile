# Asistente de fraude (ADK + Gemini). Se construye desde la RAÍZ del repo
# (construir_imagen.sh usa la raíz como contexto) para poder copiar
# Backend/common/, igual que los demás servicios.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY Backend/agente/requirements.txt Backend/agente/requirements.txt
RUN pip install --no-cache-dir -r Backend/agente/requirements.txt

COPY Backend/common/ Backend/common/
COPY Backend/agente/ Backend/agente/

WORKDIR /app/Backend/agente

CMD exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}