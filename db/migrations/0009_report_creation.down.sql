-- 0009 report creation, reverted

DROP FUNCTION IF EXISTS dephealth.previous_report_of(bytea);
DROP FUNCTION IF EXISTS dephealth.create_report(text, text, jsonb);

-- v_report_entry as 0005 defined it. A replacement cannot drop a column, so the
-- view is dropped and rebuilt, and its grants with it
DROP VIEW IF EXISTS dephealth.v_report_entry;

CREATE VIEW dephealth.v_report_entry AS
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
       e.days_since_last_event
  FROM dephealth.report_entry e
  LEFT JOIN dephealth.resolution_outcome o ON o.status = e.unresolved_reason;

COMMENT ON VIEW dephealth.v_report_entry IS
    'The lines of a stored report. The disclosure threshold applies here too, so a report is not a route by which a withheld count is published.';

GRANT SELECT ON dephealth.v_report_entry TO dephealth_app, dephealth_public_read;

-- The two enum values stay. PostgreSQL cannot remove a value from an enumerated
-- type, and recreating the type would mean altering every column that uses it,
-- the reference table among them, so the reverse path leaves the type wider
-- than it found it and the rest of the schema identical. No row depends on the
-- values, since the reference rows for them live in db/seed/reference.sql
