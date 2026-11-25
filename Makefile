# From an empty cluster:
#   cp .env.example .env     and fill it in
#   make db-up migrate roles seed verify test

SHELL := /bin/bash
.DEFAULT_GOAL := help

ifneq (,$(wildcard .env))
include .env
export
endif

MIGRATIONS := db/migrations
PSQL       := psql "$(DATABASE_URL)" -v ON_ERROR_STOP=1
SQLX       := sqlx

.PHONY: help
help: ## list the targets
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	 | awk -F':.*?## ' '{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# Local server

.PHONY: db-up
db-up: ## start the local Postgres and wait for it
	docker compose up -d --wait db

.PHONY: db-down
db-down: ## stop the local Postgres, keeping its data
	docker compose stop db

.PHONY: db-reset
db-reset: ## delete the local database and rebuild it from the migrations, losing its data
	docker compose down -v
	$(MAKE) db-up migrate roles seed

.PHONY: db-destroy
db-destroy: ## stop the local Postgres and delete its data
	docker compose down -v

# Schema

.PHONY: migrate
migrate: ## apply every pending migration
	$(SQLX) migrate run --source $(MIGRATIONS)

.PHONY: revert
revert: ## undo the most recent migration
	$(SQLX) migrate revert --source $(MIGRATIONS)

.PHONY: migrate-info
migrate-info: ## show which migrations are applied
	$(SQLX) migrate info --source $(MIGRATIONS)

.PHONY: new-migration
new-migration: ## create a migration pair: make new-migration name=add_something
	@test -n "$(name)" || { echo "give a name: make new-migration name=add_something"; exit 1; }
	$(SQLX) migrate add -r --source $(MIGRATIONS) $(name)

.PHONY: ddl
ddl: ## regenerate the consolidated DDL from the live schema
	@db/ddl/generate.sh

.PHONY: dictionary
dictionary: ## regenerate the data dictionary from the live schema
	@docs/generate-data-dictionary.sh

# Roles and data

.PHONY: roles
roles: ## create the three login roles from the passwords in .env
	@test -n "$(INGEST_PASSWORD)$(APP_PASSWORD)$(PUBLIC_READ_PASSWORD)" \
	 || { echo "set INGEST_PASSWORD, APP_PASSWORD and PUBLIC_READ_PASSWORD in .env"; exit 1; }
	@$(PSQL) -q \
	  -v ingest_password="$(INGEST_PASSWORD)" \
	  -v app_password="$(APP_PASSWORD)" \
	  -v public_read_password="$(PUBLIC_READ_PASSWORD)" \
	  -f db/roles/create_login_roles.sql

.PHONY: seed
seed: ## load the reference data, the test data and the registry snapshot
	@$(PSQL) -q -f db/seed/reference.sql -f db/seed/test_data.sql \
	         -f db/seed/registry_snapshot.sql
	@echo "loaded"

.PHONY: reference
reference: ## load the reference data alone, which is idempotent
	@$(PSQL) -q -f db/seed/reference.sql

# Checking

.PHONY: test
test: ## run the integrity tests
	@$(PSQL) -q -f db/tests/integrity.sql

.PHONY: verify
verify: ## report data quality findings and audit the privileges
	@echo "== data quality findings (none expected)"
	@$(PSQL) -c "SELECT check_code, severity, subject, detail FROM dephealth.v_data_quality_finding ORDER BY severity, check_code;"
	@echo "== privileges"
	@$(PSQL) -q -f db/checks/privileges.sql

.PHONY: indicators
indicators: ## print the indicator views
	@$(PSQL) -q -f db/queries/05_ecosystem_analytics.sql

.PHONY: tree
tree: ## resolve one manifest: make tree manifest='{tiny-config@0.3.1}'
	@test -n "$(manifest)" || { echo "give a manifest: make tree manifest='{tiny-config@0.3.1}'"; exit 1; }
	@$(PSQL) -v manifest="$(manifest)" -f db/queries/01_resolve_tree.sql

.PHONY: psql
psql: ## open a session as the schema owner
	@$(PSQL)

# API tier

.PHONY: api
api: ## run the API against the local database
	cd api && cargo run

.PHONY: api-test
api-test: ## run the API unit and integration tests
	cd api && cargo test

.PHONY: api-check
api-check: ## lint and format-check the API
	cd api && cargo fmt --check && cargo clippy --all-targets -- -D warnings

.PHONY: api-coverage
api-coverage: ## measure the API test coverage, needs cargo-llvm-cov
	cd api && cargo llvm-cov --summary-only --fail-under-lines 80

.PHONY: api-audit
api-audit: ## check the API dependencies against the advisory database, needs cargo-audit
	cd api && cargo audit

.PHONY: openapi
openapi: ## regenerate the API specification from the handlers
	cd api && cargo run --quiet --bin openapi > ../docs/api/openapi.yaml
	@echo "wrote docs/api/openapi.yaml"

.PHONY: openapi-lint
openapi-lint: ## validate the API specification, needs npx
	npx --yes @redocly/cli@1.34.3 lint docs/api/openapi.yaml

.PHONY: sqlx-prepare
sqlx-prepare: ## refresh the offline query data, so the API builds without a database
	cd api && cargo sqlx prepare -- --all-targets

# Browser application

.PHONY: web-install
web-install: ## install the browser application's dependencies
	cd web && npm install

.PHONY: web
web: ## run the browser application against the local API
	cd web && npm run dev

.PHONY: web-demo
web-demo: ## build and serve the browser application with no API behind it
	cd web && npm run build:demo && npm run preview

.PHONY: web-test
web-test: ## run the browser application's unit tests
	cd web && npm test

.PHONY: web-e2e
web-e2e: ## run the browser application's end to end tests
	cd web && npm run e2e

.PHONY: web-check
web-check: ## lint, format and type-check the browser application
	cd web && npm run lint && npm run format:check && npm run typecheck

.PHONY: fixtures
fixtures: ## recapture the demonstration fixtures from a running API
	cd web && npm run fixtures

.PHONY: screenshots
screenshots: ## capture every screen at every device size
	cd web && npm run screenshots

.PHONY: mockups
mockups: ## render the interface design document to PDF
	cd web && npm run mockups

# Analytical tier

.PHONY: analytics
analytics: ## run the DuckDB pipeline over whatever is in analytics/data/raw
	@analytics/run.sh

.PHONY: analytics-test
analytics-test: ## run the DuckDB pipeline over the committed fixture
	@analytics/run-fixture.sh

.PHONY: analytics-clean
analytics-clean: ## delete the local analytical database and the raw files
	rm -rf analytics/data
