-- Analytical queries over the whole stored set. Read by the administrator and
-- the evaluation notebooks, never by the request path.

\echo '-- resolution rate, and where it is lost'
SELECT * FROM dephealth.v_kpi1_resolution;
SELECT * FROM dephealth.v_kpi1_resolution_by_reason ORDER BY packages DESC;

\echo '-- the serving models against their baselines'
SELECT kind, metric_label, kpi, model_value, baseline_value, beats_baseline
  FROM dephealth.v_model_against_baseline
 ORDER BY kpi NULLS LAST;

\echo '-- risk distribution by how concentrated the maintenance effort is'
SELECT width_bucket(a.top_contributor_share, 0, 1, 4) AS concentration_quartile,
       count(*)                                        AS packages,
       round(avg(a.risk_probability), 4)               AS mean_risk,
       round(
           percentile_cont(0.5) WITHIN GROUP (ORDER BY a.risk_probability)::numeric, 4
       )                                               AS median_risk,
       count(*) FILTER (WHERE a.is_abandoned)          AS already_silent
  FROM dephealth.mv_package_current_assessment a
 WHERE a.top_contributor_share IS NOT NULL
   AND a.risk_probability IS NOT NULL
 GROUP BY 1
 ORDER BY 1;

\echo '-- the packages carrying the most exposure: highest risk among those most depended on'
SELECT a.package_name,
       a.risk_probability,
       a.days_since_last_event,
       count(DISTINCT pd.dependent_version_id) AS dependent_versions,
       rank() OVER (ORDER BY a.risk_probability DESC NULLS LAST) AS by_risk,
       rank() OVER (ORDER BY count(DISTINCT pd.dependent_version_id) DESC) AS by_dependents
  FROM dephealth.mv_package_current_assessment a
  LEFT JOIN dephealth.package_dependency pd ON pd.dependency_package_id = a.package_id
 GROUP BY a.package_name, a.risk_probability, a.days_since_last_event
 ORDER BY by_risk, by_dependents
 LIMIT 20;

\echo '-- adoption against production: are the consumers leaving before the maintainers stop'
SELECT a.package_name,
       recent.downloads_90d,
       earlier.downloads_90d                                  AS downloads_prior_90d,
       round(100.0 * (recent.downloads_90d::numeric
             / nullif(earlier.downloads_90d, 0) - 1), 1)      AS download_change_percent,
       a.distinct_contributors,
       a.days_since_last_event,
       a.risk_probability
  FROM dephealth.mv_package_current_assessment a
  LEFT JOIN LATERAL (
        SELECT sum(downloads) AS downloads_90d
          FROM dephealth.download_daily d
         WHERE d.package_id = a.package_id
           AND d.day BETWEEN current_date - 90 AND current_date - 1
  ) recent ON true
  LEFT JOIN LATERAL (
        SELECT sum(downloads) AS downloads_90d
          FROM dephealth.download_daily d
         WHERE d.package_id = a.package_id
           AND d.day BETWEEN current_date - 180 AND current_date - 91
  ) earlier ON true
 WHERE recent.downloads_90d IS NOT NULL
 ORDER BY download_change_percent;

\echo '-- freshness of each source'
SELECT source, data_as_of, age_days, last_attempt_status, last_attempt_at
  FROM dephealth.v_data_age
 ORDER BY source;
