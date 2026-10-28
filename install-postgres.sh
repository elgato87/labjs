#!/usr/bin/env bash
# =============================================================================
# JumpServer - Script de Instalación de PostgreSQL 16 en Red Hat (RHEL 8/9)
# =============================================================================
# Instala y configura PostgreSQL 16 listo para ser usado por JumpServer EE.
# Crea la base de datos, el usuario y abre los accesos necesarios.
#
# Uso:
#   chmod +x install-postgres.sh
#   sudo ./install-postgres.sh
#
# Variables que podés editar antes de correr el script:
DB_NAME="jumpserver"
DB_USER="jumpserver"
DB_PASSWORD="jump"            # Cambiá por una contraseña segura
JUMPSERVER_IP="0.0.0.0/0"    # Reemplazá por la IP del servidor JumpServer (ej: 192.168.1.5/32)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}     Instalador de PostgreSQL 16 para JumpServer EE (RHEL / DNF)    ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# 1. Verificar que sea root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root o con sudo.${NC}"
  exit 1
fi

# 2. Instalar el repositorio oficial de PostgreSQL 16
echo -e "\n${YELLOW}>>> [1/6] Instalando repositorio y paquetes de PostgreSQL 16...${NC}"
# Detectar la versión de RHEL/CentOS
RHEL_VER=$(rpm -E %rhel)

if ! rpm -q pgdg-redhat-repo &>/dev/null; then
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${RHEL_VER}-x86_64/pgdg-redhat-repo-latest.noarch.rpm"
fi

# Deshabilitar el módulo de postgres que viene con el sistema (si existe)
dnf -qy module disable postgresql 2>/dev/null || true

dnf install -y postgresql16-server postgresql16
echo -e "${GREEN}PostgreSQL 16 instalado correctamente.${NC}"

# 3. Inicializar el cluster de base de datos
echo -e "\n${YELLOW}>>> [2/6] Inicializando cluster de PostgreSQL 16...${NC}"
if [ ! -f /var/lib/pgsql/16/data/postgresql.conf ]; then
  /usr/pgsql-16/bin/postgresql-16-setup initdb
  echo -e "${GREEN}Cluster inicializado.${NC}"
else
  echo -e "${GREEN}Cluster ya existente, omitiendo initdb.${NC}"
fi

# 4. Configurar escucha en todas las interfaces y autenticación
echo -e "\n${YELLOW}>>> [3/6] Configurando postgresql.conf y pg_hba.conf...${NC}"
PG_CONF="/var/lib/pgsql/16/data/postgresql.conf"
HBA_CONF="/var/lib/pgsql/16/data/pg_hba.conf"

# Habilitar escucha en todas las IPs
if grep -q "^#listen_addresses" "${PG_CONF}"; then
  sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "${PG_CONF}"
elif grep -q "^listen_addresses" "${PG_CONF}"; then
  sed -i "s/^listen_addresses = .*/listen_addresses = '*'/" "${PG_CONF}"
else
  echo "listen_addresses = '*'" >> "${PG_CONF}"
fi

# Agregar regla de acceso para JumpServer si no existe
RULE="host    ${DB_NAME}    ${DB_USER}    ${JUMPSERVER_IP}    scram-sha-256"
if ! grep -q "${DB_USER}" "${HBA_CONF}"; then
  echo "${RULE}" >> "${HBA_CONF}"
  echo -e "${GREEN}Regla de acceso agregada en pg_hba.conf para ${JUMPSERVER_IP}${NC}"
else
  echo -e "${GREEN}Regla de acceso ya existe en pg_hba.conf.${NC}"
fi

# 5. Iniciar y habilitar el servicio
echo -e "\n${YELLOW}>>> [4/6] Iniciando servicio postgresql-16...${NC}"
systemctl enable --now postgresql-16
echo -e "${GREEN}Servicio postgresql-16 activo y habilitado.${NC}"

# 6. Crear base de datos, usuario y permisos
echo -e "\n${YELLOW}>>> [5/6] Creando base de datos '${DB_NAME}' y usuario '${DB_USER}'...${NC}"
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    RAISE NOTICE 'Usuario ${DB_USER} creado.';
  ELSE
    ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    RAISE NOTICE 'Usuario ${DB_USER} ya existía, contraseña actualizada.';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${DB_NAME} WITH OWNER ${DB_USER} ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
\c ${DB_NAME}
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
EOF
echo -e "${GREEN}Base de datos y usuario configurados.${NC}"

# 7. Abrir puerto en firewalld
echo -e "\n${YELLOW}>>> [6/6] Abriendo puerto 5432 en firewalld...${NC}"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=5432/tcp
  firewall-cmd --reload
  echo -e "${GREEN}Puerto 5432 abierto.${NC}"
else
  echo -e "${YELLOW}firewalld no está activo, omitiendo.${NC}"
fi

# Resumen final
LOCAL_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${GREEN}=====================================================================${NC}"
echo -e "${GREEN}   PostgreSQL 16 instalado y listo para JumpServer EE ✅            ${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo -e "Host:       ${LOCAL_IP}"
echo -e "Puerto:     5432"
echo -e "Base:       ${DB_NAME}"
echo -e "Usuario:    ${DB_USER}"
echo -e "Contraseña: ${DB_PASSWORD}"
echo -e "\nConfigurar en .env.ee del servidor JumpServer:"
echo -e "  DB_ENGINE=postgresql"
echo -e "  DB_HOST=${LOCAL_IP}"
echo -e "  DB_PORT=5432"
echo -e "  DB_USER=${DB_USER}"
echo -e "  DB_PASSWORD=${DB_PASSWORD}"
echo -e "  DB_NAME=${DB_NAME}"
echo -e "=====================================================================\n"
