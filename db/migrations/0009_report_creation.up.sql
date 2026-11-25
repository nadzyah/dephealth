-- 0009 report creation

-- Three outcomes the earlier enum could not express, all of them reachable
-- from a submitted manifest rather than from ingestion. An entry may name a
-- package the registry snapshot does not contain, it may not come from the
-- registry at all, a path or git dependency being the common case, and it may
-- be a package the next scoring run has not reached yet
ALTER TYPE dephealth.resolution_status ADD VALUE IF NOT EXISTS 'absent_from_snapshot';
ALTER TYPE dephealth.resolution_status ADD VALUE IF NOT EXISTS 'not_a_registry_package';
ALTER TYPE dephealth.resolution_status ADD VALUE IF NOT EXISTS 'awaiting_first_score';

-- The application may read neither the model table, nor the live scores, nor
-- the factor decomposition, so a stored report is assembled here from the
-- parsed manifest alone. One statement from the caller, one transaction, and
-- the ordinal it writes is the rank the tree is displayed in
CREATE FUNCTION dephealth.create_report(
    in_token   text,
    in_salt    text,
    in_entries jsonb
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = dephealth, pg_temp
AS $$
DECLARE
    new_id         bigint;
    risk_model     bigint;
    forecast_model bigint;
    crates_as_of   date;
    events_as_of   date;
    fingerprint    bytea;
    submitted      text[];
BEGIN
    IF in_token IS NULL OR length(in_token) < 32 THEN
        RAISE EXCEPTION 'the link token must be at least 32 characters'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF in_entries IS NULL OR jsonb_typeof(in_entries) <> 'array' THEN
        RAISE EXCEPTION 'the entries must be a JSON array'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT array_agg(e.name || '@' || e.version ORDER BY e.name, e.version)
      INTO submitted
      FROM jsonb_to_recordset(in_entries)
           AS e(name text, version text, depth integer);

    IF submitted IS NULL THEN
        RAISE EXCEPTION 'a report needs at least one entry'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT id INTO risk_model
      FROM dephealth.model
     WHERE kind = 'maintenance_risk' AND is_current;

    SELECT id INTO forecast_model
      FROM dephealth.model
     WHERE kind = 'adoption_forecast' AND is_current;

    IF risk_model IS NULL OR forecast_model IS NULL THEN
        RAISE EXCEPTION 'no current model, so no assessment may be reported'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    SELECT max(data_as_of) FILTER (WHERE source = 'crates_io_dump'),
           max(data_as_of) FILTER (WHERE source = 'gh_archive')
      INTO crates_as_of, events_as_of
      FROM dephealth.v_data_age;

    IF crates_as_of IS NULL OR events_as_of IS NULL THEN
        RAISE EXCEPTION 'no completed ingestion run, so there is nothing to report'
            USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    fingerprint := dephealth.manifest_fingerprint(submitted, in_salt);

    -- The report row and its entries in one statement, since a stored report is
    -- immutable from the moment it exists and its counts cannot be corrected
    -- afterwards
    WITH submitted AS (
        -- One line per package, at the shallowest depth it was reached by,
        -- which is the one the submitter can act on
        SELECT DISTINCT ON (lower(e.name))
               e.name,
               e.version,
               e.depth,
               coalesce(e.from_registry, true) AS from_registry
          FROM jsonb_to_recordset(in_entries)
               AS e(name text, version text, depth integer, from_registry boolean)
         ORDER BY lower(e.name), e.depth
    ), matched AS (
        -- An entry counts as reported only with a score behind it, so a package
        -- resolved to a repository but not yet scored is grouped with the
        -- unresolved ones and keeps its own reason. An entry that does not come
        -- from the registry is never matched by name, since a local crate may
        -- share the name of a published one
        SELECT s.name,
               s.version,
               s.depth,
               s.from_registry,
               a.package_id,
               a.resolution_status,
               a.risk_probability,
               a.risk_horizon_days,
               a.forecast_point_downloads,
               a.forecast_horizon_months,
               a.insufficient_history,
               a.distinct_contributors,
               a.days_since_last_event,
               s.from_registry AND a.risk_probability IS NOT NULL AS resolved
          FROM submitted s
          LEFT JOIN dephealth.mv_package_current_assessment a
                 ON s.from_registry
                AND lower(a.package_name) = lower(s.name)
    ), line AS (
        SELECT row_number() OVER (
                   ORDER BY m.resolved DESC,
                            m.risk_probability DESC NULLS LAST,
                            m.name
               )::integer      AS ordinal,
               m.name           AS package_name,
               m.version        AS package_version,
               m.depth,
               m.depth = 0      AS is_direct,
               CASE WHEN m.resolved THEN m.package_id END AS package_id,
               m.resolved,
               CASE
                   WHEN m.resolved              THEN NULL
                   WHEN NOT m.from_registry     THEN 'not_a_registry_package'
                   WHEN m.package_id IS NULL    THEN 'absent_from_snapshot'
                   WHEN m.resolution_status = 'resolved' THEN 'awaiting_first_score'
                   ELSE m.resolution_status::text
               END              AS unresolved_reason,
               CASE WHEN m.resolved THEN m.risk_probability END AS risk_probability,
               CASE WHEN m.resolved THEN m.risk_horizon_days END AS risk_horizon_days,
               CASE WHEN m.resolved THEN m.forecast_point_downloads END
                                AS forecast_point_downloads,
               CASE WHEN m.resolved THEN m.forecast_horizon_months END
                                AS forecast_horizon_months,
               CASE WHEN m.resolved THEN coalesce(m.insufficient_history, true)
                    ELSE true END AS insufficient_history,
               CASE WHEN m.resolved
                    THEN dephealth.disclosed_contributors(m.distinct_contributors)
               END              AS distinct_contributors,
               CASE WHEN m.resolved THEN m.days_since_last_event END
                                AS days_since_last_event
          FROM matched m
    ), stored AS (
        INSERT INTO dephealth.report
            (token_digest, manifest_fingerprint, crates_data_as_of,
             events_data_as_of, abandonment_window_days, risk_model_id,
             forecast_model_id, entry_count, resolved_count)
        SELECT dephealth.report_token_digest(in_token), fingerprint,
               crates_as_of, events_as_of,
               dephealth.abandonment_window_days(), risk_model, forecast_model,
               (SELECT count(*) FROM line),
               (SELECT count(*) FROM line WHERE resolved)
        RETURNING id
    )
    INSERT INTO dephealth.report_entry
        (report_id, ordinal, package_name, package_version, depth, is_direct,
         package_id, resolved, unresolved_reason,
         risk_probability, risk_horizon_days,
         forecast_point_downloads, forecast_horizon_months, insufficient_history,
         distinct_contributors, days_since_last_event)
    SELECT stored.id, l.ordinal, l.package_name, l.package_version, l.depth,
           l.is_direct, l.package_id, l.resolved,
           l.unresolved_reason::dephealth.resolution_status,
           l.risk_probability, l.risk_horizon_days,
           l.forecast_point_downloads, l.forecast_horizon_months,
           l.insufficient_history, l.distinct_contributors,
           l.days_since_last_event
      FROM line l CROSS JOIN stored;

    SELECT id INTO new_id
      FROM dephealth.report
     WHERE token_digest = dephealth.report_token_digest(in_token);

    INSERT INTO dephealth.report_entry_factor
        (report_id, ordinal, factor, observed_value, contribution)
    SELECT e.report_id, e.ordinal, f.factor, f.observed_value, f.contribution
      FROM dephealth.report_entry e
      JOIN dephealth.mv_package_current_assessment a
            ON a.package_id = e.package_id
      JOIN dephealth.risk_factor f
            ON f.maintenance_risk_id = a.maintenance_risk_id
     WHERE e.report_id = new_id AND e.resolved;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION dephealth.create_report(text, text, jsonb) IS
    'Store one assessment of a submitted manifest. Definer rights, because the caller may not read the models, the live scores or the factor decomposition that the snapshot is taken from. The token is hashed here and never stored.';

REVOKE ALL ON FUNCTION dephealth.create_report(text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION dephealth.create_report(text, text, jsonb) TO dephealth_app;

-- Two columns the published view did not carry. A client needs the reason code
-- to branch on, the label being prose, and it needs to know that a contributor
-- count was withheld rather than absent, which v_package_assessment already
-- reports for the live figures
CREATE OR REPLACE VIEW dephealth.v_report_entry AS
SELECT e.report_id,
       e.ordinal,
       e.package_name,
       e.package_version,
       e.depth,
       e.is_direct,
       e.resolved,
       o.label  AS unresolved_label,
       o.remedy AS unresolved_remedy,
       e.risk_probability,
       e.risk_horizon_days,
       e.forecast_point_downloads,
       e.forecast_horizon_months,
       e.insufficient_history,
       dephealth.disclosed_contributors(e.distinct_contributors) AS distinct_contributors,
       e.days_since_last_event,
       e.unresolved_reason,
       (dephealth.disclosed_contributors(e.distinct_contributors) IS NULL
            AND e.distinct_contributors IS NOT NULL)
                                                 AS contributor_count_withheld
  FROM dephealth.report_entry e
  LEFT JOIN dephealth.resolution_outcome o ON o.status = e.unresolved_reason;

-- Comparing a resubmission with the assessment before it means recognising the
-- same manifest without having kept it
CREATE FUNCTION dephealth.previous_report_of(
    in_token_digest bytea
) RETURNS bytea
LANGUAGE sql
STABLE
SET search_path = dephealth, pg_temp
AS $$
    SELECT earlier.token_digest
      FROM dephealth.report current
      JOIN dephealth.report earlier
            ON earlier.manifest_fingerprint = current.manifest_fingerprint
           AND earlier.created_at < current.created_at
     WHERE current.token_digest = in_token_digest
       AND current.manifest_fingerprint IS NOT NULL
     ORDER BY earlier.created_at DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION dephealth.previous_report_of(bytea) IS
    'The digest of the report before this one for the same manifest, or nothing if this is the first. Invoker rights, since both rows are readable by whoever may read the report.';

GRANT EXECUTE ON FUNCTION dephealth.previous_report_of(bytea) TO dephealth_app;
