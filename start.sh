#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ARRANQUE EN UN SOLO COMANDO del lab HA (JumpServer + Vault) en Docker Desktop.
#   ./start.sh
# Hace todo: genera .env con claves aleatorias, levanta datos + Vault,
# inicializa el cluster Vault, y arranca los 2 nodos JumpServer + el balanceador.
# Requisitos: docker (con compose v2), openssl, jq, curl.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

# --- Chequeos ---
command -v docker  >/dev/null 2>&1 || { echo "!! Falta docker"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "!! Falta docker compose v2"; exit 1; }
command -v jq      >/dev/null 2>&1 || { echo "!! Falta jq (Mac: brew install jq)"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "!! Falta openssl"; exit 1; }

# Setea KEY=value en .env (reemplaza si existe, agrega si no)
set_env () {
  local key="$1" val="$2"
  [ -f .env ] || touch .env
  if grep -q "^${key}=" .env; then
    grep -v "^${key}=" .env > .env.tmp && mv .env.tmp .env
  fi
  echo "${key}=${val}" >> .env
}

# --- 1) .env con claves aleatorias (solo la primera vez) ---
if [ ! -f .env ]; then
  echo ">> Generando .env con claves aleatorias..."
  cp .env.example .env
  set_env SECRET_KEY      "$(openssl rand -hex 24)"
  set_env BOOTSTRAP_TOKEN "$(openssl rand -hex 12)"
  set_env DB_PASSWORD     "$(openssl rand -hex 12)"
  set_env REDIS_PASSWORD  "$(openssl rand -hex 12)"
  set_env VAULT_ENABLED   "false"
else
  echo ">> .env ya existe, lo reuso."
fi

# --- 2) Datos + Vault ---
echo ">> Levantando PostgreSQL, Redis y los 3 nodos Vault..."
docker compose up -d jms-postgres jms-redis vault1 vault2 vault3

# --- 3) Init del cluster Vault (idempotente) ---
if [ ! -f vault-init.json ]; then
  echo ">> Inicializando el cluster Vault..."
  chmod +x vault-init.sh
  ./vault-init.sh || echo "   (revisá la salida de vault-init si algo falló)"
else
  echo ">> Vault ya estaba inicializado (vault-init.json presente)."
fi

# Inyectar el token de Vault en .env (queda listo para cuando uses la imagen EE)
if [ -f vault-jms-token.txt ]; then
  set_env VAULT_HCP_TOKEN "$(cat vault-jms-token.txt)"
  echo ">> Token de Vault guardado en .env (VAULT_HCP_TOKEN)."
fi

# --- 4) JumpServer: nodo 1, esperar, luego nodo 2 + balanceador ---
echo ">> Levantando nodo 1 (corre las migraciones de BD)..."
docker compose up -d jms-node1

echo ">> Esperando a que el nodo 1 termine de iniciar (puede tardar 1-4 min)..."
ready=0
for i in $(seq 1 60); do
  if docker exec jms-node1 sh -c 'curl -fsS http://127.0.0.1/api/health/ >/dev/null 2>&1'; then
    ready=1; break
  fi
  sleep 5
done
if [ "$ready" = 1 ]; then echo "   nodo 1 OK."
else echo "   (no confirmé el health; sigo igual. Si algo falla: docker compose logs jms-node1)"; fi

echo ">> Levantando nodo 2 y el balanceador..."
docker compose up -d jms-node2 jms-lb

echo
echo "==================================================================="
echo "  LISTO ✅"
echo "  Web:   http://localhost        (usuario: admin  /  pass: ChangeMe)"
echo "  SSH:   ssh -p 2222 <usuario>@localhost"
echo "  Vault: http://localhost:8200   (unseal keys en vault-init.json)"
echo
echo "  Integración con Vault: requiere imagen Enterprise. Cuando la tengas,"
echo "  poné JMS_IMAGE=<EE> y VAULT_ENABLED=true en .env y corré:"
echo "     docker compose up -d jms-node1 jms-node2"
echo "==================================================================="
