-- Resolve a submitted manifest to its transitive tree, ranked by risk. This is
-- the query behind the main screen and the one the latency budget applies to.
--
--   psql -v manifest="{tiny-config@0.3.1}" -f db/queries/01_resolve_tree.sql
--
-- Version selection takes the newest version that is not yanked. A real
-- resolver respects the requirement on the edge, which the schema stores.

WITH RECURSIVE submitted(package_name, package_version) AS (
    SELECT split_part(entry, '@', 1), split_part(entry, '@', 2)
      FROM unnest(:'manifest'::text[]) AS entry
),
tree(package_id, package_name, package_version, depth, path) AS (
        SELECT p.id, p.name, v.version, 0, ARRAY[p.name]
          FROM submitted s
          JOIN dephealth.package p         ON p.name = s.package_name
          JOIN dephealth.package_version v ON v.package_id = p.id
                                          AND v.version = s.package_version
    UNION ALL
        SELECT dependency.id,
               dependency.name,
               newest.version,
               t.depth + 1,
               t.path || dependency.name
          FROM tree t
          JOIN dephealth.package_version pv
                ON pv.package_id = t.package_id AND pv.version = t.package_version
          JOIN dephealth.package_dependency pd
                ON pd.dependent_version_id = pv.id
               AND pd.kind <> 'dev'
          JOIN dephealth.package dependency
                ON dependency.id = pd.dependency_package_id
          LEFT JOIN LATERAL (
                SELECT version
                  FROM dephealth.package_version
                 WHERE package_id = pd.dependency_package_id
                   AND NOT yanked
                 ORDER BY published_at DESC NULLS LAST
                 LIMIT 1
          ) newest ON true
         WHERE NOT dependency.name = ANY (t.path)
           AND t.depth < 32
),
-- Reported once, at the shallowest depth it was reached by, which is the one
-- the submitter can act on
reached AS (
    SELECT DISTINCT ON (package_id)
           package_id, package_name, package_version, depth
      FROM tree
     ORDER BY package_id, depth
)
SELECT row_number() OVER (
           ORDER BY a.is_resolved DESC,
                    a.risk_probability DESC NULLS LAST,
                    r.package_name
       )                                        AS ordinal,
       r.package_name,
       r.package_version,
       r.depth,
       r.depth = 0                              AS is_direct,
       a.is_resolved,
       a.risk_probability,
       a.risk_horizon_days,
       a.forecast_point_downloads,
       a.forecast_horizon_months,
       a.insufficient_history,
       a.distinct_contributors,
       a.contributor_count_withheld,
       a.days_since_last_event,
       a.is_abandoned,
       a.resolution_label,
       a.resolution_remedy,
       a.registry_data_as_of,
       a.events_data_as_of,
       -- share of the tree at or above this row's risk
       round((100.0 * cume_dist() OVER (ORDER BY a.risk_probability DESC NULLS LAST))::numeric, 1)
                                                AS percentile_of_tree
  FROM reached r
  JOIN dephealth.v_package_assessment a ON a.package_name = r.package_name
 ORDER BY ordinal;
