-- Layer 4, features. The trailing windows the models are fitted on. The last
-- statements drop the two event tables, which are where the logins were.

CREATE SCHEMA IF NOT EXISTS feature;

-- One row per package per window, as of the latest day loaded
CREATE OR REPLACE TABLE feature.activity_window AS
WITH as_of AS (
    SELECT max(day) AS as_of_day FROM mart.fct_activity_daily
),
windows(window_days) AS (
    VALUES (30), (90), (180), (365)
),
windowed AS (
    SELECT a.crates_id,
           w.window_days,
           o.as_of_day,
           sum(a.event_count)          AS event_count,
           sum(a.commit_event_count)   AS commit_event_count,
           sum(a.issue_event_count)    AS issue_event_count,
           sum(a.review_event_count)   AS review_event_count,
           -- weighted by volume, so one busy day cannot dominate the window
           sum(a.top_contributor_share * a.event_count)
               / nullif(sum(a.event_count), 0) AS top_contributor_share
      FROM mart.fct_activity_daily a
     CROSS JOIN windows w
     CROSS JOIN as_of o
     WHERE a.day > o.as_of_day - w.window_days
       AND a.day <= o.as_of_day
     GROUP BY 1, 2, 3
),
-- Recounted per window, since an account working two days is one contributor
contributors AS (
    SELECT e.crates_id,
           w.window_days,
           count(DISTINCT e.actor_login) AS distinct_contributors
      FROM staging.tracked_event e
     CROSS JOIN windows w
     CROSS JOIN as_of o
     WHERE e.day > o.as_of_day - w.window_days
       AND e.day <= o.as_of_day
     GROUP BY 1, 2
),
last_event AS (
    SELECT crates_id, max(day) AS last_event_on
      FROM mart.fct_activity_daily
     GROUP BY 1
)
SELECT p.crates_id,
       o.as_of_day                                     AS as_of,
       w.window_days,
       coalesce(c.distinct_contributors, 0)            AS distinct_contributors,
       coalesce(x.event_count, 0)                      AS event_count,
       coalesce(x.commit_event_count, 0)               AS commit_event_count,
       coalesce(x.issue_event_count, 0)                AS issue_event_count,
       coalesce(x.review_event_count, 0)               AS review_event_count,
       -- null where there has never been an event. The model uses the package
       -- age instead
       CASE WHEN l.last_event_on IS NOT NULL
            THEN (o.as_of_day - l.last_event_on)::INTEGER END
                                                       AS days_since_last_event,
       CASE WHEN coalesce(x.event_count, 0) > 0
            THEN round(x.top_contributor_share, 3) END AS top_contributor_share
  FROM mart.dim_package p
 CROSS JOIN windows w
 CROSS JOIN as_of o
  LEFT JOIN windowed x     ON x.crates_id = p.crates_id AND x.window_days = w.window_days
  LEFT JOIN contributors c ON c.crates_id = p.crates_id AND c.window_days = w.window_days
  LEFT JOIN last_event l   ON l.crates_id = p.crates_id
 WHERE p.is_current
   AND p.resolution_status = 'resolved';

-- The consumption side, over the same windows
CREATE OR REPLACE TABLE feature.download_window AS
WITH as_of AS (
    SELECT max(day) AS as_of_day FROM mart.fct_download_daily
)
SELECT d.crates_id,
       o.as_of_day                                                 AS as_of,
       sum(d.downloads) FILTER (WHERE d.day > o.as_of_day - 90)     AS downloads_90d,
       sum(d.downloads) FILTER (WHERE d.day > o.as_of_day - 180
                                  AND d.day <= o.as_of_day - 90)    AS downloads_prior_90d,
       count(DISTINCT d.day)                                        AS observed_days,
       (o.as_of_day - min(d.day))::INTEGER                          AS history_days
  FROM mart.fct_download_daily d
 CROSS JOIN as_of o
 GROUP BY 1, 2;

-- The logins end here. Everything downstream is counts and shares
DROP TABLE staging.tracked_event;
DROP TABLE staging.event;
