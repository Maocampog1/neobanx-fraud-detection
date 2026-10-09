"""Prueba MINIMA, descartable: confirma que un TaskManager real arranca su
worker Python usando el venv empaquetado (venv.zip) via -pyarch/-pyexec, en
vez del Python de sistema del contenedor -- el mismo mecanismo que se usara
contra Dataproc. No se despliega, es solo para esta validacion puntual.

Se corre con `flink run` (CLI real, cluster local, no MiniCluster en
proceso) para ejercer el mismo camino de arranque de workers que falla en
YARN -- un test en proceso (MiniCluster normal) no lo haria, porque ahi los
workers ya corren con el Python del proceso actual, no con el que indique
-pyexec.
"""
from pyflink.datastream import StreamExecutionEnvironment

env = StreamExecutionEnvironment.get_execution_environment()
resultado = env.from_collection(["ok-1", "ok-2", "ok-3"]).map(lambda x: f"{x}-procesado")
resultado.print()
env.execute("prueba-venv-empaquetado")
