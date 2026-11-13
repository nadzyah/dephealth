-- Detail view of one package.
--
--   psql -v package=failure -f db/queries/02_package_detail.sql

\echo '-- assessment'
SELECT package_name, risk_probability, risk_horizon_days, abandonment_window_days,
       days_since_last_event, is_abandoned,
       distinct_contributors, contributor_count_withheld, top_contributor_share,
       forecast_point_downloads, forecast_lower_downloads, forecast_upper_downloads,
       forecast_horizon_months, insufficient_history,
       registry_data_as_of, events_data_as_of
  FROM dephealth.v_package_assessment
 WHERE package_name = :'package';

\echo '-- factors behind the score, largest first'
SELECT c.label,
       c.description,
       f.observed_value,
       f.contribution,
       CASE WHEN f.contribution > 0 THEN 'raises the risk'
            WHEN f.contribution < 0 THEN 'lowers the risk'
            ELSE 'no effect' END AS direction
  FROM dephealth.maintenance_risk mr
  JOIN dephealth.package p             ON p.id = mr.package_id
  JOIN dephealth.model m               ON m.id = mr.model_id AND m.is_current
  JOIN dephealth.risk_factor f         ON f.maintenance_risk_id = mr.id
  JOIN dephealth.risk_factor_catalogue c ON c.code = f.factor
 WHERE p.name = :'package'
 ORDER BY abs(f.contribution) DESC;

\echo '-- monthly downloads with a three month moving average'
SELECT month,
       downloads,
       round(avg(downloads) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))
           AS moving_average_3m,
       round(100.0 * (downloads::numeric / nullif(lag(downloads) OVER (ORDER BY month), 0) - 1), 1)
           AS change_percent
  FROM (
        SELECT date_trunc('month', day)::date AS month,
               sum(downloads)                 AS downloads
          FROM dephealth.v_download_series
         WHERE package_name = :'package'
         GROUP BY 1
  ) monthly
 ORDER BY month DESC
 LIMIT 18;
