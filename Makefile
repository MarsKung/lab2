SHELL := /bin/bash
COMPOSE := docker compose

.DEFAULT_GOAL := help

.PHONY: help
help: ## show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## create .env from template
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "[setup] created .env — edit NVIDIA_API_KEY before running 'make up'"; \
	else \
		echo "[setup] .env already exists"; \
	fi

.PHONY: up
up: setup ## build and start Lab 2
	$(COMPOSE) down --remove-orphans 2>/dev/null || true
	$(COMPOSE) up -d --build --force-recreate
	@echo
	@echo "=== Lab 2 started ==="
	@echo "Player key:  ./keys/player_key"
	@echo "SFTP:        sftp -i ./keys/player_key -P 2250 clawuser@localhost"
	@echo

.PHONY: logs
logs: ## follow container logs
	$(COMPOSE) logs -f --tail=80

.PHONY: key
key: ## copy player key to current directory with correct permissions
	@cp ./keys/player_key ./player_key 2>/dev/null && chmod 600 ./player_key \
		&& echo "player_key written (600)" \
		|| echo "keys/player_key not found — run 'make up' first"

.PHONY: shell
shell: ## drop into the attacker toolbox
	$(COMPOSE) exec attacker bash

.PHONY: down
down: ## stop containers, keep volumes
	$(COMPOSE) down

.PHONY: clean
clean: ## stop and wipe everything
	$(COMPOSE) down -v --remove-orphans
	rm -rf keys/
	@echo "[clean] done; .env left in place"

.PHONY: reset-skills
reset-skills: ## restore skills to pristine state (undo player's malicious upload)
	$(COMPOSE) exec copyfail-target bash -c 'cp -a /opt/skills.pristine/* /srv/openclaw/skills/'
	@echo "[reset] skills restored"
