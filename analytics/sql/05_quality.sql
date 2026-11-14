-- Quality checks. A row here stops the run, since loading a known bad batch is
-- worse than serving yesterday's data for another day.

CREATE OR REPLACE VIEW main.quality_finding AS

SELECT 'duplicate_package_name' AS check_code, 'error' AS severity,
       count(*)::VARCHAR AS detail
  FROM (SELECT lower(package_name) FROM mart.dim_package
         WHERE is_current GROUP BY 1 HAVING count(*) > 1)
HAVING count(*) > 0

UNION ALL
-- two current rows for one package means the type 2 close did not happen
SELECT 'multiple_current_dimension_rows', 'error', count(*)::VARCHAR
  FROM (SELECT crates_id FROM mart.dim_package
         WHERE is_current GROUP BY 1 HAVING count(*) > 1)
HAVING count(*) > 0

UNION ALL
SELECT 'duplicate_download_day', 'error', count(*)::VARCHAR
  FROM (SELECT crates_id, day FROM mart.fct_download_daily
         GROUP BY 1, 2 HAVING count(*) > 1)
HAVING count(*) > 0

UNION ALL
SELECT 'negative_downloads', 'error', count(*)::VARCHAR
  FROM mart.fct_download_daily WHERE downloads < 0
HAVING count(*) > 0

UNION ALL
SELECT 'null_in_key_column', 'error', count(*)::VARCHAR
  FROM mart.fct_download_daily WHERE crates_id IS NULL OR day IS NULL
HAVING count(*) > 0

UNION ALL
SELECT 'day_in_future', 'error', count(*)::VARCHAR
  FROM mart.fct_download_daily WHERE day > current_date
HAVING count(*) > 0

UNION ALL
-- impossible arithmetically, so the event id deduplication did not hold
SELECT 'contributors_exceed_events', 'error', count(*)::VARCHAR
  FROM feature.activity_window
 WHERE distinct_contributors > event_count
HAVING count(*) > 0

UNION ALL
SELECT 'share_out_of_range', 'error', count(*)::VARCHAR
  FROM feature.activity_window
 WHERE top_contributor_share IS NOT NULL
   AND (top_contributor_share <= 0 OR top_contributor_share > 1)
HAVING count(*) > 0

UNION ALL
-- a partial aggregate rather than a fact about the package
SELECT 'share_disagrees_with_events', 'error', count(*)::VARCHAR
  FROM feature.activity_window
 WHERE (event_count = 0) <> (top_contributor_share IS NULL)
HAVING count(*) > 0

UNION ALL
-- usually means the repository fields in the dump have changed shape
SELECT 'resolution_rate_below_target', 'warning',
       round(100.0 * count(*) FILTER (WHERE resolution_status = 'resolved')
             / nullif(count(*), 0), 1)::VARCHAR
  FROM mart.dim_package
 WHERE is_current
HAVING round(100.0 * count(*) FILTER (WHERE resolution_status = 'resolved')
             / nullif(count(*), 0), 1) < 90;
