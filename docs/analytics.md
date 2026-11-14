# Analytical Tier

DuckDB, four layers, one pass per day. It reads the two public sources,
aggregates them to the package, and hands CSV to Postgres. SQL in
`analytics/sql`, driven by `analytics/run.sh`.

Data flow diagram: `docs/diagrams/data-flow.mmd`.

## Layer Architecture

| Layer | File | What it does |
|---|---|---|
| raw | `01_raw.sql` | views over the downloaded files. Nothing is cast or copied, so a defect can be traced back to the file it came from |
| staging | `02_staging.sql` | typed, deduplicated, filtered. Resolves each package to a repository and records why when it fails. Its two event tables are the only place holding account logins |
| mart | `03_mart.sql` | star schema. Two facts, `fct_download_daily` and `fct_activity_daily`, with `dim_package`, `dim_repository` and `dim_date` |
| feature | `04_features.sql` | trailing windows of 30, 90, 180 and 365 days, which is what the models are fitted on. Drops the two event tables at the end |

Reading the files in place rather than copying them keeps the whole tier inside
a free tier. The dumps are never stored twice.

## Dimensional Model

The two facts are the two sides of the research question. Downloads are what
consumers do, events are what producers do, and the whole project rests on
joining them by package. They share `dim_package` and `dim_date`.

`dim_package` is slowly changing, type 2. A package whose declared repository
changes gets a new row and the previous one is closed with `valid_to` and
`is_current`, so a score computed last year can still be read against the
repository it was computed from. Every reader filters on `is_current`, and a
quality check fails the run if a package ever ends up with two current rows.

## Load Strategy

The facts are a full load. crates.io publishes the whole database daily and the
previous copy is deleted, so there is nothing to increment against.

`dim_package` is the exception and is merged rather than replaced, because a
type 2 dimension is only useful if it survives the run that created it. It is
the one table in this tier that carries state between runs.

The event archive is incremental. GH Archive publishes one file per hour.
`run.sh` downloads a bounded window, 30 days by default, and skips files already
on disk. The window is bounded because the full history does not fit a free
tier. That is constraint C1 in the requirements, not an oversight.

The load into Postgres is an upsert on the natural key, so re-running a batch
writes the same rows rather than duplicates.

## Data Quality Controls

`05_quality.sql` defines `main.quality_finding`. Ten checks covering duplicate
package names, two current rows for one package, duplicate download days,
negative downloads, nulls in key columns, future dated days, contributors
exceeding events, shares out of range, shares disagreeing with event counts,
and a resolution rate below the KPI1 target.

`run.sh` counts the errors before exporting. If there are any it prints them,
marks both runs failed and loads nothing, so submissions continue to be served
from the previous results with their age shown.

## Treatment of Account Identifiers

The event files name the account behind each event. Logins enter
`staging.event` and `staging.tracked_event`, are counted, and go no further.
`04_features.sql` drops both tables. `run.sh` then deletes the raw files and
records the number of bytes deleted against the ingestion run.

Bot accounts are filtered out in staging. A release bot pushing daily would
otherwise make an abandoned package look maintained.

## Execution

```
make analytics-test     # the committed fixture, downloads nothing
make analytics          # the real sources
```

Needs `duckdb`, `curl`, `tar` and `psql`. Install DuckDB from
https://duckdb.org or with `cargo install duckdb-cli`.

On failure both runs are marked failed and the serving database is untouched.

## Test Fixture

`analytics/testdata` holds a small set of source files in the published shape
of each source, so the pipeline can be run and the result inspected without
downloading 30 days of event archives. `make analytics-test` copies it into
place, runs all six layers, loads the result and closes both runs.

It is built to exercise every branch rather than to look realistic. Five
crates covering all four resolution outcomes, including a repository on GitLab
and a malformed URL. Seventy days of per version downloads for two of them, so
the trailing windows have something to aggregate. One package with five
contributors across two hourly event files and one that is silent. A
`dependabot[bot]` and a `release-bot` event, so the bot filter has something to
drop. One event repeated in a third file, so the deduplication is exercised.
One dependency edge of each kind, including a development edge that a consumer
tree must exclude.

## Verification Status

The pipeline has been run end to end against the fixture, and its output loaded
into Postgres and served. It has not been run against the real dumps. The
column names are taken from the published schemas, so the first real run may
still need adjustment there.
