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


### activity_feature

Contributor activity aggregated to the package over a trailing window. The data protection boundary of the system. The raw events identify accounts, these rows hold counts, and the raw files are deleted once a run has produced them.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `package_id` | bigint | no |  |  |
| `as_of` | date | no |  |  |
| `window_days` | integer | no |  |  |
| `distinct_contributors` | integer | no |  | Accounts that produced at least one event in the window. Published through the read-only views only at or above dephealth.k_anonymity_threshold(). |
| `event_count` | integer | no |  |  |
| `commit_event_count` | integer | no |  |  |
| `issue_event_count` | integer | no |  |  |
| `review_event_count` | integer | no |  |  |
| `days_since_last_event` | integer | yes |  | Days between as_of and the most recent development event. The abandonment label derives from this column at 180 days. |
| `top_contributor_share` | numeric(4,3) | yes |  |  |
| `run_id` | bigint | no |  |  |

**Keys and constraints**

- `activity_feature_commit_event_count_check`: CHECK ((commit_event_count >= 0))
- `activity_feature_contributors_within_events`: CHECK ((distinct_contributors <= event_count))
- `activity_feature_days_since_last_event_check`: CHECK ((days_since_last_event >= 0))
- `activity_feature_distinct_contributors_check`: CHECK ((distinct_contributors >= 0))
- `activity_feature_event_count_check`: CHECK ((event_count >= 0))
- `activity_feature_events_need_a_contributor`: CHECK (((event_count = 0) = (distinct_contributors = 0)))
- `activity_feature_issue_event_count_check`: CHECK ((issue_event_count >= 0))
- `activity_feature_parts_within_total`: CHECK ((((commit_event_count + issue_event_count) + review_event_count) <= event_count))
- `activity_feature_review_event_count_check`: CHECK ((review_event_count >= 0))
- `activity_feature_share_at_least_even`: CHECK (((top_contributor_share IS NULL) OR (top_contributor_share >= ((1.0 / (distinct_contributors)::numeric) - 0.001))))
- `activity_feature_share_with_events`: CHECK (((event_count = 0) = (top_contributor_share IS NULL)))
- `activity_feature_top_contributor_share_check`: CHECK (((top_contributor_share > (0)::numeric) AND (top_contributor_share <= (1)::numeric)))
- `activity_feature_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `activity_feature_run_id_fkey`: FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id)
- `activity_feature_window_days_fkey`: FOREIGN KEY (window_days) REFERENCES dephealth.feature_window(days)
- `activity_feature_pkey`: PRIMARY KEY (package_id, as_of, window_days)

**Indexes**

- CREATE INDEX activity_feature_dormant ON dephealth.activity_feature USING btree (package_id, as_of DESC) WHERE (days_since_last_event >= 180)
- CREATE INDEX activity_feature_recent ON dephealth.activity_feature USING btree (as_of DESC, window_days)


### adoption_forecast

Forecast adoption per package and horizon, computed offline. A row with insufficient_history set records that no forecast was produced, which differs from a forecast being absent.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `package_id` | bigint | no |  |  |
| `model_id` | bigint | no |  |  |
| `run_id` | bigint | no |  |  |
| `as_of` | date | no |  |  |
| `horizon_months` | integer | no |  |  |
| `point_downloads` | numeric(14,2) | yes |  |  |
| `lower_downloads` | numeric(14,2) | yes |  |  |
| `upper_downloads` | numeric(14,2) | yes |  |  |
| `history_days` | integer | no |  |  |
| `insufficient_history` | boolean | no |  |  |

**Keys and constraints**

- `adoption_forecast_history_days_check`: CHECK ((history_days >= 0))
- `adoption_forecast_lower_downloads_check`: CHECK ((lower_downloads >= (0)::numeric))
- `adoption_forecast_point_downloads_check`: CHECK ((point_downloads >= (0)::numeric))
- `adoption_forecast_upper_downloads_check`: CHECK ((upper_downloads >= (0)::numeric))
- `forecast_absent_when_history_insufficient`: CHECK (((insufficient_history AND (point_downloads IS NULL) AND (lower_downloads IS NULL) AND (upper_downloads IS NULL)) OR ((NOT insufficient_history) AND (point_downloads IS NOT NULL))))
- `forecast_history_rule`: CHECK ((insufficient_history = (history_days < 365)))
- `forecast_horizon_in_range`: CHECK (((horizon_months >= 3) AND (horizon_months <= 12)))
- `forecast_interval_ordered`: CHECK (((lower_downloads IS NULL) OR (upper_downloads IS NULL) OR ((lower_downloads <= point_downloads) AND (point_downloads <= upper_downloads))))
- `adoption_forecast_model_id_fkey`: FOREIGN KEY (model_id) REFERENCES dephealth.model(id)
- `adoption_forecast_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `adoption_forecast_run_id_fkey`: FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id)
- `adoption_forecast_pkey`: PRIMARY KEY (id)
- `adoption_forecast_package_id_model_id_as_of_horizon_months_key`: UNIQUE (package_id, model_id, as_of, horizon_months)

**Indexes**

- CREATE UNIQUE INDEX adoption_forecast_package_id_model_id_as_of_horizon_months_key ON dephealth.adoption_forecast USING btree (package_id, model_id, as_of, horizon_months)
- CREATE INDEX adoption_forecast_serving ON dephealth.adoption_forecast USING btree (package_id, model_id, as_of DESC)


### download_daily (partitioned table)

Downloads per package per day. The registry publishes the figure per version, and the versions are summed on load, since every requirement is stated at the level of the package.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `package_id` | bigint | no |  |  |
| `day` | date | no |  |  |
| `downloads` | bigint | no |  |  |
| `run_id` | bigint | no |  |  |

**Keys and constraints**

- `download_daily_downloads_check`: CHECK ((downloads >= 0))
- `download_daily_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `download_daily_run_id_fkey`: FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id)
- `download_daily_pkey`: PRIMARY KEY (package_id, day)

**Indexes**




### feature_window

Reference table of the trailing windows contributor activity is aggregated over. Adding one changes what the model is trained on, so it takes a migration.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `days` | integer | no |  |  |
| `label` | text | no |  |  |

**Keys and constraints**

- `feature_window_label_present`: CHECK ((length(btrim(label)) > 0))
- `feature_window_positive`: CHECK ((days > 0))
- `feature_window_pkey`: PRIMARY KEY (days)

**Indexes**




### ingestion_run

One pass over one source. Every derived row names the run that produced it, so the age of a served figure is answerable and a bad run is reversible.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `source` | dephealth.data_source | no |  |  |
| `status` | dephealth.run_status | no | `'running'::dephealth.run_status` |  |
| `started_at` | timestamp with time zone | no | `now()` |  |
| `finished_at` | timestamp with time zone | yes |  |  |
| `data_as_of` | date | yes |  |  |
| `window_start` | date | yes |  |  |
| `window_end` | date | yes |  |  |
| `rows_ingested` | bigint | no | `0` |  |
| `rows_rejected` | bigint | no | `0` |  |
| `raw_bytes_discarded` | bigint | yes |  |  |
| `failure_detail` | text | yes |  |  |

**Keys and constraints**

- `ingestion_run_failure_detail_with_failure`: CHECK (((status = 'failed'::dephealth.run_status) = (failure_detail IS NOT NULL)))
- `ingestion_run_finished_after_start`: CHECK (((finished_at IS NULL) OR (finished_at >= started_at)))
- `ingestion_run_finished_with_status`: CHECK (((status = 'running'::dephealth.run_status) = (finished_at IS NULL)))
- `ingestion_run_raw_bytes_discarded_check`: CHECK ((raw_bytes_discarded >= 0))
- `ingestion_run_rows_ingested_check`: CHECK ((rows_ingested >= 0))
- `ingestion_run_rows_rejected_check`: CHECK ((rows_rejected >= 0))
- `ingestion_run_success_has_as_of`: CHECK (((status <> 'succeeded'::dephealth.run_status) OR (data_as_of IS NOT NULL)))
- `ingestion_run_window_ordered`: CHECK (((window_start IS NULL) OR (window_end IS NULL) OR (window_start <= window_end)))
- `ingestion_run_pkey`: PRIMARY KEY (id)

**Indexes**

- CREATE INDEX ingestion_run_latest_success ON dephealth.ingestion_run USING btree (source, data_as_of DESC) WHERE (status = 'succeeded'::dephealth.run_status)
- CREATE UNIQUE INDEX ingestion_run_one_in_flight_per_source ON dephealth.ingestion_run USING btree (source) WHERE (status = 'running'::dephealth.run_status)


### maintenance_risk

Probability that a package loses its active maintainers within the horizon, computed offline. numeric rather than float, since the figure is quoted in a stored report and has to round identically on every read.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `package_id` | bigint | no |  |  |
| `model_id` | bigint | no |  |  |
| `run_id` | bigint | no |  |  |
| `as_of` | date | no |  |  |
| `horizon_days` | integer | no |  |  |
| `probability` | numeric(5,4) | no |  |  |
| `abandonment_window_days` | integer | no | `180` |  |

**Keys and constraints**

- `maintenance_risk_abandonment_window_days_check`: CHECK ((abandonment_window_days > 0))
- `maintenance_risk_horizon_days_check`: CHECK ((horizon_days > 0))
- `maintenance_risk_probability_check`: CHECK (((probability >= (0)::numeric) AND (probability <= (1)::numeric)))
- `maintenance_risk_model_id_fkey`: FOREIGN KEY (model_id) REFERENCES dephealth.model(id)
- `maintenance_risk_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `maintenance_risk_run_id_fkey`: FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id)
- `maintenance_risk_pkey`: PRIMARY KEY (id)
- `maintenance_risk_package_id_model_id_as_of_horizon_days_key`: UNIQUE (package_id, model_id, as_of, horizon_days)

**Indexes**

- CREATE UNIQUE INDEX maintenance_risk_package_id_model_id_as_of_horizon_days_key ON dephealth.maintenance_risk USING btree (package_id, model_id, as_of, horizon_days)
- CREATE INDEX maintenance_risk_ranking ON dephealth.maintenance_risk USING btree (as_of DESC, probability DESC)
- CREATE INDEX maintenance_risk_serving ON dephealth.maintenance_risk USING btree (package_id, model_id, as_of DESC)


### metric_definition

Reference table of evaluation metrics. The kpi column links a measured number to the indicator it reports against.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `code` | text | no |  |  |
| `label` | text | no |  |  |
| `unit` | text | no |  |  |
| `lower_is_better` | boolean | no |  |  |
| `kpi` | text | yes |  |  |

**Keys and constraints**

- `metric_definition_code_wellformed`: CHECK ((code ~ '^[a-z][a-z0-9_]{2,31}$'::text))
- `metric_definition_kpi_wellformed`: CHECK (((kpi IS NULL) OR (kpi ~ '^KPI[1-9]$'::text)))
- `metric_definition_label_present`: CHECK ((length(btrim(label)) > 0))
- `metric_definition_pkey`: PRIMARY KEY (code)

**Indexes**




### model

One fitted model. A baseline is a model row rather than a constant, so one metric table measures both sides of the comparison.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `kind` | dephealth.model_kind | no |  |  |
| `name` | text | no |  |  |
| `version` | text | no |  |  |
| `is_baseline` | boolean | no | `false` |  |
| `is_current` | boolean | no | `false` |  |
| `trained_at` | timestamp with time zone | no |  |  |
| `train_window_start` | date | no |  |  |
| `train_window_end` | date | no |  |  |
| `hyperparameters` | jsonb | no | `'{}'::jsonb` |  |

**Keys and constraints**

- `model_baseline_never_current`: CHECK ((NOT (is_baseline AND is_current)))
- `model_hyperparameters_is_object`: CHECK ((jsonb_typeof(hyperparameters) = 'object'::text))
- `model_name_present`: CHECK ((length(btrim(name)) > 0))
- `model_train_window_ordered`: CHECK ((train_window_start < train_window_end))
- `model_version_present`: CHECK ((length(btrim(version)) > 0))
- `model_pkey`: PRIMARY KEY (id)
- `model_kind_name_version_key`: UNIQUE (kind, name, version)

**Indexes**

- CREATE UNIQUE INDEX model_kind_name_version_key ON dephealth.model USING btree (kind, name, version)
- CREATE UNIQUE INDEX model_one_baseline_per_kind ON dephealth.model USING btree (kind) WHERE is_baseline
- CREATE UNIQUE INDEX model_one_current_per_kind ON dephealth.model USING btree (kind) WHERE is_current


### model_metric

Held-out metrics per model. KPI3 and KPI4 compare the current model with the baseline of the same kind.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `model_id` | bigint | no |  |  |
| `metric` | text | no |  |  |
| `value` | numeric | no |  |  |
| `evaluated_on_packages` | integer | no |  |  |
| `evaluated_at` | timestamp with time zone | no | `now()` |  |

**Keys and constraints**

- `model_metric_evaluated_on_packages_check`: CHECK ((evaluated_on_packages > 0))
- `model_metric_metric_fkey`: FOREIGN KEY (metric) REFERENCES dephealth.metric_definition(code)
- `model_metric_model_id_fkey`: FOREIGN KEY (model_id) REFERENCES dephealth.model(id) ON DELETE CASCADE
- `model_metric_pkey`: PRIMARY KEY (model_id, metric)

**Indexes**




### package

One package in the registry. The resolution columns record whether it reached a source repository and, if not, why. KPI1 is read from them.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `registry` | text | no | `'crates.io'::text` |  |
| `name` | text | no |  |  |
| `created_on` | date | yes |  |  |
| `latest_version` | text | yes |  |  |
| `repository_id` | bigint | yes |  |  |
| `resolution_status` | dephealth.resolution_status | no |  |  |
| `resolution_method` | dephealth.resolution_method | yes |  |  |
| `resolution_detail` | text | yes |  |  |
| `resolved_at` | timestamp with time zone | yes |  |  |
| `first_seen_run_id` | bigint | no |  |  |

**Keys and constraints**

- `package_name_wellformed`: CHECK ((name ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'::text))
- `package_registry_supported`: CHECK ((registry = 'crates.io'::text))
- `package_resolution_coherent`: CHECK ((((resolution_status = 'resolved'::dephealth.resolution_status) AND (repository_id IS NOT NULL) AND (resolution_method IS NOT NULL) AND (resolved_at IS NOT NULL)) OR ((resolution_status <> 'resolved'::dephealth.resolution_status) AND (repository_id IS NULL) AND (resolution_method IS NULL) AND (resolved_at IS NULL))))
- `package_first_seen_run_id_fkey`: FOREIGN KEY (first_seen_run_id) REFERENCES dephealth.ingestion_run(id)
- `package_repository_id_fkey`: FOREIGN KEY (repository_id) REFERENCES dephealth.repository(id) ON DELETE SET NULL
- `package_resolution_status_fkey`: FOREIGN KEY (resolution_status) REFERENCES dephealth.resolution_outcome(status)
- `package_pkey`: PRIMARY KEY (id)

**Indexes**

- CREATE INDEX package_by_repository ON dephealth.package USING btree (repository_id) WHERE (repository_id IS NOT NULL)
- CREATE UNIQUE INDEX package_identity ON dephealth.package USING btree (registry, lower(name))
- CREATE INDEX package_unresolved ON dephealth.package USING btree (resolution_status) WHERE (resolution_status <> 'resolved'::dephealth.resolution_status)


### package_dependency

Dependency edges from a published version to a required package. The development kind is left out of a consumer tree, since a consumer does not build the test suite of its dependencies.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `dependent_version_id` | bigint | no |  |  |
| `dependency_package_id` | bigint | no |  |  |
| `kind` | dephealth.dependency_kind | no |  |  |
| `requirement` | text | no |  |  |
| `optional` | boolean | no | `false` |  |

**Keys and constraints**

- `package_dependency_requirement_present`: CHECK ((length(btrim(requirement)) > 0))
- `package_dependency_dependency_package_id_fkey`: FOREIGN KEY (dependency_package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `package_dependency_dependent_version_id_fkey`: FOREIGN KEY (dependent_version_id) REFERENCES dephealth.package_version(id) ON DELETE CASCADE
- `package_dependency_pkey`: PRIMARY KEY (dependent_version_id, dependency_package_id, kind)

**Indexes**

- CREATE INDEX package_dependency_by_dependency ON dephealth.package_dependency USING btree (dependency_package_id, kind)


### package_version

Published versions. A lockfile entry names a version rather than a package, and the first publication date bounds how much history a forecast can rest on.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `package_id` | bigint | no |  |  |
| `version` | text | no |  |  |
| `published_at` | timestamp with time zone | yes |  |  |
| `yanked` | boolean | no | `false` |  |

**Keys and constraints**

- `package_version_present`: CHECK ((length(btrim(version)) > 0))
- `package_version_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE
- `package_version_pkey`: PRIMARY KEY (id)
- `package_version_package_id_version_key`: UNIQUE (package_id, version)

**Indexes**

- CREATE UNIQUE INDEX package_version_package_id_version_key ON dephealth.package_version USING btree (package_id, version)


### report

One generated assessment, addressable by a permanent link. Append only except for withdrawal, enforced by trigger and by column level privileges.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `token_digest` | bytea | no |  | SHA-256 of the random token in the permanent link. The token is never stored, so links cannot be recovered from a database dump. |
| `manifest_fingerprint` | bytea | yes |  | Salted SHA-256 of the sorted name@version set. Lets a resubmission be recognised without retaining the manifest. |
| `created_at` | timestamp with time zone | no | `now()` |  |
| `crates_data_as_of` | date | no |  |  |
| `events_data_as_of` | date | no |  |  |
| `abandonment_window_days` | integer | no |  |  |
| `risk_model_id` | bigint | no |  |  |
| `forecast_model_id` | bigint | no |  |  |
| `entry_count` | integer | no |  |  |
| `resolved_count` | integer | no |  |  |
| `withdrawn_at` | timestamp with time zone | yes |  |  |
| `withdrawal_reason` | text | yes |  |  |

**Keys and constraints**

- `report_abandonment_window_days_check`: CHECK ((abandonment_window_days > 0))
- `report_entry_count_check`: CHECK ((entry_count > 0))
- `report_fingerprint_is_sha256`: CHECK (((manifest_fingerprint IS NULL) OR (length(manifest_fingerprint) = 32)))
- `report_resolved_count_check`: CHECK ((resolved_count >= 0))
- `report_resolved_within_total`: CHECK ((resolved_count <= entry_count))
- `report_token_digest_is_sha256`: CHECK ((length(token_digest) = 32))
- `report_withdrawal_coherent`: CHECK (((withdrawn_at IS NULL) = (withdrawal_reason IS NULL)))
- `report_withdrawn_after_created`: CHECK (((withdrawn_at IS NULL) OR (withdrawn_at >= created_at)))
- `report_forecast_model_id_fkey`: FOREIGN KEY (forecast_model_id) REFERENCES dephealth.model(id)
- `report_risk_model_id_fkey`: FOREIGN KEY (risk_model_id) REFERENCES dephealth.model(id)
- `report_pkey`: PRIMARY KEY (id)
- `report_counts_match_entries`: TRIGGER DEFERRABLE INITIALLY DEFERRED
- `report_token_digest_key`: UNIQUE (token_digest)

**Indexes**

- CREATE INDEX report_by_fingerprint ON dephealth.report USING btree (manifest_fingerprint, created_at DESC) WHERE (manifest_fingerprint IS NOT NULL)
- CREATE UNIQUE INDEX report_token_digest_key ON dephealth.report USING btree (token_digest)


### report_entry

One line of a stored report, holding the figures as they stood when it was generated. Append only, so a report filed as evidence does not change when the next run overwrites the live scores.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `report_id` | bigint | no |  |  |
| `ordinal` | integer | no |  |  |
| `package_name` | text | no |  |  |
| `package_version` | text | no |  |  |
| `depth` | integer | no |  |  |
| `is_direct` | boolean | no |  |  |
| `package_id` | bigint | yes |  |  |
| `resolved` | boolean | no |  |  |
| `unresolved_reason` | dephealth.resolution_status | yes |  |  |
| `risk_probability` | numeric(5,4) | yes |  |  |
| `risk_horizon_days` | integer | yes |  |  |
| `forecast_point_downloads` | numeric(14,2) | yes |  |  |
| `forecast_horizon_months` | integer | yes |  |  |
| `insufficient_history` | boolean | no | `false` |  |
| `distinct_contributors` | integer | yes |  |  |
| `days_since_last_event` | integer | yes |  |  |

**Keys and constraints**

- `report_entry_days_since_last_event_check`: CHECK ((days_since_last_event >= 0))
- `report_entry_depth_check`: CHECK ((depth >= 0))
- `report_entry_direct_matches_depth`: CHECK ((is_direct = (depth = 0)))
- `report_entry_distinct_contributors_check`: CHECK ((distinct_contributors >= 0))
- `report_entry_forecast_coherent`: CHECK (((insufficient_history AND (forecast_point_downloads IS NULL)) OR (NOT insufficient_history)))
- `report_entry_forecast_horizon_months_check`: CHECK (((forecast_horizon_months >= 3) AND (forecast_horizon_months <= 12)))
- `report_entry_forecast_point_downloads_check`: CHECK ((forecast_point_downloads >= (0)::numeric))
- `report_entry_name_present`: CHECK ((length(btrim(package_name)) > 0))
- `report_entry_ordinal_check`: CHECK ((ordinal > 0))
- `report_entry_resolution_coherent`: CHECK (((resolved AND (unresolved_reason IS NULL) AND (risk_probability IS NOT NULL) AND (risk_horizon_days IS NOT NULL)) OR ((NOT resolved) AND (unresolved_reason IS NOT NULL) AND (risk_probability IS NULL) AND (risk_horizon_days IS NULL))))
- `report_entry_risk_horizon_days_check`: CHECK ((risk_horizon_days > 0))
- `report_entry_risk_probability_check`: CHECK (((risk_probability >= (0)::numeric) AND (risk_probability <= (1)::numeric)))
- `report_entry_version_present`: CHECK ((length(btrim(package_version)) > 0))
- `report_entry_package_id_fkey`: FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE SET NULL
- `report_entry_report_id_fkey`: FOREIGN KEY (report_id) REFERENCES dephealth.report(id) ON DELETE RESTRICT
- `report_entry_unresolved_reason_fkey`: FOREIGN KEY (unresolved_reason) REFERENCES dephealth.resolution_outcome(status)
- `report_entry_pkey`: PRIMARY KEY (report_id, ordinal)

**Indexes**

- CREATE INDEX report_entry_by_package ON dephealth.report_entry USING btree (lower(package_name))
- CREATE UNIQUE INDEX report_entry_one_row_per_package_version ON dephealth.report_entry USING btree (report_id, lower(package_name), package_version)


### report_entry_factor

The factor decomposition as it stood when the report was generated, so the evidence behind a filed score is as durable as the score. A child table rather than a document column, since it is read as rows ordered by contribution.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `report_id` | bigint | no |  |  |
| `ordinal` | integer | no |  |  |
| `factor` | text | no |  |  |
| `observed_value` | numeric | no |  |  |
| `contribution` | numeric | no |  |  |

**Keys and constraints**

- `report_entry_factor_factor_fkey`: FOREIGN KEY (factor) REFERENCES dephealth.risk_factor_catalogue(code)
- `report_entry_factor_report_id_ordinal_fkey`: FOREIGN KEY (report_id, ordinal) REFERENCES dephealth.report_entry(report_id, ordinal) ON DELETE RESTRICT
- `report_entry_factor_pkey`: PRIMARY KEY (report_id, ordinal, factor)

**Indexes**




### repository

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | no |  |  |
| `host` | text | no |  |  |
| `owner` | text | no |  |  |
| `name` | text | no |  |  |
| `canonical_url` | text | no |  |  |
| `first_seen_at` | timestamp with time zone | no | `now()` |  |
| `last_event_on` | date | yes |  |  |

**Keys and constraints**

- `repository_host_supported`: CHECK ((host = 'github.com'::text))
- `repository_name_present`: CHECK ((length(btrim(name)) > 0))
- `repository_owner_present`: CHECK ((length(btrim(owner)) > 0))
- `repository_url_wellformed`: CHECK ((canonical_url ~ '^https://[a-z0-9.-]+/[^/]+/[^/]+$'::text))
- `repository_pkey`: PRIMARY KEY (id)

**Indexes**

- CREATE UNIQUE INDEX repository_identity ON dephealth.repository USING btree (host, lower(owner), lower(name))


### resolution_outcome

Reference table, one row per value of dephealth.resolution_status.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `status` | dephealth.resolution_status | no |  |  |
| `label` | text | no |  |  |
| `is_resolved` | boolean | no |  |  |
| `remedy` | text | no |  |  |

**Keys and constraints**

- `resolution_outcome_label_present`: CHECK ((length(btrim(label)) > 0))
- `resolution_outcome_pkey`: PRIMARY KEY (status)

**Indexes**




### risk_factor

Decomposition of one risk score into named factors. Shown in the detail view, which is what makes the score evidence rather than a number.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `maintenance_risk_id` | bigint | no |  |  |
| `factor` | text | no |  |  |
| `observed_value` | numeric | no |  |  |
| `contribution` | numeric | no |  |  |

**Keys and constraints**

- `risk_factor_factor_fkey`: FOREIGN KEY (factor) REFERENCES dephealth.risk_factor_catalogue(code)
- `risk_factor_maintenance_risk_id_fkey`: FOREIGN KEY (maintenance_risk_id) REFERENCES dephealth.maintenance_risk(id) ON DELETE CASCADE
- `risk_factor_pkey`: PRIMARY KEY (maintenance_risk_id, factor)

**Indexes**




### risk_factor_catalogue

Reference table of the factors a risk score may be decomposed into. A factor takes a migration, since an explanation has to be describable in words before it is shown.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `code` | text | no |  |  |
| `label` | text | no |  |  |
| `description` | text | no |  |  |
| `higher_is_riskier` | boolean | no |  |  |

**Keys and constraints**

- `risk_factor_code_wellformed`: CHECK ((code ~ '^[a-z][a-z0-9_]{2,39}$'::text))
- `risk_factor_description_present`: CHECK ((length(btrim(description)) > 0))
- `risk_factor_label_present`: CHECK ((length(btrim(label)) > 0))
- `risk_factor_catalogue_pkey`: PRIMARY KEY (code)

**Indexes**




### mv_package_current_assessment (materialised view)

One row per package with the figures of the current models, refreshed concurrently at the end of a run. The ranked tree is built from it.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `package_id` | bigint | yes |  |  |
| `package_name` | text | yes |  |  |
| `latest_version` | text | yes |  |  |
| `resolution_status` | dephealth.resolution_status | yes |  |  |
| `repository_url` | text | yes |  |  |
| `maintenance_risk_id` | bigint | yes |  |  |
| `risk_probability` | numeric(5,4) | yes |  |  |
| `risk_horizon_days` | integer | yes |  |  |
| `abandonment_window_days` | integer | yes |  |  |
| `risk_as_of` | date | yes |  |  |
| `forecast_point_downloads` | numeric(14,2) | yes |  |  |
| `forecast_lower_downloads` | numeric(14,2) | yes |  |  |
| `forecast_upper_downloads` | numeric(14,2) | yes |  |  |
| `forecast_horizon_months` | integer | yes |  |  |
| `insufficient_history` | boolean | yes |  |  |
| `history_days` | integer | yes |  |  |
| `distinct_contributors` | integer | yes |  |  |
| `event_count` | integer | yes |  |  |
| `days_since_last_event` | integer | yes |  |  |
| `top_contributor_share` | numeric(4,3) | yes |  |  |
| `is_abandoned` | boolean | yes |  |  |

**Keys and constraints**



**Indexes**

- CREATE UNIQUE INDEX mv_package_current_assessment_name ON dephealth.mv_package_current_assessment USING btree (lower(package_name))
- CREATE UNIQUE INDEX mv_package_current_assessment_package_id ON dephealth.mv_package_current_assessment USING btree (package_id)
- CREATE INDEX mv_package_current_assessment_risk ON dephealth.mv_package_current_assessment USING btree (risk_probability DESC NULLS LAST)


### v_data_age (view)

Age of each source and the outcome of its last attempt. Read on every request, since no score may be shown without the age of the data behind it.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `source` | dephealth.data_source | yes |  |  |
| `data_as_of` | date | yes |  |  |
| `age_days` | integer | yes |  |  |
| `last_success_at` | timestamp with time zone | yes |  |  |
| `last_attempt_status` | dephealth.run_status | yes |  |  |
| `last_attempt_at` | timestamp with time zone | yes |  |  |

**Keys and constraints**



**Indexes**




### v_data_quality_finding (view)

Data quality conditions the constraints cannot express. An empty result is the expected state. Error means the data should not be served, warning means it should be looked at.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `check_code` | text | yes |  |  |
| `severity` | text | yes |  |  |
| `subject` | text | yes |  |  |
| `detail` | text | yes |  |  |

**Keys and constraints**



**Indexes**




### v_download_series (view)

The observed download series, plotted beside the forecast in the detail view.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `package_name` | text | yes |  |  |
| `day` | date | yes |  |  |
| `downloads` | bigint | yes |  |  |

**Keys and constraints**



**Indexes**




### v_kpi1_resolution (view)

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `packages` | bigint | yes |  |  |
| `resolved` | bigint | yes |  |  |
| `resolved_percent` | numeric | yes |  |  |
| `target_percent` | numeric | yes |  |  |

**Keys and constraints**



**Indexes**




### v_kpi1_resolution_by_reason (view)

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `status` | dephealth.resolution_status | yes |  |  |
| `label` | text | yes |  |  |
| `packages` | bigint | yes |  |  |
| `share_percent` | numeric | yes |  |  |

**Keys and constraints**



**Indexes**




### v_model_against_baseline (view)

Every held-out metric of the serving models beside the same metric of the baseline of the same kind. KPI3 and KPI4 are rows of this view.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `kind` | dephealth.model_kind | yes |  |  |
| `metric` | text | yes |  |  |
| `metric_label` | text | yes |  |  |
| `kpi` | text | yes |  |  |
| `lower_is_better` | boolean | yes |  |  |
| `model_name` | text | yes |  |  |
| `model_version` | text | yes |  |  |
| `model_value` | numeric | yes |  |  |
| `baseline_name` | text | yes |  |  |
| `baseline_value` | numeric | yes |  |  |
| `beats_baseline` | boolean | yes |  |  |

**Keys and constraints**



**Indexes**




### v_package_assessment (view)

The read-only assessment of one package, with the disclosure threshold applied and the age of both sources attached. The public API role holds this view and no base table.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `package_name` | text | yes |  |  |
| `latest_version` | text | yes |  |  |
| `repository_url` | text | yes |  |  |
| `risk_probability` | numeric(5,4) | yes |  |  |
| `risk_horizon_days` | integer | yes |  |  |
| `abandonment_window_days` | integer | yes |  |  |
| `risk_as_of` | date | yes |  |  |
| `forecast_point_downloads` | numeric(14,2) | yes |  |  |
| `forecast_lower_downloads` | numeric(14,2) | yes |  |  |
| `forecast_upper_downloads` | numeric(14,2) | yes |  |  |
| `forecast_horizon_months` | integer | yes |  |  |
| `insufficient_history` | boolean | yes |  |  |
| `distinct_contributors` | integer | yes |  |  |
| `top_contributor_share` | numeric | yes |  |  |
| `contributor_count_withheld` | boolean | yes |  |  |
| `days_since_last_event` | integer | yes |  |  |
| `is_abandoned` | boolean | yes |  |  |
| `resolution_label` | text | yes |  |  |
| `is_resolved` | boolean | yes |  |  |
| `resolution_remedy` | text | yes |  |  |
| `registry_data_as_of` | date | yes |  |  |
| `events_data_as_of` | date | yes |  |  |

**Keys and constraints**



**Indexes**




### v_report (view)

A stored report with the models and the definition it was generated under, so a reader who did not run the assessment can interpret it.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | bigint | yes |  |  |
| `token_digest` | bytea | yes |  |  |
| `created_at` | timestamp with time zone | yes |  |  |
| `crates_data_as_of` | date | yes |  |  |
| `events_data_as_of` | date | yes |  |  |
| `abandonment_window_days` | integer | yes |  |  |
| `risk_model_name` | text | yes |  |  |
| `risk_model_version` | text | yes |  |  |
| `forecast_model_name` | text | yes |  |  |
| `forecast_model_version` | text | yes |  |  |
| `entry_count` | integer | yes |  |  |
| `resolved_count` | integer | yes |  |  |
| `unresolved_count` | integer | yes |  |  |
| `is_withdrawn` | boolean | yes |  |  |
| `withdrawn_at` | timestamp with time zone | yes |  |  |
| `withdrawal_reason` | text | yes |  |  |

**Keys and constraints**



**Indexes**




### v_report_entry (view)

The lines of a stored report. The disclosure threshold applies here too, so a report is not a route by which a withheld count is published.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `report_id` | bigint | yes |  |  |
| `ordinal` | integer | yes |  |  |
| `package_name` | text | yes |  |  |
| `package_version` | text | yes |  |  |
| `depth` | integer | yes |  |  |
| `is_direct` | boolean | yes |  |  |
| `resolved` | boolean | yes |  |  |
| `unresolved_label` | text | yes |  |  |
| `unresolved_remedy` | text | yes |  |  |
| `risk_probability` | numeric(5,4) | yes |  |  |
| `risk_horizon_days` | integer | yes |  |  |
| `forecast_point_downloads` | numeric(14,2) | yes |  |  |
| `forecast_horizon_months` | integer | yes |  |  |
| `insufficient_history` | boolean | yes |  |  |
| `distinct_contributors` | integer | yes |  |  |
| `days_since_last_event` | integer | yes |  |  |

**Keys and constraints**



**Indexes**




## Routines

| Routine | Kind | Returns | Purpose |
|---|---|---|---|
| `abandonment_window_days()` | function | integer |  |
| `check_report_counts()` | function | trigger |  |
| `disclosed_contributors(distinct_contributors integer)` | function | integer | Applies the disclosure threshold. Returns null between one and the threshold, the only range in which a count describes identifiable people. Every read-only view passes its counts through this. |
| `disclosed_share(in_share numeric, in_contributors integer)` | function | numeric |  |
| `finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date DEFAULT NULL::date, IN in_rows_ingested bigint DEFAULT 0, IN in_rows_rejected bigint DEFAULT 0, IN in_raw_bytes_discarded bigint DEFAULT NULL::bigint, IN in_failure_detail text DEFAULT NULL::text)` | procedure |  | Closes a run and, on success, refreshes the serving view. Runs with the owner privileges, since refreshing a materialised view requires ownership. Every identifier inside is schema qualified and the search path is fixed. |
| `guard_report_mutation()` | function | trigger |  |
| `is_abandoned(days_since_last_event integer)` | function | boolean | The abandonment label of the requirements document. The training label and the interface both read it, so the two cannot drift apart. |
| `k_anonymity_threshold()` | function | integer | Smallest contributor count publishable through a read-only view. A migration rather than a setting, so the value in force on any date is in the schema history. |
| `manifest_fingerprint(in_entries text[], in_salt text)` | function | bytea | Salted digest of the sorted name@version set of a manifest. Recognises a resubmission without retaining the manifest. The salt is held by the application, not the database. |
| `reject_mutation()` | function | trigger |  |
| `report_token_digest(in_token text)` | function | bytea | SHA-256 of a report link token. A fast digest is correct here and a password digest would not be, since the token is random. |
| `start_ingestion_run(in_source dephealth.data_source)` | function | bigint | Opens a run and returns its id. Every row a run writes carries that id, so a bad run can be found and removed afterwards. |
| `sync_repository_last_event()` | function | trigger |  |
| `withdraw_report(IN in_token_digest bytea, IN in_reason text)` | procedure |  |  |

## Privileges

Generated from the live grants. The four group roles are described in `db/roles/README.md`.

| Relation | Role | Privileges |
|---|---|---|
| `activity_feature` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `activity_feature` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `adoption_forecast` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `adoption_forecast` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `download_daily` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `download_daily` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `feature_window` | `dephealth_app` | SELECT |
| `feature_window` | `dephealth_ingest` | SELECT |
| `feature_window` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `ingestion_run` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `ingestion_run` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `maintenance_risk` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `maintenance_risk` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `metric_definition` | `dephealth_app` | SELECT |
| `metric_definition` | `dephealth_ingest` | SELECT |
| `metric_definition` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `model` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `model` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `model_metric` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `model_metric` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `mv_package_current_assessment` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `package` | `dephealth_app` | SELECT |
| `package` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `package` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `package_dependency` | `dephealth_app` | SELECT |
| `package_dependency` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `package_dependency` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `package_version` | `dephealth_app` | SELECT |
| `package_version` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `package_version` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `report` | `dephealth_app` | INSERT, SELECT |
| `report` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `report_entry` | `dephealth_app` | INSERT, SELECT |
| `report_entry` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `report_entry_factor` | `dephealth_app` | INSERT, SELECT |
| `report_entry_factor` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `repository` | `dephealth_app` | SELECT |
| `repository` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `repository` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `resolution_outcome` | `dephealth_app` | SELECT |
| `resolution_outcome` | `dephealth_ingest` | SELECT |
| `resolution_outcome` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `risk_factor` | `dephealth_ingest` | INSERT, SELECT, UPDATE |
| `risk_factor` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `risk_factor_catalogue` | `dephealth_app` | SELECT |
| `risk_factor_catalogue` | `dephealth_ingest` | SELECT |
| `risk_factor_catalogue` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_data_age` | `dephealth_app` | SELECT |
| `v_data_age` | `dephealth_ingest` | SELECT |
| `v_data_age` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_data_age` | `dephealth_public_read` | SELECT |
| `v_data_quality_finding` | `dephealth_ingest` | SELECT |
| `v_data_quality_finding` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_download_series` | `dephealth_app` | SELECT |
| `v_download_series` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_download_series` | `dephealth_public_read` | SELECT |
| `v_kpi1_resolution` | `dephealth_ingest` | SELECT |
| `v_kpi1_resolution` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_kpi1_resolution_by_reason` | `dephealth_ingest` | SELECT |
| `v_kpi1_resolution_by_reason` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_model_against_baseline` | `dephealth_ingest` | SELECT |
| `v_model_against_baseline` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_package_assessment` | `dephealth_app` | SELECT |
| `v_package_assessment` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_package_assessment` | `dephealth_public_read` | SELECT |
| `v_report` | `dephealth_app` | SELECT |
| `v_report` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_report` | `dephealth_public_read` | SELECT |
| `v_report_entry` | `dephealth_app` | SELECT |
| `v_report_entry` | `dephealth_owner` | DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE |
| `v_report_entry` | `dephealth_public_read` | SELECT |

*Generated by `docs/generate-data-dictionary.sh`. Do not edit.*
