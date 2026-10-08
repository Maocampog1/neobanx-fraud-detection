"""Carga batch del perfil histórico del cliente a Redis (job de PySpark).

QUÉ CONSTRUYE
-------------
Para cada tarjeta, un resumen de su comportamiento histórico que el job de
Flink consulta al enriquecer cada transacción del stream:

    perfil:{cc_num_hash}  ->  hash de Redis
        monto_promedio          media histórica
        monto_desviacion        desviación estándar
        monto_maximo
        categorias_frecuentes   top 3, separadas por coma
        lat_habitual            centroide de las ubicaciones del comercio
        long_habitual
        num_transacciones       tamaño de la muestra

Se consulta con un solo HGETALL, que es una ida y vuelta.

POR QUÉ ESTO ES BATCH Y CORRE EN DATAPROC
-----------------------------------------
Dos razones, y la segunda es una restricción dura:

1. Agrega 1,3 millones de filas de `fraudTrain` en ~1000 perfiles. Es un
   cálculo de una sola pasada, no algo que tenga sentido hacer por evento.

2. Memorystore tiene IP PRIVADA (Private Service Access): solo es alcanzable
   desde dentro de la VPC. La máquina que corre el despliegue está fuera, así
   que esta carga no puede ejecutarse desde ahí. Los nodos de Dataproc sí están
   en la subred.

POR QUÉ REDIS ES DE SOLO LECTURA PARA FLINK
-------------------------------------------
Este job es el ÚNICO que escribe en Redis. El job de Flink solo lee.
Deliberadamente.

Si Flink actualizara el perfil con cada transacción que evalúa, contaminaría la
línea base con los datos que está juzgando. Un atacante podría subir montos de
a poco: cada operación elevaría su propio promedio, y la siguiente se vería
"normal". La regla de "monto muy superior al promedio" se volvería inútil
contra alguien paciente. Es el envenenamiento de la línea base, un anti-patrón
conocido en detección de fraude.

El comportamiento RECIENTE (ráfagas, ubicación imposible entre operaciones
consecutivas) sí lo mantiene Flink, pero en su propio estado por clave, no en
Redis. Son dos estados con propósitos distintos:

    Redis         -> línea base histórica, estable, inmutable durante el stream
    Estado Flink  -> ventana reciente, mutable, por clave

Una cuenta que no exista en `fraudTrain` no tendrá perfil en Redis. Eso es
esperado y Flink debe tolerarlo: pierde las reglas comparativas, pero las
absolutas (monto alto, festivo) y las de velocidad (ráfaga, ubicación) siguen
funcionando desde su primera transacción.

SEPARACIÓN TRAIN / TEST
-----------------------
El perfil se construye con `fraudTrain` y el generador emite desde
`fraudTest`. Así el perfil nunca "ya conoce" la transacción que se está
evaluando, que sería hacer trampa.

USO
---
    gcloud dataproc jobs submit pyspark perfiles_redis.py \
      --cluster=neobanx-flink --region=us-central1 \
      -- --csv gs://.../fraudTrain.csv \
         --redis-host 10.x.x.x --redis-port 6378 \
         --proyecto neobanx-fraud-detection \
         --secreto-hmac neobanx-hmac-cc-num \
         --secreto-redis neobanx-redis-auth
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import sys
from collections import Counter

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

# Columnas del CSV que se necesitan. Leer solo estas evita traer las 23.
COLUMNAS = ["cc_num", "amt", "category", "merch_lat", "merch_long"]

TOP_CATEGORIAS = 3


def leer_secreto(proyecto: str, secreto: str) -> str:
    """Lee un secreto de Secret Manager con las credenciales de la cuenta de
    servicio del clúster (sa-flink).

    Los secretos NO se pasan como argumentos del job a propósito: los
    argumentos quedan visibles en la consola de Dataproc y en el historial de
    jobs, que es un lugar donde no deben aparecer credenciales.
    """
    from google.cloud import secretmanager

    cliente = secretmanager.SecretManagerServiceClient()
    nombre = f"projects/{proyecto}/secrets/{secreto}/versions/latest"
    respuesta = cliente.access_secret_version(request={"name": nombre})
    return respuesta.payload.data.decode("utf-8")


def normalizar_cc_num(valor) -> str:
    """Misma normalización que Backend/common/hmac_util.py.

    Se replica aquí porque el job corre en los nodos de Dataproc, donde no está
    montado el repo. Si cambia la lógica en hmac_util.py hay que reflejarlo
    aquí: si las dos normalizaciones divergen, los hashes dejan de coincidir y
    Flink no encontraría el perfil de ninguna cuenta.
    """
    texto = str(valor).strip()
    if not texto:
        raise ValueError("cc_num vacío")
    if texto.isdigit():
        return texto
    from decimal import Decimal, InvalidOperation

    try:
        numero = Decimal(texto)
    except InvalidOperation:
        sin_sep = texto.replace(" ", "").replace("-", "")
        if sin_sep.isdigit():
            return sin_sep
        raise ValueError(f"cc_num no válido: {valor!r}")
    if not numero.is_finite() or numero < 0:
        raise ValueError(f"cc_num no válido: {valor!r}")
    entero = numero.to_integral_value()
    if numero != entero:
        raise ValueError(f"cc_num con decimales: {valor!r}")
    canonico = format(entero, "f").rstrip(".")
    if not canonico.isdigit():
        raise ValueError(f"cc_num no normalizable: {valor!r}")
    return canonico


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True, help="Ruta gs:// de fraudTrain.csv")
    parser.add_argument("--redis-host", required=True)
    parser.add_argument("--redis-port", type=int, default=6378)
    parser.add_argument("--proyecto", required=True)
    parser.add_argument("--secreto-hmac", required=True)
    parser.add_argument("--secreto-redis", required=True)
    args = parser.parse_args()

    spark = (
        SparkSession.builder.appName("neobanx-perfiles-redis")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("WARN")

    print(f"[perfiles] leyendo {args.csv}")
    df = (
        spark.read.option("header", "true").csv(args.csv)
        .select(*COLUMNAS)
        .withColumn("amt", F.col("amt").cast("double"))
        .withColumn("merch_lat", F.col("merch_lat").cast("double"))
        .withColumn("merch_long", F.col("merch_long").cast("double"))
        .filter(F.col("cc_num").isNotNull() & F.col("amt").isNotNull())
    )

    # --- Agregados numéricos por tarjeta ---
    # Se agrupa por el cc_num EN CLARO y se hashea después, en el driver: hay
    # ~1000 tarjetas distintas frente a 1,3 M de filas, así que hashear al
    # final evita aplicar una UDF criptográfica a cada fila.
    agregados = (
        df.groupBy("cc_num")
        .agg(
            F.avg("amt").alias("monto_promedio"),
            F.stddev_pop("amt").alias("monto_desviacion"),
            F.max("amt").alias("monto_maximo"),
            F.count("*").alias("num_transacciones"),
            F.avg("merch_lat").alias("lat_habitual"),
            F.avg("merch_long").alias("long_habitual"),
        )
    )

    # --- Categorías más frecuentes por tarjeta ---
    conteo_categorias = (
        df.groupBy("cc_num", "category")
        .count()
        .groupBy("cc_num")
        .agg(F.collect_list(F.struct("count", "category")).alias("categorias"))
    )

    perfiles = agregados.join(conteo_categorias, on="cc_num", how="left")

    filas = perfiles.collect()
    print(f"[perfiles] {len(filas)} tarjetas agregadas")

    if not filas:
        print("[perfiles] ERROR: no se agregó ninguna tarjeta", file=sys.stderr)
        return 1

    # --- Secretos y conexión ---
    print("[perfiles] leyendo secretos")
    clave_hmac = leer_secreto(args.proyecto, args.secreto_hmac).encode("utf-8")
    auth_redis = leer_secreto(args.proyecto, args.secreto_redis)

    import redis

    # ssl=True porque la instancia tiene transit_encryption_mode activo.
    cliente = redis.Redis(
        host=args.redis_host,
        port=args.redis_port,
        password=auth_redis,
        ssl=True,
        ssl_cert_reqs=None,
        socket_timeout=15,
        decode_responses=True,
    )
    cliente.ping()
    print("[perfiles] conectado a Redis")

    # --- Escritura ---
    escritos = 0
    descartados = 0
    tuberia = cliente.pipeline(transaction=False)

    for fila in filas:
        try:
            normalizado = normalizar_cc_num(fila["cc_num"])
        except ValueError:
            descartados += 1
            continue

        cc_hash = hmac.new(clave_hmac, normalizado.encode("utf-8"), hashlib.sha256).hexdigest()

        categorias = []
        if fila["categorias"]:
            contador = Counter()
            for elemento in fila["categorias"]:
                contador[elemento["category"]] = elemento["count"]
            categorias = [c for c, _ in contador.most_common(TOP_CATEGORIAS)]

        # La desviación es None cuando la tarjeta tiene una sola transacción.
        desviacion = fila["monto_desviacion"] if fila["monto_desviacion"] is not None else 0.0

        tuberia.hset(
            f"perfil:{cc_hash}",
            mapping={
                "monto_promedio": f"{fila['monto_promedio']:.2f}",
                "monto_desviacion": f"{desviacion:.2f}",
                "monto_maximo": f"{fila['monto_maximo']:.2f}",
                "categorias_frecuentes": ",".join(categorias),
                "lat_habitual": f"{fila['lat_habitual']:.6f}" if fila["lat_habitual"] is not None else "",
                "long_habitual": f"{fila['long_habitual']:.6f}" if fila["long_habitual"] is not None else "",
                "num_transacciones": str(fila["num_transacciones"]),
            },
        )
        escritos += 1

        # Se envía por lotes para no acumular 1000 comandos en memoria.
        if escritos % 200 == 0:
            tuberia.execute()
            tuberia = cliente.pipeline(transaction=False)

    tuberia.execute()

    total_claves = len(cliente.keys("perfil:*"))
    print(f"[perfiles] escritos {escritos}, descartados {descartados}")
    print(f"[perfiles] claves perfil:* en Redis: {total_claves}")

    # Muestra de verificación, para que quede en el log del job.
    muestra = cliente.keys("perfil:*")[:1]
    if muestra:
        print(f"[perfiles] ejemplo {muestra[0]} -> {cliente.hgetall(muestra[0])}")

    cliente.close()
    spark.stop()

    if escritos == 0:
        print("[perfiles] ERROR: no se escribió ningún perfil", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
