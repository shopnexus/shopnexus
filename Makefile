# The three stacks of docker-compose.yml; README.md, Development, has the
# details and the URLs.
.PHONY: dev prod test down

# dev and prod take LLM_BASE_URL, LLM_API_KEY, LLM_MODEL and the three
# ASSIST_LLM_ variables from server/.env. Compose uses the file only to fill
# in ${...} in docker-compose.yml, and those six are the only ones it names.
COMPOSE_LLM := docker compose --env-file server/.env

# Everything with live reload, behind http://localhost:56481. Stays in the
# foreground and prints the logs.
dev:
	$(COMPOSE_LLM) --profile dev up --build --watch

# The images the cluster runs, behind http://localhost:56480.
prod:
	$(COMPOSE_LLM) --profile prod up -d --build

# The server's Go tests, on tmpfs.
test:
	docker compose --profile test run --rm --build tests

# Stops every stack and keeps its data; down -v by hand deletes it.
down:
	docker compose --profile dev --profile prod --profile test down
