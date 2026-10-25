# Replicacion del lab JumpServer, PostgreSQL, Redis y Vault

Esta guia resume la configuracion y las pruebas realizadas en este workspace para poder repetir el laboratorio. Esta pensada para Docker Desktop en Windows usando Git Bash o WSL.

> **Importante sobre secretos:** el `.env.ee` actual contiene credenciales y un token de Vault reales de este lab. No los copies a otro entorno ni los subas a Git. Genera valores nuevos y rota los actuales si el repo se compartio o se guardo en un remoto. Los archivos `vault-init.json` y `vault-jms-token.txt` tambien contienen material sensible.

## 1. Elegir la topologia

En el repo hay dos Compose distintos para JumpServer; no son intercambiables:

| Archivo | Topologia | Uso |
|---|---|---|
| `docker-compose.ee.yml` | Servicios EE separados (`core`, `celery`, `web1`, `web2`, `koko`, etc.), PostgreSQL, Redis y tres Vault | Es la variante EE que se levanto y verifico durante esta sesion. Usa `.env.ee` y las imagenes locales `v4.10.17-ee`. |
| `docker-compose.yml` | Dos nodos `jms-node1`/`jms-node2`, PostgreSQL, Redis, Vault y NGINX | Variante HA alternativa documentada en `README.md`. Usa `.env`, `JMS_IMAGE` y `nginx/nginx.conf`. No se debe asumir que fue la que se valido en esta sesion. |
| `docker-compose.mysql.yml` | MySQL independiente para pruebas | Servicio auxiliar; no reemplaza el PostgreSQL que usa JumpServer. |

Los comandos siguientes usan `docker-compose.ee.yml`, que corresponde al stack EE revisado. Ejecutalos desde la carpeta del proyecto.

## 2. Requisitos y puertos

- Docker Desktop iniciado y con recursos suficientes para las imagenes del lab.
- Git Bash o WSL para los scripts `.sh`.
- Imagenes disponibles localmente. El Compose EE tiene `pull_policy: never`; comprueba los tags antes de levantarlo:

  ```bash
  docker image ls
  docker image inspect jumpserver/core:v4.10.17-ee
  docker image inspect hashicorp/vault:1.17
  ```

- Puertos libres del host: `80`, `2222`, `3389`, `3390`, `8200`, `8210` y `8220`. PostgreSQL y Redis no publican sus puertos al host en esta variante.

## 3. Preparar la configuracion EE

El archivo `docker-compose.ee.yml` carga `.env.ee` para los servicios de JumpServer, PostgreSQL y Redis. Verifica que incluya las variables necesarias, sin reutilizar los secretos de este repo:

```dotenv
SECRET_KEY=<clave-aleatoria-larga>
BOOTSTRAP_TOKEN=<token-aleatorio>
DB_ENGINE=postgresql
DB_HOST=postgresql
DB_PORT=5432
DB_USER=jumpserver
DB_PASSWORD=<clave-db-aleatoria>
DB_NAME=jumpserver
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=<clave-redis-aleatoria>
VAULT_ENABLED=true
VAULT_BACKEND=hcp
VAULT_HCP_HOST=http://vault1:8200
VAULT_HCP_TOKEN=<token-creado-en-vault>
VAULT_HCP_MOUNT_POINT=jumpserver
FACELIVE_ENABLED=0
```

Con OpenSSL puedes generar valores nuevos desde Git Bash/WSL:

```bash
openssl rand -hex 32
openssl rand -hex 24
openssl rand -hex 24
```

Usa las salidas para `SECRET_KEY`, `BOOTSTRAP_TOKEN` y las contraseñas, respectivamente. Protege `.env.ee` y no incluyas sus valores al compartir logs o capturas.

> En la configuracion verificada, `DB_HOST=postgresql` es el nombre DNS del servicio Compose, no `localhost`. Desde Windows, PostgreSQL no es accesible por puerto publicado porque no hay mapeo `5432:5432`.

## 4. Validar la configuracion e iniciar el stack

Primero valida la sintaxis y las variables del Compose:

```bash
docker compose -f docker-compose.ee.yml config
```

Levanta el stack:

```bash
docker compose -f docker-compose.ee.yml up -d
```

Comprueba los servicios y sus estados:

```bash
docker compose -f docker-compose.ee.yml ps
```

Para revisar logs de un servicio:

```bash
docker compose -f docker-compose.ee.yml logs --tail 100 core
```

La lista debe incluir, entre otros, `jms_core`, `jms_postgresql`, `jms_redis`, `vault1`, `vault2`, `vault3`, `jms_web1`, `jms_web2` y `jms_lb`. PostgreSQL y Redis deben pasar a `healthy`.

## 5. Inicializar Vault (solo en un cluster nuevo)

El script `vault-init.sh` inicializa Vault, crea un KV v2 en `jumpserver`, instala la policy de JumpServer y genera un token periodico. En la version actual del script, la inicializacion usa tres unseal keys y un umbral de dos.

Comprueba que esten disponibles `docker` y `jq`, luego ejecuta una sola vez:

```bash
chmod +x vault-init.sh
./vault-init.sh
```

El script crea `vault-init.json` con las unseal keys y el root token, y `vault-jms-token.txt` con el token de aplicacion. Guardalos fuera del control de versiones y con acceso restringido. Copia el token de aplicacion al valor `VAULT_HCP_TOKEN` de `.env.ee` y recrea los servicios que lo consumen:

```bash
docker compose -f docker-compose.ee.yml up -d --force-recreate core celery koko lion chen razor xrdp panda video
```

Comprueba el estado del nodo principal:

```bash
docker exec vault1 sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
```

Debe indicar `Initialized true` y `Sealed false`. Para comprobar los peers Raft se necesita el root token; evita pegarlo en terminales compartidas o guardar el comando en scripts.

### Si Vault ya estaba inicializado

No vuelvas a ejecutar `vault operator init` ni borres los volumenes como primer intento. El script termina con error si detecta que Vault ya esta inicializado; eso no significa por si solo que el servicio este caido. Comprueba:

```bash
docker exec vault1 sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status'
```

En el estado existente inspeccionado durante esta sesion, Vault estaba inicializado, desellado y en modo `active`, con almacenamiento Raft. El status de esa instancia mostraba una sola share y umbral uno, porque se habia inicializado previamente con otros parametros; una ejecucion fresca del script actual configuraria 3 shares y umbral 2. Las unseal keys no se pueden recuperar desde el status. Si Vault aparece `Sealed true`, usa las keys originales. `docker compose down -v` destruye datos de PostgreSQL, Vault y otros volumenes; usalo solo para reiniciar el laboratorio desde cero y despues de respaldar lo necesario.

## 6. Verificar JumpServer y Vault

Comprueba que el contenedor core recibio las variables, sin imprimir el valor del token:

```bash
docker exec jms_core sh -c 'env | grep -E "^VAULT_(ENABLED|BACKEND|HCP_HOST|HCP_MOUNT_POINT)="'
```

Revisa los mensajes relevantes del log:

```bash
docker logs jms_core 2>&1 | grep -i vault
```

Durante esta sesion se verifico que `jms_core` recibio `VAULT_ENABLED=true`, el endpoint `http://vault1:8200` y el mount `jumpserver`; tambien aparecio `Start subscribe vault change`. Esto confirma que la configuracion fue inyectada y que JumpServer inicio la suscripcion a cambios de Vault. **No equivale por si solo a demostrar una escritura/lectura exitosa de una credencial.** Para validar el flujo funcional, carga la licencia EE y configura/sincroniza el almacenamiento de cuentas en la interfaz de JumpServer; luego confirma el secreto en Vault con una consulta autenticada y el root token, sin exponerlo en logs.

La integracion de almacenamiento de credenciales requiere la edicion Enterprise y licencia habilitada. Las variables `VAULT_*` no activan esa funcion en Community Edition.

## 7. Verificar conectividad de JumpServer a PostgreSQL

La prueba debe ejecutarse desde el contenedor de aplicacion y usar el hostname interno `postgresql`:

```bash
docker exec jms_core sh -c 'python3 -c "import socket; s=socket.socket(); s.settimeout(5); s.connect((\"postgresql\",5432)); print(\"TCP OK: jms_core alcanza postgresql:5432\"); s.close()"'
```

En esta sesion la conexion TCP termino correctamente (`TCP OK`). Esto comprueba red/puerto, no autentica el usuario. Para comprobar tambien login SQL, ejecuta `psql` desde un contenedor que tenga el cliente instalado, usando `DB_USER`, `DB_PASSWORD` y `DB_NAME` de `.env.ee`; evita poner la contraseña literal en el historial del shell.

## 8. NGINX y acceso web

La configuracion `nginx/ee-nginx.conf` balancea entre `web1:80` y `web2:80`, y el servicio `jms_lb` publica el puerto 80. Prueba desde el host:

```bash
curl -I http://localhost/
curl -I http://localhost/api/v1/settings/public/open/
```

Durante la sesion el balanceador respondio `200` en las comprobaciones de HTTP. La URL local es `http://localhost`. El usuario inicial indicado en la documentacion del lab es `admin` / `ChangeMe`; cambia esa clave en el primer acceso y no uses ese valor fuera de un laboratorio.

## 9. MySQL auxiliar (opcional)

`docker-compose.mysql.yml` crea una base separada para pruebas, no usada por JumpServer:

- Host desde Windows: `127.0.0.1`
- Puerto: `3306`
- Usuario: `admin`
- Password de laboratorio: `admin`
- Base: `demo`

Arranque y estado:

```bash
docker compose -f docker-compose.mysql.yml up -d mysql
docker ps --filter name=demo_mysql
```

La imagen se inicializa la primera vez; puede tardar un poco antes de aceptar conexiones. `telnet localhost 3306` no es una prueba adecuada de login MySQL: el protocolo no es una consola de texto. Usa un cliente MySQL, o prueba localmente dentro del contenedor:

```bash
docker exec -it demo_mysql mysql -u admin -p demo
```

Cuando pida la clave, escribe `admin`. La cuenta `admin` solo tiene acceso a la base `demo`; la variable `MYSQL_ROOT_PASSWORD` define por separado la clave de `root`.

El servicio usa el puerto host `3306`; si ya esta ocupado, cambia el lado izquierdo del mapeo, por ejemplo `3307:3306`, y conecta al puerto `3307`.

## 10. Problemas encontrados y resoluciones

- **Vault: permiso denegado en `/vault/data/vault.db`:** la variante EE del Compose ejecuta `chown -R 100:1000 /vault/data` antes de arrancar Vault. Esta inicializacion de permisos se aplica al volumen de datos.
- **Redis: password o variables sin expandir:** la variante EE usa `sh -c` para expandir `REDIS_PASSWORD` al ejecutar `redis-server`; el healthcheck autentica tambien con esa variable.
- **Errores de upstream `facelive` en NGINX:** se desactivo con `FACELIVE_ENABLED=0` en `.env.ee` para este lab.
- **Telnet a MySQL no da una respuesta legible:** usa el cliente MySQL para validar el protocolo y la autenticacion.
- **Compose muestra contenedores ajenos como `orphan`:** ambos archivos Compose pueden resolver al mismo nombre de proyecto predeterminado (`demo`). No ejecutes `down` sin especificar que stack quieres detener. `docker-compose.mysql.yml` fija `container_name: demo_mysql`; no intentes crear otra instancia con ese mismo nombre mientras exista el contenedor.
- **PostgreSQL con `healthy` pero la aplicacion falla:** mira los logs de `core` y verifica que usuario, password, base y host coincidan entre `.env.ee` y PostgreSQL. No borres `pgdata` sin respaldo y confirmacion: eso elimina la base persistente.

## 11. Detener y reiniciar

Detener solo la variante EE sin eliminar los volumenes:

```bash
docker compose -f docker-compose.ee.yml down
```

Volver a iniciarla:

```bash
docker compose -f docker-compose.ee.yml up -d
```

El cambio de `.env.ee` se aplica al recrear los contenedores correspondientes. `restart` reinicia los contenedores existentes, pero no siempre actualiza su configuracion/env; usa `up -d --force-recreate <servicios>` cuando hayas cambiado variables.

> No uses `down -v` a menos que quieras borrar los datos persistentes. Antes, exporta PostgreSQL y respalda Vault y sus llaves.

## 12. Variante HA `docker-compose.yml`

Para reproducir la topologia alternativa descrita por el `README.md` del repo, prepara `.env` a partir de `.env.example`, usa una imagen disponible en `JMS_IMAGE`, y sigue la secuencia documentada:

```bash
cp .env.example .env
# Edita .env y genera valores nuevos para secretos y passwords
docker compose config
docker compose up -d jms-postgres jms-redis vault1 vault2 vault3
./vault-init.sh
docker compose up -d jms-node1
# Espera a que node1 termine las migraciones y quede listo
docker compose up -d jms-node2 jms-lb
```

Esta variante separa primero las migraciones de la base para evitar que los dos nodos las ejecuten simultaneamente. La integracion Vault tambien necesita una imagen EE y licencia. Revisa `README.md`, `.env.example`, `start.sh`, `vault-init.sh` y `nginx/nginx.conf` antes de usarla; no mezcles sus nombres de servicios ni su archivo `.env` con la variante EE anterior.
