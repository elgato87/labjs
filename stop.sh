#!/usr/bin/env bash
# Detiene el lab. Los datos quedan guardados en los volúmenes.
#   ./stop.sh            -> detiene y borra contenedores (conserva datos)
#   ./stop.sh --wipe     -> borra TAMBIÉN los datos (empezás de cero)
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "--wipe" ]; then
  echo ">> Borrando contenedores Y datos (volúmenes)..."
  docker compose down -v
  rm -f vault-init.json vault-jms-token.txt .env
  echo ">> Limpieza total hecha."
else
  echo ">> Deteniendo el lab (los datos se conservan)..."
  docker compose down
  echo ">> Hecho. Para volver a arrancar: ./start.sh"
fi
