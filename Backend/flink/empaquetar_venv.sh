#!/usr/bin/env bash
# ============================================================================
# empaquetar_venv.sh — construye venv.zip para distribuir a los TaskManagers
# ============================================================================
#
# POR QUE ESTE SCRIPT EXISTE
# --------------------------
# El job de Flink en el cluster real falla en los TaskManagers con
# "ModuleNotFoundError: No module named 'pyflink'" porque Flink arranca cada
# worker Python con un chequeo propio que exige que `pyflink` sea un paquete
# `pip` real (con `pyflink.__file__` apuntando a una carpeta `bin/` de
# verdad), no solo el .zip bundleado que alcanza para el lado cliente. Y
# `pip install apache-flink==1.17.0` en el Python de sistema del cluster
# (3.11, Debian 12) esta bloqueado por `numpy<1.22` sin wheels para 3.11+.
#
# La solucion oficial de Flink (ver Backend/flink/README.md, seccion
# "Bloqueador actual", con las fuentes): empaquetar un venv COMPLETO con
# Python 3.10 + apache-flink==1.17.0 de verdad instalado, y que Flink mismo
# lo distribuya a cada nodo via `-pyarch`, apuntando tanto el lado cliente
# como el de TaskManager al interprete DENTRO del zip (`-pyclientexec`/
# `-pyexec`). Esto ya no depende del Python de sistema del cluster.
#
# POR QUE SE CONSTRUYE DENTRO DE neobanx-flink-dev (Dockerfile.dev)
# -------------------------------------------------------------------
# Tiene que ser la MISMA imagen base que ya validamos contra el MiniCluster
# local (Python 3.10-slim, Debian, mismas versiones fijadas de
# apache-flink/pydantic/requests/redis/cloudpickle) -- si se construyera en
# otro Python/OS, se arriesga el mismo tipo de desajuste de versión que ya
# costo dos sesiones de nube completas.
#
# `--copies` en `python -m venv` es obligatorio: sin el, el venv solo tiene
# symlinks al Python del sistema del contenedor de build, que no sobrevive
# a empaquetarlo y descomprimirlo en otra maquina.
#
# PERO `--copies` NO basta: el binario `python3` copiado sigue enlazado
# dinamicamente a `libpython3.10.so.1.0`, que vive FUERA del venv (en
# /usr/local/lib/ del contenedor de build). En el cluster real de Dataproc
# (Debian 12, Python de sistema 3.11) esa libreria simplemente no existe ->
# "error while loading shared libraries: libpython3.10.so.1.0: cannot open
# shared object file" al intentar correr el venv.zip subido -- confirmado
# en la primera corrida real contra el cluster, DESPUES de que la prueba
# local pasara (la prueba local no lo detecto porque se ejecuto dentro del
# MISMO contenedor donde se construyo el venv, que si tiene esa libreria
# instalada a nivel de sistema).
#
# Arreglo: empaquetar la libreria compartida DENTRO del zip
# (venv/lib_externa/) y usar `patchelf` para que el binario la busque por
# una ruta RELATIVA a si mismo ($ORIGIN) en vez de la ruta absoluta del
# contenedor de build -- asi el venv.zip ya no depende de nada fuera de si
# mismo, sea cual sea el Python de sistema del host donde se descomprima.
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEN="neobanx-flink-dev"

echo "==> Reconstruyendo ${IMAGEN} (por si Dockerfile.dev cambio)"
docker build -t "${IMAGEN}" -f "${AQUI}/Dockerfile.dev" "${AQUI}"

# MSYS_NO_PATHCONV=1: en Git Bash/Windows, sin esto, docker.exe recibe la ruta
# del -v ya mangled por la conversion automatica de rutas estilo POSIX -> Windows,
# y el volumen queda montado pero vacio del lado del contenedor (visto antes con
# el mismo sintoma: el script "termina bien" pero el archivo nunca aparece en el
# host). Confirmado con una prueba directa de escritura al volumen.
echo "==> Empaquetando venv.zip dentro de un contenedor de ${IMAGEN}"
MSYS_NO_PATHCONV=1 docker run --rm -v "${AQUI}:/out" "${IMAGEN}" bash -c '
  set -euo pipefail
  python -m venv --copies /tmp/venv
  /tmp/venv/bin/pip install --no-cache-dir --upgrade pip
  /tmp/venv/bin/pip install --no-cache-dir apache-flink==1.17.0 pydantic requests redis cloudpickle

  echo "==> Empaquetando libpython + stdlib base junto al venv (portabilidad)"
  # `venv --copies` solo copia el EJECUTABLE -- ni la libreria compartida
  # (libpython3.10.so.1.0, resuelta por el cache de ldconfig del SISTEMA,
  # /usr/local/lib/, que no existe en otra maquina) ni la libreria
  # estandar (los .py de siempre -- os.py, encodings/, etc., que tampoco
  # viven dentro del venv, solo en el prefix base) viajan con el venv por
  # defecto. Confirmado en 2 intentos reales contra el cluster: primero
  # "cannot open shared object file" (faltaba la .so), despues
  # "ModuleNotFoundError: No module named encodings" (faltaba la stdlib).
  # Se empaquetan ambas DENTRO del venv para que sea de verdad autonomo.
  mkdir -p /tmp/venv/lib_externa
  cp /usr/local/lib/libpython3.10.so* /tmp/venv/lib_externa/
  cp -r /usr/local/lib/python3.10/. /tmp/venv/lib/python3.10/
  for bin in /tmp/venv/bin/python /tmp/venv/bin/python3 /tmp/venv/bin/python3.10; do
    patchelf --set-rpath "\$ORIGIN/../lib_externa" "${bin}"
  done

  # pyvenv.cfg le dice al interprete que su "home" (para ubicar la stdlib)
  # es la ruta del contenedor de build (/usr/local/bin) -- en el host real
  # eso no existe, y CPython ni siquiera prueba la stdlib que ya copiamos
  # DENTRO del venv un paso atras ("ModuleNotFoundError: No module named
  # encodings", confirmado). Sin este archivo, CPython cae a su busqueda
  # por defecto relativa al propio ejecutable (bin/../lib/python3.10),
  # que es exactamente donde esta todo ahora.
  rm -f /tmp/venv/pyvenv.cfg

  cd /tmp
  python -c "import shutil; shutil.make_archive(\"/out/venv\", \"zip\", \"/tmp\", \"venv\")"
'

echo "==> Listo: ${AQUI}/venv.zip"
ls -lh "${AQUI}/venv.zip"
