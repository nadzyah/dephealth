-- 0005 derived definitions, views and the serving materialised view

-- Definitions

CREATE FUNCTION dephealth.abandonment_window_days() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN 180;

-- Read by the training label and the interface alike, so the two cannot drift
CREATE FUNCTION dephealth.is_abandoned(days_since_last_event integer) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN days_since_last_event >= dephealth.abandonment_window_days();

COMMENT ON FUNCTION dephealth.is_abandoned(integer) IS
    'The abandonment label of the requirements document. The training label and the interface both read it, so the two cannot drift apart.';

-- Zero is published, since it describes nobody and is the clearest signal
-- there is. One up to the threshold is withheld
CREATE FUNCTION dephealth.disclosed_contributors(distinct_contributors integer)
    RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN CASE
        WHEN distinct_contributors = 0
          OR distinct_contributors >= dephealth.k_anonymity_threshold()
        THEN distinct_contributors
    END;

COMMENT ON FUNCTION dephealth.disclosed_contributors(integer) IS
    'Applies the disclosure threshold. Returns null between one and the threshold, the only range in which a count describes identifiable people. Every read-only view passes its counts through this.';

-- A share of 1.000 beside a withheld count would reveal that the count is one
CREATE FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer)
    RETURNS numeric
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN CASE
        WHEN in_contributors >= dephealth.k_anonymity_threshold() THEN in_share
    END;

-- Data age

CREATE VIEW dephealth.v_data_age AS
SELECT s.source,
       succeeded.data_as_of,
       (current_date - succeeded.data_as_of)       AS age_days,
       succeeded.finished_at                       AS last_success_at,
       latest.status                               AS last_attempt_status,
       latest.started_at                           AS last_attempt_at
  FROM (SELECT unnest(enum_range(NULL::dephealth.data_source)) AS source) s
  LEFT JOIN LATERAL (
        SELECT r.data_as_of, r.finished_at
          FROM dephealth.ingestion_run r
         WHERE r.source = s.source
           AND r.status = 'succeeded'
         ORDER BY r.data_as_of DESC
         LIMIT 1
  ) succeeded ON true
  LEFT JOIN LATERAL (
        SELECT r.status, r.started_at
          FROM dephealth.ingestion_run r
         WHERE r.source = s.source
         ORDER BY r.started_at DESC
         LIMIT 1
  ) latest ON true;

COMMENT ON VIEW dephealth.v_data_age IS
    'Age of each source and the outcome of its last attempt. Read on every request, since no score may be shown without the age of the data behind it.';

-- One indexed read instead of three newest-row lookups per package. The latency
-- budget for a report does not survive the second form

CREATE MATERIALIZED VIEW dephealth.mv_package_current_assessment AS
WITH current_risk AS (
    SELECT DISTINCT ON (mr.package_id)
           mr.package_id,
           mr.id AS maintenance_risk_id,
           mr.probability,
           mr.horizon_days,
           mr.abandonment_window_days,
           mr.as_of
      FROM dephealth.maintenance_risk mr
      JOIN dephealth.model m ON m.id = mr.model_id AND m.is_current
     ORDER BY mr.package_id, mr.as_of DESC
), current_forecast AS (
    SELECT DISTINCT ON (f.package_id)
           f.package_id,
           f.point_downloads,
           f.lower_downloads,
           f.upper_downloads,
           f.horizon_months,
           f.insufficient_history,
           f.history_days,
           f.as_of
      FROM dephealth.adoption_forecast f
      JOIN dephealth.model m ON m.id = f.model_id AND m.is_current
     -- longest horizon, which is the one the ranked tree shows
     ORDER BY f.package_id, f.as_of DESC, f.horizon_months DESC
), current_activity AS (
    SELECT DISTINCT ON (a.package_id)
           a.package_id,
           a.distinct_contributors,
           a.event_count,
           a.days_since_last_event,
           a.top_contributor_share,
           a.as_of
      FROM dephealth.activity_feature a
     WHERE a.window_days = 90
     ORDER BY a.package_id, a.as_of DESC
)
SELECT p.id                       AS package_id,
       p.name                     AS package_name,
       p.latest_version,
       p.resolution_status,
       rp.canonical_url           AS repository_url,
       cr.maintenance_risk_id,
       cr.probability             AS risk_probability,
       cr.horizon_days            AS risk_horizon_days,
       cr.abandonment_window_days,
       cr.as_of                   AS risk_as_of,
       cf.point_downloads         AS forecast_point_downloads,
       cf.lower_downloads         AS forecast_lower_downloads,
       cf.upper_downloads         AS forecast_upper_downloads,
       cf.horizon_months          AS forecast_horizon_months,
       cf.insufficient_history,
       cf.history_days,
       ca.distinct_contributors,
       ca.event_count,
       ca.days_since_last_event,
       ca.top_contributor_share,
       dephealth.is_abandoned(ca.days_since_last_event) AS is_abandoned
  FROM dephealth.package p
  LEFT JOIN dephealth.repository rp ON rp.id = p.repository_id
  LEFT JOIN current_risk cr        ON cr.package_id = p.id
  LEFT JOIN current_forecast cf    ON cf.package_id = p.id
  LEFT JOIN current_activity ca    ON ca.package_id = p.id;

COMMENT ON MATERIALIZED VIEW dephealth.mv_package_current_assessment IS
    'One row per package with the figures of the current models, refreshed concurrently at the end of a run. The ranked tree is built from it.';

-- Required by REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX mv_package_current_assessment_package_id
    ON dephealth.mv_package_current_assessment (package_id);

CREATE UNIQUE INDEX mv_package_current_assessment_name
    ON dephealth.mv_package_current_assessment (lower(package_name));

CREATE INDEX mv_package_current_assessment_risk
    ON dephealth.mv_package_current_assessment (risk_probability DESC NULLS LAST);

-- Read-only interface. This view and v_report_entry are the only paths by
-- which a contributor count leaves the database

CREATE VIEW dephealth.v_package_assessment AS
SELECT a.package_name,
       a.latest_version,
       a.repository_url,
       a.risk_probability,
       a.risk_horizon_days,
       a.abandonment_window_days,
       a.risk_as_of,
       a.forecast_point_downloads,
       a.forecast_lower_downloads,
       a.forecast_upper_downloads,
       a.forecast_horizon_months,
       a.insufficient_history,
       dephealth.disclosed_contributors(a.distinct_contributors) AS distinct_contributors,
       dephealth.disclosed_share(a.top_contributor_share, a.distinct_contributors)
                                                                 AS top_contributor_share,
       (dephealth.disclosed_contributors(a.distinct_contributors) IS NULL
            AND a.distinct_contributors IS NOT NULL)
                                                                 AS contributor_count_withheld,
       a.days_since_last_event,
       a.is_abandoned,
       o.label                                                   AS resolution_label,
       o.is_resolved,
       o.remedy                                                  AS resolution_remedy,
       registry_age.data_as_of                                   AS registry_data_as_of,
       events_age.data_as_of                                     AS events_data_as_of
  FROM dephealth.mv_package_current_assessment a
  JOIN dephealth.resolution_outcome o ON o.status = a.resolution_status
  LEFT JOIN dephealth.v_data_age registry_age ON registry_age.source = 'crates_io_dump'
  LEFT JOIN dephealth.v_data_age events_age   ON events_age.source   = 'gh_archive';

COMMENT ON VIEW dephealth.v_package_assessment IS
    'The read-only assessment of one package, with the disclosure threshold applied and the age of both sources attached. The public API role holds this view and no base table.';

CREATE VIEW dephealth.v_download_series AS
SELECT p.name AS package_name,
       d.day,
       d.downloads
  FROM dephealth.download_daily d
  JOIN dephealth.package p ON p.id = d.package_id;

COMMENT ON VIEW dephealth.v_download_series IS
    'The observed download series, plotted beside the forecast in the detail view.';

CREATE VIEW dephealth.v_report AS
SELECT r.id,
       r.token_digest,
       r.created_at,
       r.crates_data_as_of,
       r.events_data_as_of,
       r.abandonment_window_days,
       risk_model.name    AS risk_model_name,
       risk_model.version AS risk_model_version,
       fc_model.name      AS forecast_model_name,
       fc_model.version   AS forecast_model_version,
       r.entry_count,
       r.resolved_count,
       r.entry_count - r.resolved_count AS unresolved_count,
       (r.withdrawn_at IS NOT NULL)     AS is_withdrawn,
       r.withdrawn_at,
       r.withdrawal_reason
  FROM dephealth.report r
  JOIN dephealth.model risk_model ON risk_model.id = r.risk_model_id
  JOIN dephealth.model fc_model   ON fc_model.id   = r.forecast_model_id;

COMMENT ON VIEW dephealth.v_report IS
    'A stored report with the models and the definition it was generated under, so a reader who did not run the assessment can interpret it.';

CREATE VIEW dephealth.v_report_entry AS
SELECT e.report_id,
       e.ordinal,
       e.package_name,
       e.package_version,
       e.depth,
       e.is_direct,
       e.resolved,
       o.label  AS unresolved_label,
       o.remedy AS unresolved_remedy,
       e.risk_probability,
       e.risk_horizon_days,
       e.forecast_point_downloads,
       e.forecast_horizon_months,
       e.insufficient_history,
       dephealth.disclosed_contributors(e.distinct_contributors) AS distinct_contributors,
       e.days_since_last_event
  FROM dephealth.report_entry e
  LEFT JOIN dephealth.resolution_outcome o ON o.status = e.unresolved_reason;

COMMENT ON VIEW dephealth.v_report_entry IS
    'The lines of a stored report. The disclosure threshold applies here too, so a report is not a route by which a withheld count is published.';

-- Indicator views

CREATE VIEW dephealth.v_kpi1_resolution AS
SELECT count(*)                                          AS packages,
       count(*) FILTER (WHERE o.is_resolved)             AS resolved,
       round(100.0 * count(*) FILTER (WHERE o.is_resolved)
             / nullif(count(*), 0), 2)                   AS resolved_percent,
       90.0                                              AS target_percent
  FROM dephealth.package p
  JOIN dephealth.resolution_outcome o ON o.status = p.resolution_status;

CREATE VIEW dephealth.v_kpi1_resolution_by_reason AS
SELECT o.status,
       o.label,
       count(p.id)                                       AS packages,
       round(100.0 * count(p.id) / nullif(sum(count(p.id)) OVER (), 0), 2)
                                                         AS share_percent
  FROM dephealth.resolution_outcome o
  LEFT JOIN dephealth.package p ON p.resolution_status = o.status
 GROUP BY o.status, o.label;

CREATE VIEW dephealth.v_model_against_baseline AS
SELECT current_model.kind,
       d.code                      AS metric,
       d.label                     AS metric_label,
       d.kpi,
       d.lower_is_better,
       current_model.name          AS model_name,
       current_model.version       AS model_version,
       current_metric.value        AS model_value,
       baseline_model.name         AS baseline_name,
       baseline_metric.value       AS baseline_value,
       CASE
           WHEN baseline_metric.value IS NULL THEN NULL
           WHEN d.lower_is_better THEN current_metric.value < baseline_metric.value
           ELSE current_metric.value > baseline_metric.value
       END                         AS beats_baseline
  FROM dephealth.model current_model
  JOIN dephealth.model_metric current_metric ON current_metric.model_id = current_model.id
  JOIN dephealth.metric_definition d         ON d.code = current_metric.metric
  LEFT JOIN dephealth.model baseline_model
         ON baseline_model.kind = current_model.kind AND baseline_model.is_baseline
  LEFT JOIN dephealth.model_metric baseline_metric
         ON baseline_metric.model_id = baseline_model.id
        AND baseline_metric.metric = current_metric.metric
 WHERE current_model.is_current;

COMMENT ON VIEW dephealth.v_model_against_baseline IS
    'Every held-out metric of the serving models beside the same metric of the baseline of the same kind. KPI3 and KPI4 are rows of this view.';
