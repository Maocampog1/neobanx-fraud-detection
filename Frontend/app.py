import json
import random
import time
from datetime import datetime, timezone

import streamlit as st
from google.cloud import bigquery, pubsub_v1

PROJECT_ID = "neobanx-fraud-detection"
TOPIC_ID = "transacciones-neobanx"

st.set_page_config(page_title="NeobanX - Demo Fraude", layout="wide")
st.title("🏦 NeobanX — Demo de Detección de Fraude en Streaming")

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
bq_client = bigquery.Client(project=PROJECT_ID)

COMERCIOS = ["fraud_Rippin, Kub and Mann", "fraud_Test Store", "fraud_QuickShop"]
CATEGORIAS = ["shopping_net", "misc_net", "grocery_pos", "gas_transport", "health_fitness"]


def transaccion_de_ejemplo():
    return {
        "trans_num": f"demo_{int(time.time()*1000)}_{random.randint(1,999)}",
        "cc_num_hash": f"hash{random.randint(1000,9999)}",
        "merchant": random.choice(COMERCIOS),
        "category": random.choice(CATEGORIAS),
        "amt": round(random.uniform(5, 500), 2),
        "trans_date_trans_time": datetime.now(timezone.utc).isoformat(),
        "merch_lat": round(random.uniform(30, 40), 6),
        "merch_long": round(random.uniform(-90, -75), 6),
        "is_fraud": 0,
    }


col1, col2 = st.columns([1, 3])

with col1:
    st.subheader("Simulador")
    if st.button("🚀 Simular transacción", use_container_width=True):
        payload = transaccion_de_ejemplo()
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        future = publisher.publish(topic_path, data)
        future.result()
        st.success(f"Publicada: {payload['trans_num']}")
        st.json(payload)

    auto_refresh = st.checkbox("Auto-refrescar cada 5s", value=False)

with col2:
    st.subheader("Últimas transacciones procesadas")
    query = f"""
        SELECT trans_num, merchant, category, amt, veredicto, ingestion_timestamp
        FROM `{PROJECT_ID}.raw.transacciones_raw`
        ORDER BY ingestion_timestamp DESC
        LIMIT 20
    """
    df = bq_client.query(query).to_dataframe()

    if not df.empty:
        def resaltar(row):
            color = "background-color: #ffcccc" if row["veredicto"] == "alerta" else ""
            return [color] * len(row)

        st.dataframe(df.style.apply(resaltar, axis=1), use_container_width=True)

        c1, c2 = st.columns(2)
        c1.metric("Aprobadas", int((df["veredicto"] == "aprobada").sum()))
        c2.metric("Alertas", int((df["veredicto"] == "alerta").sum()))
    else:
        st.info("Aún no hay transacciones. Usa el botón para simular una.")

if auto_refresh:
    time.sleep(5)
    st.rerun()