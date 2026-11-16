# The three stacks of docker-compose.yml; README.md, Development, has the
# details and the URLs.
.PHONY: dev prod test down trace trace-rename

# dev and prod take LLM_BASE_URL, LLM_API_KEY, LLM_MODEL, the three
# ASSIST_LLM_ and the three TRUST_LLM_ variables from server/.env. Compose
# uses the file only to fill in ${...} in docker-compose.yml, and those nine
# are the only ones it names.
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

# Checks that server code, tests, OpenAPI and the docs name only IDs from
# docs/registry/requirements.yaml, then writes docs/registry/trace.json for
# the report and the docs site. Errors exit 1; warnings list what is missing.
TRACE := bun docs/scripts/trace/main.ts --server server --docs docs

trace:
	$(TRACE) build

# make trace-rename FROM=UC-DEAL-02 TO=UC-DEAL-07 renames one ID everywhere;
# make trace-rename FROM_WAS=1 replaces every old ID by its current one.
trace-rename:
	$(if $(FROM_WAS),$(TRACE) rename --from-was,$(TRACE) rename $(FROM) $(TO))
