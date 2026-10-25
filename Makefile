# Atajos del lab. Uso: make up | make down | make clean | make logs | make ps | make ha-test
.PHONY: up down clean logs ps ha-test

up:            ## Arranca todo (equivale a ./start.sh)
	@bash ./start.sh

down:          ## Detiene el lab (conserva datos)
	@docker compose down

clean:         ## Borra contenedores Y datos (empieza de cero)
	@bash ./stop.sh --wipe

logs:          ## Sigue los logs de todos los servicios
	@docker compose logs -f

ps:            ## Estado de los contenedores
	@docker compose ps

ha-test:       ## Tira el nodo 1, espera y lo vuelve a levantar
	@echo ">> Deteniendo jms-node1 (probá http://localhost mientras)..."
	@docker compose stop jms-node1
	@sleep 8
	@echo ">> Reactivando jms-node1..."
	@docker compose start jms-node1
	@echo ">> Listo."
