#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Inicializa el cluster Vault (3 nodos Raft) del lab:
#   - init + unseal de los 3 nodos
#   - habilita KV v2 en el path "jumpserver"
#   - crea la policy y un token periodico para JumpServer
# Requisitos: docker, jq. Ejecutar UNA sola vez, tras "docker compose up -d".
# ---------------------------------------------------------------------------
set -euo pipefail

OUT="vault-init.json"

echo ">> Esperando a que vault1 responda..."
until docker exec vault1 vault status -address=http://127.0.0.1:8200 2>/dev/null | grep -q "Initialized"; do
  sleep 2
done

if docker exec vault1 vault status -address=http://127.0.0.1:8200 2>/dev/null | grep -q "Initialized *true"; then
  echo "!! Vault ya estaba inicializado. Si perdiste las llaves, borra los volumenes:"
  echo "   docker compose down -v   (CUIDADO: borra todos los datos del lab)"
  exit 1
fi

echo ">> Inicializando vault1 (3 unseal keys, umbral 2)..."
docker exec vault1 vault operator init \
  -address=http://127.0.0.1:8200 \
  -key-shares=3 -key-threshold=2 -format=json > "$OUT"
echo "   Llaves y root token guardados en $OUT  (GUARDALO SEGURO)"

UNSEAL1=$(jq -r '.unseal_keys_b64[0]' "$OUT")
UNSEAL2=$(jq -r '.unseal_keys_b64[1]' "$OUT")
ROOT=$(jq -r '.root_token' "$OUT")

unseal_node () {
  local c=$1
  echo ">> Desellando $c ..."
  # Espera a que el nodo este listo (vault2/3 hacen retry_join tras unsealar vault1)
  for i in $(seq 1 30); do
    if docker exec "$c" vault operator unseal -address=http://127.0.0.1:8200 "$UNSEAL1" >/dev/null 2>&1; then
      docker exec "$c" vault operator unseal -address=http://127.0.0.1:8200 "$UNSEAL2" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 3
  done
  echo "   (aviso) no se pudo desellar $c automaticamente; reintenta manual."
}

unseal_node vault1
sleep 5          # dar tiempo a que vault2/vault3 se unan al raft
unseal_node vault2
unseal_node vault3

echo ">> Estado del cluster Raft:"
docker exec -e VAULT_TOKEN="$ROOT" vault1 vault operator raft list-peers -address=http://127.0.0.1:8200 || true

echo ">> Habilitando KV v2 en 'jumpserver' y creando policy..."
docker exec -e VAULT_TOKEN="$ROOT" vault1 vault secrets enable -address=http://127.0.0.1:8200 -path=jumpserver -version=2 kv 2>/dev/null || echo "   (ya existia)"

docker exec -e VAULT_TOKEN="$ROOT" -i vault1 vault policy write -address=http://127.0.0.1:8200 jumpserver - <<'EOF'
path "jumpserver/*"          { capabilities = ["create","read","update","delete","list"] }
path "jumpserver/data/*"     { capabilities = ["create","read","update","delete","list"] }
path "jumpserver/metadata/*" { capabilities = ["list","read","delete"] }
EOF

echo ">> Creando token periodico para JumpServer..."
JMS_TOKEN=$(docker exec -e VAULT_TOKEN="$ROOT" vault1 vault token create \
  -address=http://127.0.0.1:8200 -policy=jumpserver -period=768h -field=token)

# Guardar el token para que start.sh lo inyecte en .env automaticamente
echo "$JMS_TOKEN" > vault-jms-token.txt

echo
echo "==========================================================="
echo " Pegá este token en tu archivo .env:"
echo
echo "   VAULT_ENABLED=true"
echo "   VAULT_HCP_TOKEN=$JMS_TOKEN"
echo
echo " Luego reinicia los nodos JumpServer (imagen EE):"
echo "   docker compose up -d jms-node1 jms-node2"
echo "==========================================================="
