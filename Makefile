# The three stacks of docker-compose.yml; README.md, Development, has the
# details and the URLs.
.PHONY: dev prod test down trace trace-rename i18n

# Everything with live reload, behind http://localhost:56481, detached.
dev:
	docker compose --profile dev up -d --build

# The images the cluster runs, behind http://localhost:56480.
prod:
	docker compose --profile prod up -d --build

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
	$(TRACE) openapi

# make trace-rename FROM=UC-DEAL-02 TO=UC-DEAL-07 renames one ID everywhere;
# make trace-rename FROM_WAS=1 replaces every old ID by its current one.
trace-rename:
	$(if $(FROM_WAS),$(TRACE) rename --from-was,$(TRACE) rename $(FROM) $(TO))

# Checks the products' words: the format cases each repo tests against match
# docs/i18n/format-cases.json, and the UI text follows docs/i18n/glossary.yaml.
i18n:
	docs/i18n/sync.sh --check
	bun docs/i18n/glossary.ts check
