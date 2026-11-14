-- Layer 2, staging. Typed, deduplicated, filtered. The two event tables here
-- are the only place in the system that holds account logins, and
-- 04_features.sql drops them once the counts are derived.

CREATE SCHEMA IF NOT EXISTS staging;

-- Registry

CREATE OR REPLACE TABLE staging.package AS
SELECT id::BIGINT                            AS crates_id,
       name,
       created_at::TIMESTAMP::DATE           AS created_on,
       nullif(trim(repository), '')           AS declared_repository_url
  FROM raw.crates
 WHERE name IS NOT NULL
   AND name SIMILAR TO '[A-Za-z0-9][A-Za-z0-9_-]*'
 QUALIFY row_number() OVER (PARTITION BY lower(name) ORDER BY id) = 1;

CREATE OR REPLACE TABLE staging.package_version AS
SELECT v.id::BIGINT                          AS crates_version_id,
       v.crate_id::BIGINT                    AS crates_id,
       v.num                                 AS version,
       v.created_at::TIMESTAMP               AS published_at,
       coalesce(v.yanked = 't', false)       AS yanked
  FROM raw.versions v
  SEMI JOIN staging.package p ON p.crates_id = v.crate_id::BIGINT
 QUALIFY row_number() OVER (PARTITION BY v.crate_id, v.num ORDER BY v.id) = 1;

-- The dump is per version, summed to the package on load
CREATE OR REPLACE TABLE staging.download_daily AS
SELECT pv.crates_id,
       d.date::DATE                          AS day,
       sum(d.downloads::BIGINT)              AS downloads
  FROM raw.version_downloads d
  JOIN staging.package_version pv
    ON pv.crates_version_id = d.version_id::BIGINT
 WHERE d.date::DATE <= current_date
 GROUP BY 1, 2;

CREATE OR REPLACE TABLE staging.dependency AS
SELECT d.version_id::BIGINT                  AS dependent_version_id,
       d.crate_id::BIGINT                    AS dependency_crates_id,
       CASE d.kind WHEN '0' THEN 'normal'
                   WHEN '1' THEN 'build'
                   WHEN '2' THEN 'dev' END   AS kind,
       d.req                                 AS requirement,
       coalesce(d.optional = 't', false)     AS optional
  FROM raw.dependencies d
 WHERE d.kind IN ('0', '1', '2')
   AND nullif(trim(d.req), '') IS NOT NULL
 QUALIFY row_number() OVER (
     PARTITION BY d.version_id, d.crate_id, d.kind ORDER BY d.id) = 1;

-- Resolution of a package to a repository, recorded for every package
-- including the failures, since KPI1 is the share that resolves

-- regexp_extract returns an empty string rather than null when it does not
-- match, so every extraction is passed through nullif. Without it a malformed
-- URL is reported as host_unsupported and url_unparseable never occurs
CREATE OR REPLACE TABLE staging.package_resolution AS
WITH parsed AS (
    SELECT p.crates_id,
           p.declared_repository_url AS url,
           nullif(lower(regexp_extract(p.declared_repository_url,
                   '^(?:https?://)?(?:www\.)?([a-z0-9.-]+)/', 1)), '')  AS host,
           nullif(regexp_extract(p.declared_repository_url,
                   '^(?:https?://)?(?:www\.)?[a-z0-9.-]+/([^/]+)/([^/#?]+)',
                   ['owner', 'name']).owner, '')                        AS repo_owner,
           nullif(regexp_extract(p.declared_repository_url,
                   '^(?:https?://)?(?:www\.)?[a-z0-9.-]+/([^/]+)/([^/#?]+)',
                   ['owner', 'name']).name, '')                         AS repo_name
      FROM staging.package p
)
SELECT crates_id,
       url,
       host,
       repo_owner,
       regexp_replace(repo_name, '\.git$', '')              AS repo_name,
       CASE
           WHEN url IS NULL                                 THEN 'no_url_declared'
           WHEN host IS NULL
             OR repo_owner IS NULL
             OR repo_name IS NULL                           THEN 'url_unparseable'
           WHEN host <> 'github.com'                        THEN 'host_unsupported'
           ELSE 'resolved'
       END                                                  AS resolution_status
  FROM parsed;

-- Events

-- Deduplicated on the event id, since the hourly files overlap at their edges
CREATE OR REPLACE TABLE staging.event AS
SELECT e.id,
       e.type,
       e.created_at::TIMESTAMP::DATE         AS day,
       e.actor_login,
       lower(split_part(e.repo_full_name, '/', 1)) AS repo_owner,
       lower(split_part(e.repo_full_name, '/', 2)) AS repo_name
  FROM raw.events e
 WHERE e.repo_full_name IS NOT NULL
   AND e.actor_login IS NOT NULL
   -- a release bot pushing daily would make an abandoned package look alive
   AND NOT (e.actor_login ILIKE '%[bot]' OR e.actor_login ILIKE '%-bot')
 QUALIFY row_number() OVER (PARTITION BY e.id ORDER BY e.created_at) = 1;

-- Discards most of the archive, which is what makes the window affordable
CREATE OR REPLACE TABLE staging.tracked_event AS
SELECT e.*, r.crates_id
  FROM staging.event e
  JOIN staging.package_resolution r
    ON r.resolution_status = 'resolved'
   AND lower(r.repo_owner) = e.repo_owner
   AND lower(r.repo_name)  = e.repo_name;
