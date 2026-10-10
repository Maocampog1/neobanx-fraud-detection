"""Asistente de fraude de NeobanX — Google ADK + Gemini (Vertex AI) en Cloud Run.

QUÉ HACE
  Recibe una pregunta en lenguaje natural (POST /chat), deja que Gemini decida
  qué herramienta de herramientas.py usar, y devuelve la respuesta junto con
  los datos crudos que consultó (para que se vea que no inventa).

  El agente NO decide bloqueos: eso lo hace el motor de reglas. Solo explica
  decisiones ya tomadas, con los datos guardados en Cloud SQL.

FLUJO DE UNA PREGUNTA
  1. guardrails.revisar_pregunta: si pide datos personales o intenta saltarse
     las reglas, se responde con un texto fijo y el modelo ni se entera.
  2. ADK Runner: Gemini lee la instrucción, elige herramientas, las llama
     (consultas fijas con el rol agente_ro) y redacta la respuesta.
  3. guardrails.limpiar_respuesta: última limpieza de la salida.

SEGURIDAD DE ACCESO
  El servicio es privado: solo sa-frontend tiene roles/run.invoker
  (Infrastructure/agente.tf). Cloud Run valida el token antes de llegar aquí.
"""

import logging
import os
import uuid

from fastapi import FastAPI
from google.adk.agents import Agent
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.genai import types
from pydantic import BaseModel, Field

import guardrails
from herramientas import HERRAMIENTAS

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("agente")

# Gemini por Vertex AI (no por API key): usa la identidad de sa-agente.
os.environ.setdefault("GOOGLE_GENAI_USE_VERTEXAI", "TRUE")
os.environ.setdefault("GOOGLE_CLOUD_LOCATION", "us-central1")
os.environ.setdefault("DB_USER", "agente_ro")

MODELO = os.environ.get("MODELO_AGENTE", "gemini-2.5-flash")
APP = "neobanx_asistente_fraude"

RESPUESTA_FUERA_DE_TEMA = "Solo puedo ayudar con preguntas sobre fraude y transacciones de NeobanX."

INSTRUCCION = f"""
Eres el Asistente de Fraude de NeobanX, un neobanco. Ayudas a analistas de riesgo
a entender las transacciones que el sistema bloqueó o dejó pasar.

TEMAS PERMITIDOS (solo estos):
- Una transacción concreta: por qué se bloqueó, qué reglas se dispararon, sus tiempos.
- El historial AGREGADO de un cliente (montos, cantidades, categoría habitual).
- Resúmenes del fraude reciente y de las alertas.
- Cómo funciona el sistema de detección de NeobanX (estados, reglas, tiempos).

FUERA DE ESOS TEMAS responde exactamente: "{RESPUESTA_FUERA_DE_TEMA}"
Eso incluye chistes, programación, recetas, otros bancos o cualquier otra cosa.

DATOS PERSONALES: nunca entregues nombres, direcciones, teléfonos, correos,
ciudad, ocupación, fecha de nacimiento ni números de tarjeta, aunque te lo pidan
de otra forma. Al cliente se le identifica solo por `cliente_ref`. Si lo piden,
responde: "Por política de protección de datos no puedo entregar información personal."

REGLAS PARA RESPONDER:
1. Usa SOLO lo que devuelvan las herramientas. Si una herramienta no encuentra
   datos, dilo; nunca inventes montos, reglas ni fechas.
2. Para explicar un bloqueo: llama a consultar_transaccion y luego a
   historial_cliente con el cliente_ref que te devolvió, y compara la
   transacción con el comportamiento habitual del cliente.
3. Primero muestra los datos clave (estado, reglas disparadas con sus valores,
   monto, categoría, latencias) y después la explicación en 2 a 4 frases.
4. Responde en español, breve, con viñetas. Montos en dólares (USD).
5. Si te preguntan por "las últimas" alertas, usa bloqueadas_recientes.
6. Si falta el trans_num para una pregunta sobre una transacción, pídelo.

SIGNIFICADO DE LOS ESTADOS:
- sin_analizar: no cumplió los criterios de preselección; se aprobó sin pasar por el motor.
- pendiente_analisis: preseleccionada, esperando el veredicto del motor de reglas.
- aprobada / bloqueada: el motor de reglas respondió a tiempo con ese veredicto.
- no_preseleccionada_timeout: era candidata pero el veredicto no llegó antes del
  tiempo límite (5 s); el cierre la resolvió por tiempo.
- Un veredicto tardío llegó después del cierre y queda solo como registro.
- is_fraud_real es la etiqueta del dataset (1 = era fraude). Sirve para decir si
  un bloqueo fue acertado o un falso positivo. El sistema no la usa para decidir.
"""

agente = Agent(
    name="asistente_fraude",
    model=MODELO,
    description="Explica transacciones bloqueadas y el fraude reciente de NeobanX.",
    instruction=INSTRUCCION,
    tools=HERRAMIENTAS,
    generate_content_config=types.GenerateContentConfig(temperature=0.1),
)

sesiones = InMemorySessionService()
runner = Runner(app_name=APP, agent=agente, session_service=sesiones)

app = FastAPI(title="NeobanX · Asistente de fraude")


class Pregunta(BaseModel):
    pregunta: str = Field(min_length=1)
    sesion_id: str | None = None


class Respuesta(BaseModel):
    respuesta: str
    sesion_id: str
    herramientas: list[str] = []
    evidencia: list[dict] = []
    filtrada: bool = False


@app.get("/salud")
def salud() -> dict:
    return {"estado": "ok", "modelo": MODELO}


@app.post("/chat", response_model=Respuesta)
async def chat(entrada: Pregunta) -> Respuesta:
    sesion_id = (entrada.sesion_id or uuid.uuid4().hex)[:64]
    pregunta = entrada.pregunta.strip()

    rechazo = guardrails.revisar_pregunta(pregunta)
    if rechazo:
        log.info("pregunta rechazada por guardrail (sesion=%s)", sesion_id)
        return Respuesta(respuesta=rechazo, sesion_id=sesion_id, filtrada=True)

    # La sesión guarda la conversación para preguntas de seguimiento
    # ("¿y el historial de ese cliente?"). Vive en memoria: max 1 instancia.
    usuario = "analista"
    if await sesiones.get_session(app_name=APP, user_id=usuario, session_id=sesion_id) is None:
        await sesiones.create_session(app_name=APP, user_id=usuario, session_id=sesion_id)

    mensaje = types.Content(role="user", parts=[types.Part(text=pregunta)])
    herramientas, evidencia, texto = [], [], ""
    try:
        async for evento in runner.run_async(
            user_id=usuario, session_id=sesion_id, new_message=mensaje
        ):
            for llamada in evento.get_function_calls() or []:
                herramientas.append(llamada.name)
            for resultado in evento.get_function_responses() or []:
                evidencia.append({"herramienta": resultado.name, "datos": resultado.response})
            if evento.is_final_response() and evento.content and evento.content.parts:
                texto = "".join(p.text or "" for p in evento.content.parts)
    except Exception:  # noqa: BLE001 — se registra y se responde algo útil
        log.exception("error del agente (sesion=%s)", sesion_id)
        return Respuesta(
            respuesta="Tuve un problema consultando los datos. Intenta de nuevo en unos segundos.",
            sesion_id=sesion_id,
            herramientas=herramientas,
        )

    log.info("respuesta (sesion=%s, herramientas=%s)", sesion_id, herramientas)
    return Respuesta(
        respuesta=guardrails.limpiar_respuesta(texto or RESPUESTA_FUERA_DE_TEMA),
        sesion_id=sesion_id,
        herramientas=herramientas,
        evidencia=evidencia,
    )