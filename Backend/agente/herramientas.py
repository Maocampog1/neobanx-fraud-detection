"""Herramientas del asistente de fraude: las ÚNICAS formas que tiene el modelo
de ver datos.

REGLAS DE DISEÑO
  - Consultas fijas y parametrizadas (%s). El modelo elige qué herramienta usar
    y con qué valor, pero nunca escribe SQL.
  - Rol `agente_ro`: solo SELECT sobre las vistas linaje_transaccion, alertas y
    v_historial_cliente (Infrastructure/schema.sql). Si una consulta intentara
    leer otra tabla, Postgres la rechazaría.
  - Minimización de datos (DAMA / Habeas Data): v_historial_cliente trae
    `ciudad` y `ocupacion`, pero aquí NO se piden. El hash de la tarjeta sale
    recortado a 12 caracteres (`cliente_ref`), suficiente para encadenar
    herramientas y nada más. El `cc_num` real ni siquiera existe en la base.
  - Todo se convierte a tipos JSON simples (Decimal -> float, fechas -> texto),
    porque el resultado viaja al modelo.

El docstring y los tipos de cada función son lo que el modelo lee para decidir
cuándo usarla, por eso están escritos para él.
"""

import json
import re
import sys
from collections import Counter
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

_RAIZ = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_RAIZ / "Backend" / "common"))

from db_conexion import conectar  # noqa: E402

LARGO_REF = 12
_PATRON_TRANS_NUM = re.compile(r"^[A-Za-z0-9_-]{6,64}$")
_PATRON_REF = re.compile(r"^[0-9a-f]{8,64}$")


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
def _a_json(valor):
    if isinstance(valor, Decimal):
        return float(valor)
    if isinstance(valor, (datetime, date)):
        return valor.isoformat()
    if isinstance(valor, dict):
        return {k: _a_json(v) for k, v in valor.items()}
    if isinstance(valor, (list, tuple)):
        return [_a_json(v) for v in valor]
    return valor


def _consultar(sql: str, params: tuple) -> list[dict]:
    conexion = conectar()
    try:
        cursor = conexion.cursor()
        cursor.execute(sql, params)
        columnas = [c[0] for c in cursor.description]
        return [_a_json(dict(zip(columnas, fila))) for fila in cursor.fetchall()]
    finally:
        conexion.close()


def _reglas(valor) -> list:
    """reglas_disparadas puede llegar como lista, JSON en texto o None."""
    if valor is None:
        return []
    if isinstance(valor, str):
        try:
            valor = json.loads(valor)
        except ValueError:
            return [valor]
    return valor if isinstance(valor, list) else [valor]


def _nombre_regla(regla) -> str:
    if isinstance(regla, dict):
        return str(regla.get("regla") or regla.get("nombre") or regla.get("id") or regla)
    return str(regla)


def _recortar_ref(fila: dict) -> dict:
    hash_completo = fila.pop("cc_num_hash", None)
    if hash_completo:
        fila["cliente_ref"] = hash_completo[:LARGO_REF]
    return fila


# ---------------------------------------------------------------------------
# Herramientas
# ---------------------------------------------------------------------------
def consultar_transaccion(trans_num: str) -> dict:
    """Trae el análisis completo de UNA transacción por su trans_num: estado
    final, motivo de preselección, veredicto del motor de reglas, reglas que se
    dispararon (con sus valores), tiempos de cada paso (recepción, evaluación,
    cierre, latencias en segundos), veredictos tardíos, la trazabilidad de
    estados y la etiqueta real del dataset (is_fraud_real: 1 = era fraude).
    Si fue bloqueada, también trae comercio, categoría, monto y fecha.
    Devuelve `cliente_ref`, que sirve para llamar a historial_cliente.

    Args:
        trans_num: identificador de la transacción (32 caracteres hexadecimales).
    """
    trans_num = (trans_num or "").strip()
    if not _PATRON_TRANS_NUM.match(trans_num):
        return {"encontrada": False, "error": "trans_num con formato inválido"}

    filas = _consultar(
        """
        SELECT trans_num, cc_num_hash, estado_actual, motivo_preseleccion,
               momento_recepcion, momento_limite, momento_cierre,
               ROUND(latencia_cierre_seg::numeric, 3)      AS latencia_cierre_seg,
               veredicto, reglas_disparadas, version_reglas, momento_evaluacion,
               ROUND(latencia_transporte_seg::numeric, 3)  AS latencia_transporte_seg,
               is_fraud_real, trazabilidad_estados, veredictos_tardios
        FROM linaje_transaccion
        WHERE trans_num = %s
        """,
        (trans_num,),
    )
    if not filas:
        return {"encontrada": False, "trans_num": trans_num}

    resultado = _recortar_ref(filas[0])
    resultado["encontrada"] = True
    resultado["reglas_disparadas"] = _reglas(resultado.get("reglas_disparadas"))

    detalle = _consultar(
        """
        SELECT comercio, categoria, monto, fecha_hora_transaccion
        FROM alertas
        WHERE trans_num = %s
        """,
        (trans_num,),
    )
    if detalle:
        resultado["detalle_alerta"] = detalle[0]
    return resultado


def historial_cliente(cliente_ref: str) -> dict:
    """Trae el comportamiento AGREGADO de un cliente, para comparar una
    transacción con lo que ese cliente suele hacer: total de transacciones,
    cuántas bloqueadas y aprobadas, monto promedio, desviación y máximo,
    categoría más frecuente, primera y última transacción, edad aproximada y
    estado (región) de EE. UU. No trae datos personales.

    Args:
        cliente_ref: referencia del cliente (los primeros 12 caracteres del
            hash de la tarjeta), tal como la devuelve consultar_transaccion.
    """
    ref = (cliente_ref or "").strip().lower().rstrip("….")
    if not _PATRON_REF.match(ref):
        return {"encontrado": False, "error": "cliente_ref con formato inválido"}

    # Se piden columnas explícitas: ciudad y ocupacion se quedan en la base.
    filas = _consultar(
        """
        SELECT cc_num_hash, estado_geo, edad_aprox,
               total_transacciones, total_bloqueadas, total_aprobadas,
               monto_promedio, monto_desviacion, monto_maximo,
               categoria_frecuente, primera_transaccion, ultima_transaccion
        FROM v_historial_cliente
        WHERE cc_num_hash LIKE %s
        LIMIT 2
        """,
        (ref + "%",),
    )
    if not filas:
        return {"encontrado": False, "cliente_ref": ref}
    if len(filas) > 1:
        return {"encontrado": False, "error": "referencia ambigua, usa una más larga"}

    resultado = _recortar_ref(filas[0])
    resultado["encontrado"] = True
    return resultado


def resumen_fraude(horas: int) -> dict:
    """Resume la operación de las últimas N horas (según la hora en que el
    sistema RECIBIÓ cada transacción): cuántas hubo por estado final, cuántas
    eran fraude real según el dataset, cuántos fraudes se bloquearon y cuántos
    se escaparon, falsos positivos, veredictos tardíos, latencia p95 de cierre
    y las reglas que más bloquearon.

    Args:
        horas: ventana hacia atrás en horas (1 a 720). Usa 24 si no te dicen.
    """
    try:
        horas = int(horas)
    except (TypeError, ValueError):
        horas = 24
    horas = max(1, min(horas, 720))

    filas = _consultar(
        """
        SELECT estado_actual, is_fraud_real, veredictos_tardios,
               latencia_cierre_seg, reglas_disparadas
        FROM linaje_transaccion
        WHERE momento_recepcion >= NOW() - CAST(%s AS INTEGER) * INTERVAL '1 hour'
        """,
        (horas,),
    )
    if not filas:
        return {"ventana_horas": horas, "total": 0}

    por_estado = Counter(f["estado_actual"] for f in filas)
    fraude = [f for f in filas if f["is_fraud_real"] == 1]
    bloqueadas = [f for f in filas if f["estado_actual"] == "bloqueada"]
    latencias = sorted(f["latencia_cierre_seg"] for f in filas if f["latencia_cierre_seg"] is not None)
    p95 = latencias[min(len(latencias) - 1, int(0.95 * len(latencias)))] if latencias else None
    reglas = Counter(
        _nombre_regla(r) for f in bloqueadas for r in _reglas(f["reglas_disparadas"])
    )

    return {
        "ventana_horas": horas,
        "total": len(filas),
        "por_estado": dict(por_estado),
        "fraude_real_total": len(fraude),
        "fraude_bloqueado": sum(1 for f in fraude if f["estado_actual"] == "bloqueada"),
        "fraude_no_detectado": sum(1 for f in fraude if f["estado_actual"] != "bloqueada"),
        "falsos_positivos": sum(1 for f in bloqueadas if f["is_fraud_real"] != 1),
        "con_veredicto_tardio": sum(1 for f in filas if (f["veredictos_tardios"] or 0) > 0),
        "latencia_cierre_p95_seg": round(p95, 3) if p95 is not None else None,
        "reglas_mas_frecuentes": dict(reglas.most_common(5)),
    }


def bloqueadas_recientes(limite: int) -> dict:
    """Lista las últimas transacciones BLOQUEADAS (las alertas de fraude), de
    la más reciente a la más antigua, con trans_num, comercio, categoría,
    monto, fecha de la transacción, momento del bloqueo y reglas disparadas.

    Args:
        limite: cuántas traer (1 a 20). Usa 5 si no te dicen.
    """
    try:
        limite = int(limite)
    except (TypeError, ValueError):
        limite = 5
    limite = max(1, min(limite, 20))

    filas = _consultar(
        """
        SELECT trans_num, cc_num_hash, comercio, categoria, monto,
               fecha_hora_transaccion, bloqueada_at, reglas_disparadas
        FROM alertas
        ORDER BY bloqueada_at DESC
        LIMIT %s
        """,
        (limite,),
    )
    for fila in filas:
        _recortar_ref(fila)
        fila["reglas_disparadas"] = _reglas(fila.get("reglas_disparadas"))
    return {"cantidad": len(filas), "alertas": filas}


HERRAMIENTAS = [consultar_transaccion, historial_cliente, resumen_fraude, bloqueadas_recientes]