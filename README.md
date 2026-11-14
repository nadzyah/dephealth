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

This repository holds the database tier. PostgreSQL 17 serves requests and
DuckDB derives the features from the raw sources. The application comes in a
later stage.

## Requirements

- PostgreSQL 17, or Docker to run the bundled one
- [sqlx-cli](https://crates.io/crates/sqlx-cli) to apply the migrations
- `psql` and GNU make
- [DuckDB](https://duckdb.org) for the analytical tier only

## Usage

```
cp .env.example .env        # then fill it in
make db-up migrate roles seed
make test verify
```

`make` on its own lists the targets.

## Diagrams

- [Entity relationships](docs/diagrams/er.mmd)
- [Logical schema in blocks](docs/diagrams/schema-blocks.mmd)
- [Data flow](docs/diagrams/data-flow.mmd)

## Documentation

- [Data model](docs/data-model.md), the design decisions. Normal form,
  integrity, transactions, indexes, partitioning, versioning, secrets and
  personal data
- [Data dictionary](docs/data-dictionary.md), every table, column, key,
  constraint, index, routine and grant. Generated from the live schema
- [Analytical tier](docs/analytics.md), the DuckDB pipeline and its four layers
- [Roles](db/roles/README.md), the four roles and which component reads what

## Layout

- `db/migrations` the schema, in order. `db/ddl/schema.sql` is the same in one
  file, generated
- `db/queries` the queries behind each screen
- `db/seed` reference data and test data
- `db/tests` and `db/checks` integrity tests and the privilege audit
- `db/load` the load from the analytical tier
- `analytics` the DuckDB pipeline

## Licence

MIT, see [LICENSE](LICENSE).
