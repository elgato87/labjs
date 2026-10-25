# Lab HA — JumpServer + HashiCorp Vault en Docker Desktop

Entorno de prueba en **una sola máquina** con Docker Desktop que simula una arquitectura HA:

- **1× PostgreSQL** + **1× Redis** — servicios de datos compartidos.
- **3× Vault** en cluster **Raft (Integrated Storage)** — HA real de secretos.
- **2× JumpServer** (`jms_all`) — tier de aplicación en HA, compartiendo BD, Redis y grabaciones.
- **1× nginx** — balanceador **ya configurado** (web + SSH). No tenés que tocarlo.

```
                 http://localhost   ssh -p 2222 localhost
                          │                │
                    ┌─────▼────────────────▼─────┐
                    │        nginx  (jms-lb)      │   balanceador
                    └───────┬───────────────┬─────┘
                            ▼               ▼
                     ┌────────────┐  ┌────────────┐
                     │ jms-node1  │  │ jms-node2  │   JumpServer (HA)
                     └─────┬──────┘  └──────┬─────┘
                           │  (misma SECRET_KEY / BOOTSTRAP_TOKEN)
              ┌────────────┼────────────────┼───────────────┐
              ▼            ▼                 ▼               ▼
        ┌──────────┐ ┌──────────┐    ┌──────────────────────────┐
        │PostgreSQL│ │  Redis   │    │ vault1 · vault2 · vault3 │  Raft HA
        └──────────┘ └──────────┘    └──────────────────────────┘
```

---

## 🚀 Arranque rápido (un solo comando)

```bash
cd jumpserver-ha-lab
./start.sh          # o:  make up
```

Eso genera las claves, levanta datos + Vault, inicializa el cluster y arranca los 2 nodos + el balanceador. Al terminar, abrí **http://localhost** (`admin` / `ChangeMe`).

Atajos:

```bash
make up        # arranca todo
make ps        # ver estado
make logs      # ver logs
make ha-test   # tira un nodo y lo vuelve a levantar (prueba de HA)
make down      # detener (conserva datos)
make clean     # borrar todo y empezar de cero
```

> En Windows corré `./start.sh` desde **WSL** o **Git Bash** (necesita bash, jq, openssl y curl). El resto del README explica el flujo manual paso a paso por si querés control fino.

---

## ⚠️ Antes de empezar: Community vs Enterprise

La **integración con Vault externo es una función Enterprise Edition** de JumpServer.

- Con la imagen pública **`jumpserver/jms_all` (Community)** podés levantar y probar **toda la HA** (2 nodos + balanceador) y **el cluster Vault por separado**, pero las variables `VAULT_*` **se ignoran**.
- Para que JumpServer guarde credenciales en Vault necesitás la **imagen EE** (la obtenés con el *free trial* de 14 días en https://www.jumpserver.com/free-trial) y cargar la licencia.

Podés hacer todo el lab en dos fases: primero HA con Community, y cuando tengas el trial, cambiás `JMS_IMAGE` a la EE y activás Vault.

---

## Requisitos

- Docker Desktop con **≥ 8 GB de RAM** asignados (Settings → Resources). Son ~8 contenedores.
- `jq` instalado (lo usa `vault-init.sh`). En Mac: `brew install jq`. En Windows usá WSL/Git-Bash.
- Puertos libres en el host: **80**, **2222**, **8200/8210/8220**.

## Estructura de archivos

```
jumpserver-ha-lab/
├── docker-compose.yml
├── .env.example        →  copiar a .env y completar
├── vault-init.sh       →  inicializa el cluster Vault
├── nginx/
│   └── nginx.conf      →  balanceador (no editar)
└── vault/
    ├── vault1.hcl
    ├── vault2.hcl
    └── vault3.hcl
```

---

## Paso a paso

### 1. Preparar el `.env`

```bash
cd jumpserver-ha-lab
cp .env.example .env

# Generá las claves (deben ser fijas e iguales para ambos nodos):
echo "SECRET_KEY=$(openssl rand -hex 24)"       # 48 chars
echo "BOOTSTRAP_TOKEN=$(openssl rand -hex 12)"  # 24 chars
# Copiá esos valores dentro de .env, junto con DB_PASSWORD y REDIS_PASSWORD.
```

Dejá `VAULT_ENABLED=false` por ahora.

### 2. Levantar datos y Vault primero

```bash
docker compose up -d jms-postgres jms-redis vault1 vault2 vault3
```

### 3. Inicializar el cluster Vault

```bash
chmod +x vault-init.sh
./vault-init.sh
```

El script inicializa y desella los 3 nodos, crea el motor KV `jumpserver`, la policy y un **token periódico**. Al final imprime el `VAULT_HCP_TOKEN`. Guardá el archivo `vault-init.json` (contiene las *unseal keys* y el *root token*).

Verificá el cluster:

```bash
docker exec -e VAULT_TOKEN=<root_token> vault1 \
  vault operator raft list-peers -address=http://127.0.0.1:8200
# Deben aparecer vault1 (leader) + vault2 + vault3 (followers)
```

UI de Vault: http://localhost:8200

### 4. Levantar JumpServer y el balanceador

```bash
# Nodo 1 primero (corre las migraciones de BD):
docker compose up -d jms-node1
docker compose logs -f jms-node1        # esperá a que termine de iniciar

# Cuando el nodo 1 esté arriba, sumá el nodo 2 y el balanceador:
docker compose up -d jms-node2 jms-lb
```

> **Importante:** arrancá `jms-node1` solo primero. Si los dos nodos corren las migraciones de BD a la vez pueden chocar. Una vez migrada la BD, el nodo 2 levanta sin problema.

### 5. Entrar

- Web: **http://localhost** (a través del balanceador)
- Usuario inicial: `admin` / `ChangeMe` (te pide cambiarla).

### 6. (Solo EE) Activar la integración con Vault

1. Cambiá en `.env` la imagen a la **EE** (`JMS_IMAGE=...`), poné `VAULT_ENABLED=true` y pegá el `VAULT_HCP_TOKEN` que devolvió el script.
2. Recreá los nodos:
   ```bash
   docker compose up -d jms-node1 jms-node2
   ```
3. Cargá la **licencia EE** en la consola (Sistema → Licencia).
4. Consola → **Configuración → Features → Account storage** → fijá **Record limit** → **Submit** → **Sync** (migra secretos locales → Vault; es unidireccional).
5. Verificá que los secretos viajaron a Vault:
   ```bash
   docker exec -e VAULT_TOKEN=<root_token> vault1 \
     vault kv list -address=http://127.0.0.1:8200 jumpserver/
   ```

---

## Probar la HA

**Tier de aplicación (JumpServer):**

```bash
docker compose stop jms-node1        # tirá un nodo
# Refrescá http://localhost -> el balanceador te sirve por jms-node2.
# La sesión sigue viva porque Redis es compartido.
docker compose start jms-node1
```

**Cluster Vault (Raft):**

```bash
docker compose stop vault1           # cae el leader
docker exec -e VAULT_TOKEN=<root_token> vault2 \
  vault status -address=http://127.0.0.1:8200
# HA Enabled: true, y otro nodo pasa a "active". Con 3 nodos tolera 1 caído.
docker compose start vault1
```

> Nota: al reiniciar un nodo Vault que estaba sellado (por ejemplo tras `docker compose down/up`), hay que **volver a desellarlo** con 2 de las 3 unseal keys (`vault operator unseal`). En un lab con auto-unseal esto se evita, pero aquí usamos Shamir para mantenerlo simple.

---

## Apagar / limpiar

```bash
docker compose down          # detiene y borra contenedores (conserva datos en volúmenes)
docker compose down -v       # ⚠️ borra TAMBIÉN los datos (BD, Vault, grabaciones)
```

---

## Límites conscientes de este lab

| Aspecto | En el lab | Nota |
|--------|-----------|------|
| PostgreSQL / Redis | 1 instancia c/u | Servicios compartidos, **no HA** (elegido para aligerar). |
| Vault | 3 nodos Raft | **HA real** (tolera 1 caído). Sin TLS: solo lab. |
| JumpServer | 2 nodos + LB | **HA de app**. Un host = mismo dominio de fallo físico. |
| Grabaciones | volumen `media` compartido | Ambos nodos leen/escriben el mismo volumen. |
| TLS | deshabilitado en Vault | Producción exige TLS + auto-unseal. |

Al ser todo un mismo host, esto **simula** la topología HA para aprender y probar la integración; no reemplaza un despliegue real en VMs/nodos separados (ese es el otro plan que armamos).

---

## Problemas comunes

- **Un nodo JumpServer no arranca / errores de migración:** asegurate de haber levantado `jms-node1` solo primero. Si ya pasó, reiniciá: `docker compose restart jms-node2`.
- **`vault-init.sh` dice "ya estaba inicializado":** el volumen de Vault ya tiene estado. Para empezar de cero: `docker compose down -v` (borra todo) y repetí.
- **Vault sellado tras reiniciar:** desellá con `docker exec vaultX vault operator unseal <key>` (2 de 3 llaves).
- **`VAULT_*` no hace nada:** estás usando la imagen Community. La integración requiere EE.
- **La versión `v4.10.17` no existe:** revisá el tag disponible en Docker Hub (`jumpserver/jms_all`) y ajustá `JMS_IMAGE` en `.env`.
