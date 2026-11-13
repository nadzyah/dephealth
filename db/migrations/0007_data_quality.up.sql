-- 0007 data quality checks

-- Conditions a constraint cannot express, since they span tables or describe
-- a suspicion rather than a violation. An empty result is expected
CREATE VIEW dephealth.v_data_quality_finding AS

SELECT 'download_day_out_of_range'  AS check_code,
       'error'                      AS severity,
       p.name                       AS subject,
       format('%s rows land in the quarantine partition, earliest %s',
              count(*), min(d.day))  AS detail
  FROM dephealth.download_daily_unexpected d
  JOIN dephealth.package p ON p.id = d.package_id
 GROUP BY p.name

UNION ALL

SELECT 'download_day_in_future',
       'error',
       p.name,
       format('latest day is %s', max(d.day))
  FROM dephealth.download_daily d
  JOIN dephealth.package p ON p.id = d.package_id
 GROUP BY p.name
HAVING max(d.day) > current_date

UNION ALL

SELECT 'download_series_gap',
       'warning',
       p.name,
       format('%s of the 30 days ending yesterday are missing',
              30 - count(DISTINCT d.day))
  FROM dephealth.package p
  JOIN dephealth.download_daily d
    ON d.package_id = p.id
   AND d.day BETWEEN current_date - 30 AND current_date - 1
 GROUP BY p.name
HAVING count(DISTINCT d.day) < 30

UNION ALL

SELECT 'package_depends_on_itself',
       'error',
       p.name,
       format('version %s requires its own package', v.version)
  FROM dephealth.package_dependency pd
  JOIN dephealth.package_version v ON v.id = pd.dependent_version_id
  JOIN dephealth.package p         ON p.id = v.package_id
 WHERE p.id = pd.dependency_package_id

UNION ALL

SELECT 'resolved_without_activity',
       'warning',
       p.name,
       'resolved to a repository but no activity features were derived'
  FROM dephealth.package p
  JOIN dephealth.resolution_outcome o ON o.status = p.resolution_status
 WHERE o.is_resolved
   AND NOT EXISTS (
        SELECT 1 FROM dephealth.activity_feature a WHERE a.package_id = p.id
   )

UNION ALL

SELECT 'scored_without_resolution',
       'error',
       p.name,
       format('risk score %s on a package with status %s',
              mr.probability, p.resolution_status)
  FROM dephealth.maintenance_risk mr
  JOIN dephealth.package p            ON p.id = mr.package_id
  JOIN dephealth.resolution_outcome o ON o.status = p.resolution_status
 WHERE NOT o.is_resolved

UNION ALL

SELECT 'serving_model_without_metric',
       'error',
       m.kind::text,
       format('%s %s carries no %s', m.name, m.version, d.code)
  FROM dephealth.model m
  JOIN dephealth.metric_definition d
    ON (m.kind = 'maintenance_risk'  AND d.code = 'concordance_index')
    OR (m.kind = 'adoption_forecast' AND d.code = 'smape')
 WHERE m.is_current
   AND NOT EXISTS (
        SELECT 1 FROM dephealth.model_metric mm
         WHERE mm.model_id = m.id AND mm.metric = d.code
   )

UNION ALL

SELECT 'empty_successful_run',
       'warning',
       r.source::text,
       format('run %s succeeded on %s having loaded no rows', r.id, r.data_as_of)
  FROM dephealth.ingestion_run r
 WHERE r.status = 'succeeded'
   AND r.rows_ingested = 0

UNION ALL

SELECT 'activity_without_last_event',
       'error',
       p.name,
       format('window of %s days as of %s has %s contributors and no last event date',
              a.window_days, a.as_of, a.distinct_contributors)
  FROM dephealth.activity_feature a
  JOIN dephealth.package p ON p.id = a.package_id
 WHERE a.distinct_contributors > 0
   AND a.days_since_last_event IS NULL

UNION ALL

SELECT 'report_counts_disagree',
       'error',
       r.id::text,
       format('declares %s entries, holds %s', r.entry_count, count(e.ordinal))
  FROM dephealth.report r
  LEFT JOIN dephealth.report_entry e ON e.report_id = r.id
 GROUP BY r.id, r.entry_count
HAVING count(e.ordinal) <> r.entry_count;

COMMENT ON VIEW dephealth.v_data_quality_finding IS
    'Data quality conditions the constraints cannot express. An empty result is the expected state. Error means the data should not be served, warning means it should be looked at.';
