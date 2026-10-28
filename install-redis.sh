#!/usr/bin/env bash
# =============================================================================
# JumpServer - Script de Instalación de Redis 7 en Red Hat (RHEL 8/9)
# =============================================================================
# Instala y configura Redis 7 listo para ser usado por JumpServer EE.
# Configura contraseña, escucha en red y política de memoria.
#
# Uso:
#   chmod +x install-redis.sh
#   sudo ./install-redis.sh
#
# Variables que podés editar antes de correr el script:
REDIS_PASSWORD="jump"    # Cambiá por una contraseña segura
REDIS_BIND="0.0.0.0"    # Escuchar en todas las interfaces (recomendado dejar así)
REDIS_PORT=6379
MAX_MEMORY="512mb"       # Ajustá según la RAM disponible del servidor
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}       Instalador de Redis 7 para JumpServer EE (RHEL / DNF)        ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# 1. Verificar que sea root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root o con sudo.${NC}"
  exit 1
fi

# 2. Instalar Redis
echo -e "\n${YELLOW}>>> [1/5] Instalando Redis...${NC}"
# En RHEL 8 y 9 Redis 7 viene en los repositorios de AppStream
dnf install -y redis
echo -e "${GREEN}Redis instalado correctamente.${NC}"

# 3. Configurar Redis
echo -e "\n${YELLOW}>>> [2/5] Configurando Redis...${NC}"

# Detectar archivo de configuración
if [ -f /etc/redis/redis.conf ]; then
  REDIS_CONF="/etc/redis/redis.conf"
elif [ -f /etc/redis.conf ]; then
  REDIS_CONF="/etc/redis.conf"
else
  echo -e "${RED}[ERROR] No se encontró el archivo de configuración de Redis.${NC}"
  exit 1
fi

echo "Usando archivo de configuración: ${REDIS_CONF}"

# Bind: escuchar en todas las interfaces
sed -i "s/^bind .*/bind ${REDIS_BIND}/" "${REDIS_CONF}"

# Puerto
sed -i "s/^port .*/port ${REDIS_PORT}/" "${REDIS_CONF}"

# Contraseña
if grep -q "^requirepass " "${REDIS_CONF}"; then
  sed -i "s/^requirepass .*/requirepass ${REDIS_PASSWORD}/" "${REDIS_CONF}"
elif grep -q "^# requirepass " "${REDIS_CONF}"; then
  sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" "${REDIS_CONF}"
else
  echo "requirepass ${REDIS_PASSWORD}" >> "${REDIS_CONF}"
fi

# Memoria máxima y política de evicción (recomendado para JumpServer)
if grep -q "^maxmemory " "${REDIS_CONF}"; then
  sed -i "s/^maxmemory .*/maxmemory ${MAX_MEMORY}/" "${REDIS_CONF}"
else
  echo "maxmemory ${MAX_MEMORY}" >> "${REDIS_CONF}"
fi

if grep -q "^maxmemory-policy " "${REDIS_CONF}"; then
  sed -i "s/^maxmemory-policy .*/maxmemory-policy allkeys-lru/" "${REDIS_CONF}"
else
  echo "maxmemory-policy allkeys-lru" >> "${REDIS_CONF}"
fi

# Proteger modo (desactivar para permitir conexiones externas con contraseña)
sed -i "s/^protected-mode yes/protected-mode no/" "${REDIS_CONF}"
if ! grep -q "^protected-mode" "${REDIS_CONF}"; then
  echo "protected-mode no" >> "${REDIS_CONF}"
fi

echo -e "${GREEN}Redis configurado (bind ${REDIS_BIND}, port ${REDIS_PORT}, contraseña establecida).${NC}"

# 4. Iniciar y habilitar el servicio
echo -e "\n${YELLOW}>>> [3/5] Iniciando servicio Redis...${NC}"
systemctl enable --now redis
echo -e "${GREEN}Servicio Redis activo y habilitado.${NC}"

# 5. Verificar que responda
echo -e "\n${YELLOW}>>> [4/5] Verificando conexión a Redis...${NC}"
sleep 1
if redis-cli -a "${REDIS_PASSWORD}" -p "${REDIS_PORT}" ping | grep -q "PONG"; then
  echo -e "${GREEN}Redis responde correctamente (PONG).${NC}"
else
  echo -e "${RED}[ADVERTENCIA] Redis no respondió al PING. Revisá el servicio con: systemctl status redis${NC}"
fi

# 6. Abrir puerto en firewalld
echo -e "\n${YELLOW}>>> [5/5] Abriendo puerto ${REDIS_PORT} en firewalld...${NC}"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${REDIS_PORT}/tcp"
  firewall-cmd --reload
  echo -e "${GREEN}Puerto ${REDIS_PORT} abierto.${NC}"
else
  echo -e "${YELLOW}firewalld no está activo, omitiendo.${NC}"
fi

# Resumen final
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}=====================================================================${NC}"
echo -e "${GREEN}   Redis 7 instalado y listo para JumpServer EE ✅                  ${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo -e "Host:       ${LOCAL_IP}"
echo -e "Puerto:     ${REDIS_PORT}"
echo -e "Contraseña: ${REDIS_PASSWORD}"
echo -e "\nConfigurar en .env.ee del servidor JumpServer:"
echo -e "  REDIS_HOST=${LOCAL_IP}"
echo -e "  REDIS_PORT=${REDIS_PORT}"
echo -e "  REDIS_PASSWORD=${REDIS_PASSWORD}"
echo -e "=====================================================================\n"
