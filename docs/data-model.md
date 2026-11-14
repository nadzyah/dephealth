# Data Model

Design notes for the serving database. The full list of tables, columns, keys,
constraints, indexes and grants is in [data-dictionary.md](data-dictionary.md),
generated from the live schema. The analytical tier is in
[analytics.md](analytics.md).

Diagrams (Mermaid sources in `docs/diagrams`):

- `er.mmd` entity relationship diagram with keys
- `schema-blocks.mmd` logical schema, five colour coded blocks
- `data-flow.mmd` where data comes from, how it is processed, where it goes

## Choice of Database Engines

PostgreSQL 17 serves requests. DuckDB derives the features.

Serving a submission means resolving a few hundred lockfile entries, reading
one row per package and ranking them. It is small, indexed and latency bound,
with a target of under 10 seconds at the 95th percentile for 500 entries. That
is a row store workload.

Deriving the features means scanning the registry dump and a window of the
GitHub event archive, hundreds of millions of rows, and aggregating them to a
few hundred thousand. It runs once a day and nobody waits for it. That is a
column store workload.

DuckDB is embedded, so the analytical tier costs nothing to host. This matters
because the project has to fit a free tier. ClickHouse would handle a longer
window and concurrent analytical users, but it is a server to pay for and the
project needs neither.

The two tiers never meet at request time. DuckDB writes CSV and a transaction
in Postgres loads it.

## Normalisation

The schema is in 3NF with two exceptions.

**Stored reports are snapshots.** `report_entry` repeats the package name,
version, risk and forecast that also live in `package`, `maintenance_risk` and
`adoption_forecast`. The score tables are overwritten by every ingestion run,
and UC2 requires a filed report to return the figures it held when it was
generated. A report that joined to the live tables would rewrite its own
history. So the entry stores values. `package_id` stays as a nullable
reference with `ON DELETE SET NULL`, because an unresolved entry has no package
to point at.

Three things keep the copies trustworthy. The table is append only, by trigger
and by grant. The header counts are checked against the lines at commit. The
report records which models and which abandonment definition were in force.

**One JSON column.** `model.hyperparameters` is `jsonb`. The keys differ per
model family, the value is written once and read only for the record, and
nothing joins or filters on it. A name and value table here would be an EAV
store, which is worse. The column has a check that the value is an object, and
the keys each family uses are listed in the data dictionary.

Everything else that could have been JSON is a table. `model_metric`,
`risk_factor` and `report_entry_factor` are read as rows and joined to
reference tables for their labels.

## Integrity Constraints

Four mechanisms, in order of preference.

**Check constraints** for anything that fits in one row. The ones that encode a
requirement rather than a type:

- `package_resolution_coherent` a package has a repository, a method and a date,
  or it has none of them and carries a reason. KPI1 is the share that resolves,
  so the column cannot be half set.
- `forecast_history_rule` `insufficient_history` is defined as
  `history_days < 365`, not set by the caller. This is the twelve month rule
  from UC1.
- `report_entry_resolution_coherent` an entry carries a score or carries the
  reason it has none. A missing score must not read as a good one.
- `activity_feature_share_at_least_even` with n contributors the most active one
  cannot hold less than a 1/n share.

**Foreign keys** on every reference, with delete behaviour chosen per
relationship. `CASCADE` where the child is part of the parent, `RESTRICT` on
the report tables so nothing removes a filed record by cascade, `SET NULL` from
`package` to `repository`.

**Triggers** for rules that span rows.

| Trigger | What it enforces |
|---|---|
| `report_entry_is_append_only` | no update or delete on a report line |
| `report_entry_factor_is_append_only` | the same for the stored factors |
| `report_is_immutable_apart_from_withdrawal` | only the two withdrawal columns may change, a report cannot be deleted, a withdrawal cannot be reversed |
| `report_counts_match_entries` | deferred, checks the header counts against the lines at commit |
| `activity_feature_syncs_repository` | keeps `repository.last_event_on` in step with the features |

**Quality checks** for what a constraint cannot express. Ten of them in
`v_data_quality_finding`, covering gaps in a series, future dated days, self
dependencies, scores on unresolved packages, serving models with no metric, and
runs that succeeded having loaded nothing. `make verify` prints them. An empty
result is the expected state.

## Transaction Boundaries

**A load is one transaction.** `db/load/load_features.sql` fills three temp
tables from CSV, upserts four tables and commits. A half loaded batch would be
served as complete, and the reported data age would cover rows that are not
there. Every statement is an upsert on the natural key, so a retry writes the
same rows rather than duplicates.

**A report is one transaction.** Header, lines and factors are written
together, and the deferred trigger checks them at commit.

**A run is two.** `start_ingestion_run` takes an advisory lock on the source,
so a second scheduler waits instead of failing. `finish_ingestion_run` records
the outcome, then refreshes the materialised view inside its own exception
block. A failed refresh leaves stale data being served, which NFR3 allows. A
lost run record would make the data age unanswerable, which it does not.

`finish_ingestion_run` is `SECURITY DEFINER` with a fixed `search_path`.
Refreshing a materialised view needs ownership, and the ingestion role does not
own it. Every identifier in the procedure is schema qualified.

## Indexing

| Index | Reason |
|---|---|
| `package_identity`, `repository_identity` | unique under case folding. GitHub and crates.io both treat names case insensitively, so without folding the same subject enters twice |
| `ingestion_run_one_in_flight_per_source` | partial unique, one run per source at a time |
| `model_one_current_per_kind`, `model_one_baseline_per_kind` | partial unique, one serving model and one baseline per kind |
| `ingestion_run_latest_success` | partial, successful runs only. Read on every request for the data age |
| `package_unresolved` | partial, over the minority of rows it serves |
| `activity_feature_dormant` | partial, `days_since_last_event >= 180`. The survival model is fitted on these rows |
| `maintenance_risk_ranking` | carries the sort order of the ranked tree |
| `adoption_forecast_serving`, `maintenance_risk_serving` | newest row of the current model for one package |
| `report_by_fingerprint` | partial, finds the previous assessment of the same manifest for US11 |
| `mv_package_current_assessment_package_id` | unique, required by `REFRESH MATERIALIZED VIEW CONCURRENTLY` |

Partial indexes are used wherever the query is partial.

## Partitioning

`download_daily` is range partitioned by day into yearly partitions, 2014 to
2027, plus a default partition. It is the largest table read online, a detail
view reads one window of one package, and it is written one day at a time so
only the newest partition stays warm. Retention becomes a partition drop.

The default partition is a quarantine. A day outside the declared range is a
defect in the dump, so it lands there and is reported by the quality checks
instead of failing the run.

## Views and Materialisation

`mv_package_current_assessment` is a materialised view holding one row per
package with the figures of the current models. Per request this would be three
correlated lookups of the newest row per package. Materialised it is one indexed
read. It refreshes at the end of a run, concurrently, so submissions are served
throughout.

`v_package_assessment` and `v_download_series` are the privilege boundary, see
below. `v_data_age`, `v_report` and `v_report_entry` carry queries several
callers need.

`v_kpi1_resolution`, `v_kpi1_resolution_by_reason` and
`v_model_against_baseline` make the project indicators answerable by query. The
baselines for KPI3 and KPI4 are rows in `model`, so both sides of the
comparison come from the same metric table.

## Schema Versioning

Eight reversible migrations in `db/migrations`, plain SQL, applied with
`sqlx migrate run` and undone with `sqlx migrate revert`. sqlx stores the
applied version and a checksum per file, so editing an applied migration is
refused. `make migrate-info` shows the state of a database.

A change is always a new migration, never an edit to an old one. The reverse
path is tested, not assumed. The full set applies and reverts against an empty
database leaving no object and no role behind.

`db/ddl/schema.sql` is the same structure in one file, generated by `make ddl`.
It is not the source of truth.

## Roles and Privileges

Four group roles, three login roles, no superuser. Details in
[`db/roles/README.md`](../db/roles/README.md), live grants in the data
dictionary.

The boundary worth noting is `activity_feature`, which holds the contributor
counts. The application and the public API have no privilege on it, nor on the
materialised view under the published views. They read it only through
`v_package_assessment` and `v_report_entry`. A view runs with its owner's
privileges, so the restriction does not depend on the application behaving. The
integrity tests check it.

`dephealth_public_read` holds `SELECT` on five views and nothing else, which is
how NFR6 is enforced rather than promised. The application can update two
columns of one table, through a column level grant on `report.withdrawn_at` and
`report.withdrawal_reason`.

## Credentials and Encryption

The system has no accounts, so it stores no user passwords. That follows from
NFR5 and removes the largest class of credential risk.

It does store the SHA-256 digest of each report link token. The token is 256
bits of randomness, so a fast digest is the right choice and a password digest
is not. Storing the digest means a database dump does not yield working links.

`report.manifest_fingerprint` is a salted digest of the sorted name@version
set. It lets US11 recognise a resubmission without keeping the manifest, which
NFR5 forbids. The salt lives in the application, not the database.

Login passwords use SCRAM-SHA-256. `password_encryption` is fixed to that in
the compose file, and `create_login_roles.sql` refuses to run otherwise.
`db/checks/privileges.sql` reports md5 digests, superuser logins and relations
no role can reach.

No password, token or salt is in the repository. `.env` is gitignored and
`.env.example` has empty values. Transport is `sslmode=verify-full` in
deployment. Encryption at rest is the managed provider's volume encryption.

## Processing of Personal Data

GitHub events identify the account behind each one, so the raw data is personal
data. The derived data is not.

An account login exists only in `staging.event` and `staging.tracked_event` in
DuckDB. The mart holds counts and shares per package per day.
`04_features.sql` drops both event tables once the counts are derived, and
`run.sh` deletes the raw files, recording the bytes deleted against the run.
There is no per contributor table or column anywhere.

Aggregation alone is not enough for small groups. Two contributors over 30 days
on a repository with two known maintainers still describes two people. The
published views withhold a count below `k_anonymity_threshold()`, which is 5,
and withhold the concentration share with it, since a share of 1.000 beside a
withheld count would reveal that the count is one.

Zero is published. A count of zero describes nobody, and hiding it would
conceal the clearest signal the system has.

The threshold is a function created by a migration, so the value in force on
any date is in the schema history. The model keeps using the raw counts.
Suppressing them in the feature table would blind it to the packages the
service exists to flag. Its output is a probability about a package, never a
statement about a person.

## Scope of This Stage

- The Rust application. This stage is the data tier.
- Fitted models. The model tables are the schema their output lands in. The
  rows in the test data are shaped like real output but are not.
- A full run of the analytical tier over the real dumps. The DuckDB SQL is
  written against the published source schemas and the load into Postgres has
  been exercised with exported files, but the whole pipeline has not been run.
