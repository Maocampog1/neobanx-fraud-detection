# Build context: la RAIZ del repo -- ver Backend/registro/Dockerfile para la
# explicacion completa, el patron es identico.
FROM python:3.12-slim

WORKDIR /app

COPY Backend/cierre/requirements.txt Backend/cierre/requirements.txt
RUN pip install --no-cache-dir -r Backend/cierre/requirements.txt

COPY contracts/ contracts/
COPY Backend/common/ Backend/common/
COPY Backend/cierre/main.py Backend/cierre/main.py

WORKDIR /app/Backend/cierre

CMD ["sh", "-c", "python -m uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]
