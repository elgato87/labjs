#!/usr/bin/env bash
# =============================================================================
# JumpServer EE - Script de Instalación y Despliegue en Red Hat (RHEL 8/9)
# =============================================================================
# Este script automatiza la preparación completa del nodo JumpServer en un RHEL limpio:
# - Paquetes requeridos (Podman, plugins de red, Docker Compose standalone)
# - Socket de Podman y Firewall (firewalld)
# - Permisos SELinux en volúmenes montados
# - Re-etiquetado de imágenes EE y descarga de Nginx
# - Configuración de .env.ee con claves seguras
# - Parche persistente del DNS de Podman (192.168.250.1)
# - Despliegue de los contenedores
# =============================================================================

set -euo pipefail

# Colores para salida de terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}        Instalador Automatizado de JumpServer EE (RHEL / Podman)     ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# 1. Comprobar que se ejecute como root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Este script debe ejecutarse como root o con sudo.${NC}"
  exit 1
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "${PROJECT_DIR}"

# 2. Instalar paquetes necesarios
echo -e "\n${YELLOW}>>> [1/7] Instalando paquetes del sistema...${NC}"
dnf install -y podman podman-plugins curl openssl nmap-ncat git

# 3. Instalar Docker Compose Standalone v2 y habilitar Podman Socket
echo -e "\n${YELLOW}>>> [2/7] Configurando Podman Socket y Docker Compose v2...${NC}"
systemctl enable --now podman.socket

if ! command -v docker-compose &>/dev/null; then
  echo "Descargando binario oficial de docker-compose..."
  curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
fi
echo -e "${GREEN}Docker Compose v2 listo.${NC}"

# 4. Configurar Firewall (firewalld)
echo -e "\n${YELLOW}>>> [3/7] Configurando reglas en firewalld...${NC}"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port={80,2222,3389,3390}/tcp
  firewall-cmd --permanent --zone=trusted --add-source=192.168.250.0/24
  firewall-cmd --permanent --zone=public --add-masquerade
  firewall-cmd --reload
  echo -e "${GREEN}Puertos 80, 2222, 3389, 3390 y subred 192.168.250.0/24 habilitados.${NC}"
else
  echo -e "${YELLOW}firewalld no está activo, omitiendo.${NC}"
fi

# 5. Configurar permisos SELinux
echo -e "\n${YELLOW}>>> [4/7] Aplicando etiquetas SELinux...${NC}"
mkdir -p ./nginx
if [ -d "./jumpserver-ee-v4.10.17-x86_64/config_init" ]; then
  chcon -Rt svirt_sandbox_file_t ./jumpserver-ee-v4.10.17-x86_64/config_init
fi
chcon -Rt svirt_sandbox_file_t ./nginx

# 6. Preparar imágenes de JumpServer
echo -e "\n${YELLOW}>>> [5/7] Verificando y etiquetando imágenes en Podman...${NC}"
# Re-etiquetar si las imágenes vienen con el prefijo gabrielpose/labjs
COMPONENTS=(core web koko lion chen razor xrdp panda video-worker)
for comp in "${COMPONENTS[@]}"; do
  if podman image exists "docker.io/gabrielpose/labjs:${comp}-v4.10.17-ee"; then
    echo "Etiquetando ${comp} para Podman..."
    podman tag "docker.io/gabrielpose/labjs:${comp}-v4.10.17-ee" "docker.io/jumpserver/${comp}:v4.10.17-ee" 2>/dev/null || true
    podman tag "docker.io/gabrielpose/labjs:${comp}-v4.10.17-ee" "localhost/jumpserver/${comp}:v4.10.17-ee" 2>/dev/null || true
  fi
done

# Descargar Nginx si falta
if ! podman image exists "docker.io/nginx:1.27-alpine" && ! podman image exists "nginx:1.27-alpine"; then
  echo "Descargando imagen del balanceador Nginx..."
  podman pull docker.io/nginx:1.27-alpine
fi

# 7. Configuración de variables (.env.ee)
echo -e "\n${YELLOW}>>> [6/7] Verificando archivo de configuración (.env.ee)...${NC}"
if [ ! -f .env.ee ]; then
  if [ -f .env.ee.example ]; then
    cp .env.ee.example .env.ee
  else
    touch .env.ee
  fi
  # Generar claves maestras únicas
  sed -i "s/SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 24)/" .env.ee
  sed -i "s/BOOTSTRAP_TOKEN=.*/BOOTSTRAP_TOKEN=$(openssl rand -hex 12)/" .env.ee
  echo -e "${GREEN}Archivo .env.ee creado con SECRET_KEY y BOOTSTRAP_TOKEN nuevos.${NC}"
  echo -e "${RED}[IMPORTANTE] Editá .env.ee y completá las IPs de tu PostgreSQL y Redis externos antes de continuar.${NC}"
else
  echo -e "${GREEN}Archivo .env.ee ya existe.${NC}"
fi

# 8. Generar configuración persistente de Nginx con DNS de Podman (192.168.250.1)
echo -e "\n${YELLOW}>>> [7/7] Preparando archivo de resolución DNS para Nginx...${NC}"
if [ ! -f ./nginx/web-nginx.conf ]; then
  WEB_IMG=""
  for img in "docker.io/jumpserver/web:v4.10.17-ee" "localhost/jumpserver/web:v4.10.17-ee" "docker.io/gabrielpose/labjs:web-v4.10.17-ee"; do
    if podman image exists "$img"; then
      WEB_IMG="$img"
      break
    fi
  done

  if [ -z "$WEB_IMG" ]; then
    echo -e "${RED}[ERROR] No se encontró ninguna imagen de JumpServer Web localmente.${NC}"
    exit 1
  fi

  echo "Extrayendo plantilla base de nginx.conf desde ${WEB_IMG}..."
  temp_id=$(podman create "${WEB_IMG}")
  podman cp "${temp_id}:/etc/nginx/nginx.conf" ./nginx/web-nginx.conf
  podman rm "${temp_id}" >/dev/null
  # Reemplazar 127.0.0.11 por la IP real del gateway DNS de Podman
  sed -i 's/127.0.0.11/192.168.250.1/g' ./nginx/web-nginx.conf
  chcon -t svirt_sandbox_file_t ./nginx/web-nginx.conf
  echo -e "${GREEN}Archivo ./nginx/web-nginx.conf configurado con resolver 192.168.250.1.${NC}"
fi

# 9. Levantar el stack
echo -e "\n${BLUE}=====================================================================${NC}"
echo -e "${GREEN}>>> Iniciando JumpServer con Docker Compose...${NC}"
export DOCKER_HOST="unix:///run/podman/podman.sock"
docker-compose -f docker-compose.ee.yml up -d

echo -e "\n${GREEN}=====================================================================${NC}"
echo -e "${GREEN}   ¡INSTALACIÓN Y ARRANQUE COMPLETADOS EXITOSAMENTE! ✅             ${NC}"
echo -e "${GREEN}=====================================================================${NC}"
echo -e "Web UI:      http://$(hostname -I | awk '{print $1}')"
echo -e "SSH Bastion: ssh -p 2222 admin@$(hostname -I | awk '{print $1}')"
echo -e "Usuario:     admin"
echo -e "Contraseña:  admin (te pedirá cambiarla en el primer ingreso)"
echo -e "\nPara ver los logs del backend:"
echo -e "  sudo podman logs -f jms_core"
echo -e "=====================================================================\n"

