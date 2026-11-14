-- Layer 3, mart. Two facts, downloads and activity, sharing the package and
-- date dimensions. No account login reaches this layer.

CREATE SCHEMA IF NOT EXISTS mart;

-- Dimensions

CREATE OR REPLACE TABLE mart.dim_date AS
SELECT d::DATE                                    AS day,
       extract(year FROM d)                       AS year,
       extract(month FROM d)                      AS month,
       extract(isodow FROM d)                     AS iso_weekday,
       extract(isodow FROM d) IN (6, 7)           AS is_weekend
  FROM generate_series(DATE '2014-01-01', current_date, INTERVAL 1 DAY) AS g(d);

-- Slowly changing, type 2. A package whose declared repository changes gets a
-- new row and the old one is closed, so a score computed last year can still
-- be read against the repository it was computed from. This is the only table
-- in the tier that carries state between runs
CREATE TABLE IF NOT EXISTS mart.dim_package (
    crates_id         BIGINT  NOT NULL,
    package_name      VARCHAR NOT NULL,
    created_on        DATE,
    resolution_status VARCHAR NOT NULL,
    repository_host   VARCHAR,
    repository_owner  VARCHAR,
    repository_name   VARCHAR,
    valid_from        DATE    NOT NULL,
    valid_to          DATE    NOT NULL,
    is_current        BOOLEAN NOT NULL
);

CREATE OR REPLACE TEMP TABLE dim_package_incoming AS
SELECT p.crates_id,
       p.name       AS package_name,
       p.created_on,
       r.resolution_status,
       r.host       AS repository_host,
       r.repo_owner AS repository_owner,
       r.repo_name  AS repository_name
  FROM staging.package p
  JOIN staging.package_resolution r USING (crates_id);

-- Close the current row of anything whose tracked attributes moved
UPDATE mart.dim_package
   -- greatest, so a second run on the same day cannot close a row before it
   -- opened
   SET valid_to   = greatest(valid_from, current_date - 1),
       is_current = false
 WHERE is_current
   AND crates_id IN (
        SELECT i.crates_id
          FROM dim_package_incoming i
          JOIN mart.dim_package d
            ON d.crates_id = i.crates_id
           AND d.is_current
         WHERE d.resolution_status IS DISTINCT FROM i.resolution_status
            OR d.repository_host   IS DISTINCT FROM i.repository_host
            OR d.repository_owner  IS DISTINCT FROM i.repository_owner
            OR d.repository_name   IS DISTINCT FROM i.repository_name
   );

-- Insert the new packages and the new version of the changed ones
INSERT INTO mart.dim_package
SELECT i.crates_id,
       i.package_name,
       i.created_on,
       i.resolution_status,
       i.repository_host,
       i.repository_owner,
       i.repository_name,
       current_date,
       DATE '9999-12-31',
       true
  FROM dim_package_incoming i
 WHERE NOT EXISTS (
        SELECT 1
          FROM mart.dim_package d
         WHERE d.crates_id = i.crates_id
           AND d.is_current
   );

CREATE OR REPLACE TABLE mart.dim_repository AS
SELECT DISTINCT
       host                                       AS repository_host,
       repo_owner                                 AS repository_owner,
       repo_name                                  AS repository_name
  FROM staging.package_resolution
 WHERE resolution_status = 'resolved';

-- Facts

CREATE OR REPLACE TABLE mart.fct_download_daily AS
SELECT crates_id,
       day,
       downloads
  FROM staging.download_daily;

CREATE OR REPLACE TABLE mart.fct_activity_daily AS
SELECT crates_id,
       day,
       count(*)                                                      AS event_count,
       count(DISTINCT actor_login)                                   AS distinct_contributors,
       count(*) FILTER (WHERE type = 'PushEvent')                    AS commit_event_count,
       count(*) FILTER (WHERE type = 'IssuesEvent')                  AS issue_event_count,
       count(*) FILTER (WHERE type IN ('PullRequestEvent',
                                       'PullRequestReviewEvent'))    AS review_event_count,
       -- a share, not an account. The login is counted and goes no further
       max(per_actor.events)::DOUBLE / count(*)                      AS top_contributor_share
  FROM staging.tracked_event e
  JOIN (
        SELECT crates_id, day, actor_login, count(*) AS events
          FROM staging.tracked_event
         GROUP BY 1, 2, 3
  ) per_actor USING (crates_id, day, actor_login)
 GROUP BY 1, 2;
