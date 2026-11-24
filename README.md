# dephealth

Forecasts how open-source libraries develop over time and how likely they are
to be left without maintainers.

It joins two sources of behavioural data by repository, the daily download
statistics published by the crates.io registry and the public contributor
activity recorded in GH Archive. From those it estimates how the adoption of a
library will change over the next 3 to 12 months, the probability that a
project loses its active maintainers within a year, and anomalies in download
series.

You upload a dependency file and get the dependency tree ranked by risk, with a
forecast and an explanation for each library.

Diploma project at European Humanities University, 2026/27.

PostgreSQL 19 serves requests, DuckDB derives the features from the raw
sources, an HTTP service in Rust exposes them, and a
[React](https://www.npmjs.com/package/react) client presents them.

## Scope

The ingestion and feature pipeline, the schema, the HTTP service and the client
are implemented. The statistical models are specified in the schema and in
[the data model](docs/data-model.md) but are not yet fitted, so the scores the
service returns are fixture data rather than model output.

## Demonstration

The browser application is published to GitHub Pages from the default branch at
<https://nadzyah.github.io/dephealth/>. It is built from the response fixtures
committed in `web/src/api/fixtures`, so it can be opened and used with no
service behind it, and it says so on the screen. The figures it shows are
captured responses rather than live scores.

## Requirements

Docker alone is enough to run everything. To work on a tier rather than run it:

- PostgreSQL 19 and [sqlx-cli](https://crates.io/crates/sqlx-cli) for the schema
- Rust 1.98 or newer for the API
- Node 24 or newer for the browser application
- [DuckDB](https://duckdb.org) for the analytical tier
- `psql` and GNU make

## Usage

Docker Compose is the default workflow. It starts the database, applies the
migrations, creates the login roles and runs both the service and the client:

```
cp .env.example .env    # then fill it in
docker compose up -d
```

The client is then on <http://localhost:5173> and the service on
<http://localhost:8080>, with its reference at <http://localhost:8080/docs/>.
The migration and role steps are idempotent, so a later `docker compose up` is
a no-op for them. The test data is not, so it is loaded once, from a profile of
its own:

```
docker compose --profile fixture run --rm seed
```

## Development

Compose runs the system. The Makefile covers everything that is not running it:
the test and verification suites, regeneration of the artefacts derived from
the live schema, the analytical pipeline, and schema authoring. CI invokes the
same targets, so a result obtained locally is the result CI reports.

`make` lists every target with its purpose.

## Diagrams

- [Entity relationships](docs/diagrams/er.mmd)
- [Logical schema in blocks](docs/diagrams/schema-blocks.mmd)
- [Data flow](docs/diagrams/data-flow.mmd)
- [API request flow](docs/diagrams/api-request-flow.mmd)

## Documentation

- [Data model](docs/data-model.md), the design decisions. Normal form,
  integrity, transactions, indexes, partitioning, versioning, secrets and
  personal data
- [Data dictionary](docs/data-dictionary.md), every table, column, key,
  constraint, index, routine and grant. Generated from the live schema
- [Analytical tier](docs/analytics.md), the DuckDB pipeline and its layers
- [Back-end](docs/backend.md), the service architecture, layering, error
  handling, logging, security and the testing it rests on
- [API documentation](docs/api/README.md), the generated reference, the guides
  and the runnable examples
- [Front-end](docs/frontend.md), the client architecture, user flows, state
  management and the technology choices
- [Adaptive UI](docs/adaptive-ui.md), breakpoints, the design system, the
  component library and the accessibility verification
- [Interface design](docs/mockups/index.html), the pages, components, states
  and device variants, rendered to PDF by `make mockups`
- [Browser application](web/README.md), configuration, commands and layout
- [Roles](db/roles/README.md), the group roles and which component reads what

## Layout

- `db/migrations` the schema, in order. `db/ddl/schema.sql` is the same in one
  file, generated
- `db/queries` the queries behind each screen
- `db/seed` reference data and test data
- `db/tests` and `db/checks` integrity tests and the privilege audit
- `db/load` the load from the analytical tier
- `analytics` the DuckDB pipeline
- `api` the HTTP service
- `web` the browser application
- `docs` the documentation, including the generated API reference

## Licence

MIT, see [LICENSE](LICENSE).
