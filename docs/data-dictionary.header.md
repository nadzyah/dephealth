# Data Dictionary

Every relation, column, key, constraint, index, routine and grant in the
`dephealth` schema. Generated from a live database by
`docs/generate-data-dictionary.sh`, so it cannot drift from the schema.
Descriptions come from the `COMMENT` statements in the migrations, which means
`\d+` in psql shows the same text.

The analytical layers are described in [analytics.md](analytics.md). The
reasoning behind the design is in [data-model.md](data-model.md).

## Layers

| Layer | Where | Holds | Lifetime |
|---|---|---|---|
| raw | files on disk, read in place by DuckDB | the registry dump and hourly event archives as downloaded | deleted at the end of each run |
| staging | DuckDB | typed, deduplicated source data. Its two event tables are the only place with account logins in them | the event tables are dropped at the end of each run |
| mart, feature | DuckDB | two daily facts and the trailing window aggregates, already per package | kept between runs as a local file |
| serving | PostgreSQL, this schema | reference data, packages, edges, series, features, model output, stored reports | durable |

## Grain

| Relation | One row is |
|---|---|
| `ingestion_run` | one pass of one source |
| `repository` | one source repository |
| `package` | one package in the registry |
| `package_version` | one published version |
| `package_dependency` | one dependency edge of one kind |
| `download_daily` | one package on one day |
| `activity_feature` | one package over one window, as of one day |
| `model` | one fitted model, baselines included |
| `model_metric` | one metric of one model |
| `adoption_forecast` | one package, model, horizon and date |
| `maintenance_risk` | one package, model, horizon and date |
| `risk_factor` | one factor of one risk score |
| `report` | one generated assessment |
| `report_entry` | one line of one report |
| `report_entry_factor` | one factor of one line |

## Data Quality Expectations

Each table's `CHECK` constraints are listed with it below, and they are the per
column expectations. A probability lies in the unit interval, a count is not
negative, a window is one of four values, a resolved package has a repository,
a forecast needs twelve months of history behind it.

Three kinds of expectation cannot be a constraint.

1. Those spanning tables, such as a report header agreeing with its lines.
   These are deferred constraint triggers, fired at commit.
2. Those describing a suspicion rather than a violation, such as a gap in a
   series or a run that succeeded having loaded nothing. These are rows of
   `v_data_quality_finding`, which `make verify` prints.
3. Those belonging to the analytical tier, such as duplicate control on the
   event id. These are in `analytics/sql/05_quality.sql`, and an error there
   stops the run before Postgres is touched.

## Relations
