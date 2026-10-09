# Build context: la RAIZ del repo -- este servicio solo necesita contracts/
# (no toca Backend/common/, no tiene conexion a base de datos).
FROM python:3.12-slim

WORKDIR /app

COPY Backend/stub_veredicto/requirements.txt Backend/stub_veredicto/requirements.txt
RUN pip install --no-cache-dir -r Backend/stub_veredicto/requirements.txt

COPY contracts/ contracts/
COPY Backend/stub_veredicto/main.py Backend/stub_veredicto/main.py

WORKDIR /app/Backend/stub_veredicto

CMD ["sh", "-c", "python -m uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
