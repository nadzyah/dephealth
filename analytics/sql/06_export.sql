-- Export to CSV for db/load/load_features.sql. A file between the tiers means
-- a failed load can be retried without recomputing the features.

COPY (
    SELECT p.package_name,
           f.as_of,
           f.window_days,
           f.distinct_contributors,
           f.event_count,
           f.commit_event_count,
           f.issue_event_count,
           f.review_event_count,
           f.days_since_last_event,
           f.top_contributor_share
      FROM feature.activity_window f
      JOIN mart.dim_package p USING (crates_id)
     WHERE p.is_current
) TO 'data/out/activity_feature.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT p.package_name,
           d.day,
           d.downloads
      FROM mart.fct_download_daily d
      JOIN mart.dim_package p USING (crates_id)
     WHERE p.is_current
       AND d.day > current_date - 1100
) TO 'data/out/download_daily.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT p.package_name,
           p.created_on,
           p.resolution_status,
           p.repository_host,
           p.repository_owner,
           p.repository_name
      FROM mart.dim_package p
     WHERE p.is_current
) TO 'data/out/package.csv' (HEADER, DELIMITER ',');

COPY (
    SELECT p.package_name,
           v.version,
           v.published_at,
           v.yanked
      FROM staging.package_version v
      JOIN mart.dim_package p USING (crates_id)
     WHERE p.is_current
) TO 'data/out/package_version.csv' (HEADER, DELIMITER ',');

-- The edges the tree resolution walks. Exported by name and version rather
-- than by registry id, because the serving database assigns its own
COPY (
    SELECT dependent.package_name  AS dependent_name,
           v.version               AS dependent_version,
           dependency.package_name AS dependency_name,
           d.kind,
           d.requirement,
           d.optional
      FROM staging.dependency d
      JOIN staging.package_version v
        ON v.crates_version_id = d.dependent_version_id
      JOIN mart.dim_package dependent
        ON dependent.crates_id = v.crates_id AND dependent.is_current
      JOIN mart.dim_package dependency
        ON dependency.crates_id = d.dependency_crates_id AND dependency.is_current
) TO 'data/out/package_dependency.csv' (HEADER, DELIMITER ',');
