-- Load the features exported by the analytical tier.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v crates_run_id=42 -v events_run_id=43 \
--        -f db/load/load_features.sql
--
-- One transaction, every statement an upsert on the natural key, so a retry
-- writes the same rows rather than duplicates. Two run ids, since the sources
-- age independently and the interface reports both.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE incoming_package (
    package_name      text,
    created_on        date,
    resolution_status text,
    repository_host   text,
    repository_owner  text,
    repository_name   text
) ON COMMIT DROP;

CREATE TEMP TABLE incoming_download (
    package_name text,
    day          date,
    downloads    bigint
) ON COMMIT DROP;

CREATE TEMP TABLE incoming_activity (
    package_name          text,
    as_of                 date,
    window_days           integer,
    distinct_contributors integer,
    event_count           integer,
    commit_event_count    integer,
    issue_event_count     integer,
    review_event_count    integer,
    days_since_last_event integer,
    top_contributor_share numeric
) ON COMMIT DROP;

CREATE TEMP TABLE incoming_version (
    package_name text,
    version      text,
    published_at timestamptz,
    yanked       boolean
) ON COMMIT DROP;

CREATE TEMP TABLE incoming_dependency (
    dependent_name    text,
    dependent_version text,
    dependency_name   text,
    kind              text,
    requirement       text,
    optional          boolean
) ON COMMIT DROP;

\copy incoming_package    FROM PROGRAM 'cat "$OUT_DIR/package.csv"'            WITH (FORMAT csv, HEADER)
\copy incoming_version    FROM PROGRAM 'cat "$OUT_DIR/package_version.csv"'    WITH (FORMAT csv, HEADER)
\copy incoming_dependency FROM PROGRAM 'cat "$OUT_DIR/package_dependency.csv"' WITH (FORMAT csv, HEADER)
\copy incoming_download   FROM PROGRAM 'cat "$OUT_DIR/download_daily.csv"'     WITH (FORMAT csv, HEADER)
\copy incoming_activity   FROM PROGRAM 'cat "$OUT_DIR/activity_feature.csv"'   WITH (FORMAT csv, HEADER)

-- Repositories first, since a package resolves to one
INSERT INTO dephealth.repository (host, owner, name, canonical_url)
SELECT DISTINCT
       i.repository_host,
       i.repository_owner,
       i.repository_name,
       'https://' || i.repository_host || '/' || i.repository_owner || '/' || i.repository_name
  FROM incoming_package i
 WHERE i.resolution_status = 'resolved'
ON CONFLICT DO NOTHING;

INSERT INTO dephealth.package
    (name, created_on, repository_id, resolution_status, resolution_method,
     resolved_at, first_seen_run_id)
SELECT i.package_name,
       i.created_on,
       r.id,
       i.resolution_status::dephealth.resolution_status,
       CASE WHEN i.resolution_status = 'resolved' THEN 'declared_url'::dephealth.resolution_method END,
       CASE WHEN i.resolution_status = 'resolved' THEN now() END,
       :'crates_run_id'::bigint
  FROM incoming_package i
  LEFT JOIN dephealth.repository r
         ON r.host = i.repository_host
        AND lower(r.owner) = lower(i.repository_owner)
        AND lower(r.name) = lower(i.repository_name)
ON CONFLICT (registry, lower(name)) DO UPDATE
    SET created_on        = excluded.created_on,
        repository_id     = excluded.repository_id,
        resolution_status = excluded.resolution_status,
        resolution_method = excluded.resolution_method,
        resolved_at       = excluded.resolved_at;

INSERT INTO dephealth.package_version (package_id, version, published_at, yanked)
SELECT p.id, i.version, i.published_at, i.yanked
  FROM incoming_version i
  JOIN dephealth.package p ON p.name = i.package_name
ON CONFLICT (package_id, version) DO UPDATE
    SET published_at = excluded.published_at,
        yanked       = excluded.yanked;

INSERT INTO dephealth.package_dependency
    (dependent_version_id, dependency_package_id, kind, requirement, optional)
SELECT v.id,
       dependency.id,
       i.kind::dephealth.dependency_kind,
       i.requirement,
       i.optional
  FROM incoming_dependency i
  JOIN dephealth.package dependent
        ON dependent.name = i.dependent_name
  JOIN dephealth.package_version v
        ON v.package_id = dependent.id AND v.version = i.dependent_version
  JOIN dephealth.package dependency
        ON dependency.name = i.dependency_name
ON CONFLICT (dependent_version_id, dependency_package_id, kind) DO UPDATE
    SET requirement = excluded.requirement,
        optional    = excluded.optional;

INSERT INTO dephealth.download_daily (package_id, day, downloads, run_id)
SELECT p.id, i.day, i.downloads, :'crates_run_id'::bigint
  FROM incoming_download i
  JOIN dephealth.package p ON p.name = i.package_name
ON CONFLICT (package_id, day) DO UPDATE
    SET downloads = excluded.downloads,
        run_id    = excluded.run_id;

INSERT INTO dephealth.activity_feature
    (package_id, as_of, window_days, distinct_contributors, event_count,
     commit_event_count, issue_event_count, review_event_count,
     days_since_last_event, top_contributor_share, run_id)
SELECT p.id, i.as_of, i.window_days, i.distinct_contributors, i.event_count,
       i.commit_event_count, i.issue_event_count, i.review_event_count,
       i.days_since_last_event, i.top_contributor_share, :'events_run_id'::bigint
  FROM incoming_activity i
  JOIN dephealth.package p ON p.name = i.package_name
ON CONFLICT (package_id, as_of, window_days) DO UPDATE
    SET distinct_contributors = excluded.distinct_contributors,
        event_count           = excluded.event_count,
        commit_event_count    = excluded.commit_event_count,
        issue_event_count     = excluded.issue_event_count,
        review_event_count    = excluded.review_event_count,
        days_since_last_event = excluded.days_since_last_event,
        top_contributor_share = excluded.top_contributor_share,
        run_id                = excluded.run_id;

-- Counted before the commit, so the run record quotes the load not the files
SELECT (SELECT count(*) FROM incoming_package)    AS packages,
       (SELECT count(*) FROM incoming_version)    AS versions,
       (SELECT count(*) FROM incoming_dependency) AS dependency_edges,
       (SELECT count(*) FROM incoming_download)   AS download_days,
       (SELECT count(*) FROM incoming_activity)   AS activity_windows;

COMMIT;
