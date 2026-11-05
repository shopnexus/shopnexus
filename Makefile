# The three stacks of docker-compose.yml; README.md, Development, has the
# details and the URLs.
.PHONY: dev prod test down

# Everything with live reload, behind http://localhost:56481. Stays in the
# foreground and prints the logs.
dev:
	docker compose --profile dev up --build --watch

# The images the cluster runs, behind http://localhost:56480.
prod:
	docker compose --profile prod up -d --build

# The server's Go tests, on tmpfs.
test:
	docker compose --profile test run --rm --build tests

# Stops every stack and keeps its data; down -v by hand deletes it.
down:
	docker compose --profile dev --profile prod --profile test down
