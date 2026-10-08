"""Conexion a Cloud SQL, compartida entre el servicio de registro y el de
cierre -- los dos necesitan la misma logica de conexion, solo cambia el rol.

Dos modos, elegidos por variables de entorno:

  - Local (desarrollo): `DATABASE_URL` -- cadena de conexion normal de
    psycopg2 contra un Postgres cualquiera (ej. el contenedor Docker local).
  - Nube: `INSTANCE_CONNECTION_NAME` -- usa el Cloud SQL Python Connector
    (no el Auth Proxy, los servicios no lo necesitan) con el driver pg8000,
    y la contrasena del rol se lee de Secret Manager (`DB_PASSWORD_SECRET`).

Ambos devuelven una conexion DB-API 2.0 normal (`cursor()`, `execute(sql,
params)`, `commit()`) -- el codigo que las usa no necesita saber cual es.
"""

import os


def conectar():
    instance_connection_name = os.environ.get("INSTANCE_CONNECTION_NAME")
    db_name = os.environ.get("DB_NAME", "neobanx")
    db_user = os.environ["DB_USER"]

    if instance_connection_name:
        return _conectar_nube(instance_connection_name, db_user, db_name)
    return _conectar_local(db_user, db_name)


def _conectar_local(db_user: str, db_name: str):
    import psycopg2

    database_url = os.environ.get("DATABASE_URL")
    if database_url:
        return psycopg2.connect(database_url)

    # Variante sin DATABASE_URL completa: arma la cadena a partir de piezas
    # sueltas, utíl para los contenedores locales de prueba.
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "127.0.0.1"),
        port=int(os.environ.get("DB_PORT", "5555")),
        user=db_user,
        password=os.environ["DB_PASSWORD_LOCAL"],
        dbname=db_name,
    )


def _conectar_nube(instance_connection_name: str, db_user: str, db_name: str):
    from google.cloud import secretmanager
    from google.cloud.sql.connector import Connector

    secreto_id = os.environ["DB_PASSWORD_SECRET"]
    proyecto = os.environ["GOOGLE_CLOUD_PROJECT"]
    cliente = secretmanager.SecretManagerServiceClient()
    nombre = f"projects/{proyecto}/secrets/{secreto_id}/versions/latest"
    password = cliente.access_secret_version(name=nombre).payload.data.decode("utf-8")

    connector = Connector()
    return connector.connect(
        instance_connection_name,
        "pg8000",
        user=db_user,
        password=password,
        db=db_name,
    )
