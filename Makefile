# EterDB task runner. This is a Go + C + SQL project (no JavaScript), so the
# tasks live in a Makefile, not an npm package.json.
#
#   make            # list targets
#   docker compose up -d && make demo
PREFIX ?= /usr/local

.DEFAULT_GOAL := help
.PHONY: help build install demo capture storage orchestrator sidecars-build \
        docker-check dev-db stack-up stack-down test-e2e site-preview

help: ## list the available targets
	@grep -hE '^[a-z][a-zA-Z0-9-]*:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## build the eter CLI to cli/eter
	cd cli && go build -o eter .

install: build ## build + install eter to PREFIX/bin (default /usr/local, may need sudo)
	install -d "$(PREFIX)/bin"
	install -m 0755 cli/eter "$(PREFIX)/bin/eter"

demo: stack-up ## up the stack, run the walkthrough, then tear it all down (down -v)
	( cd cli && go run . demo ); s=$$?; docker compose down -v; exit $$s

capture: ## run the capture sidecar
	go run -C sidecars ./capture

storage: ## run the storage sidecar
	go run -C sidecars ./storage

orchestrator: ## run the orchestrator (single /v1 entry point on :4400)
	go run -C sidecars ./orchestrator

sidecars-build: ## build the sidecar binaries
	bash sidecars/build.sh

dev-db: ## start just Postgres (no control plane)
	docker compose up -d postgres

docker-check: ## verify the Docker daemon is reachable (clear error if not)
	@docker info >/dev/null 2>&1 || { \
	  echo "Docker does not appear to be running."; \
	  echo "Start Docker Desktop (or your docker daemon), then re-run 'make demo'."; \
	  exit 1; }

stack-up: docker-check ## bring up the two-container stack (pulls prebuilt images), wait until healthy
	docker compose up -d --wait

stack-down: ## tear the stack down, removing volumes
	docker compose down -v

test-e2e: ## run the end-to-end suite
	bash test/e2e.sh

site-preview: ## serve the marketing site on :8080
	cd site && python3 -m http.server 8080
