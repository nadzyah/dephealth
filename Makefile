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
seed: ## load the reference data and the test data
	@$(PSQL) -q -f db/seed/reference.sql -f db/seed/test_data.sql
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
