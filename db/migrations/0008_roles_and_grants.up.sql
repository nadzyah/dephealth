-- 0008 roles and privileges

-- Login roles are created outside the migrations, since they carry passwords.
-- See db/roles/README.md

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dephealth_admin') THEN
        CREATE ROLE dephealth_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dephealth_ingest') THEN
        CREATE ROLE dephealth_ingest NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dephealth_app') THEN
        CREATE ROLE dephealth_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dephealth_public_read') THEN
        CREATE ROLE dephealth_public_read NOLOGIN;
    END IF;
END;
$$;

COMMENT ON ROLE dephealth_admin IS 'Schema owner and maintenance. Not a superuser.';
COMMENT ON ROLE dephealth_ingest IS 'Scheduled ingestion and scoring. The only role besides the administrator that may read the contributor counts.';
COMMENT ON ROLE dephealth_app IS 'Web application. Reads through views, writes reports, deletes nothing.';
COMMENT ON ROLE dephealth_public_read IS 'Public read-only API. Five views, no write privilege anywhere.';

-- Nothing is granted to everybody

REVOKE ALL ON SCHEMA dephealth FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA dephealth FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dephealth FROM PUBLIC;
REVOKE ALL ON ALL PROCEDURES IN SCHEMA dephealth FROM PUBLIC;

GRANT USAGE ON SCHEMA dephealth TO
    dephealth_admin, dephealth_ingest, dephealth_app, dephealth_public_read;

-- Administrator

GRANT ALL ON ALL TABLES IN SCHEMA dephealth TO dephealth_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA dephealth TO dephealth_admin;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA dephealth TO dephealth_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA dephealth TO dephealth_admin;

-- No blanket defaults for the other three. A new object is granted in the
-- migration that creates it, and db/checks/privileges.sql finds omissions
ALTER DEFAULT PRIVILEGES IN SCHEMA dephealth GRANT ALL ON TABLES TO dephealth_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA dephealth GRANT ALL ON SEQUENCES TO dephealth_admin;

-- Ingestion

GRANT SELECT ON
    dephealth.resolution_outcome,
    dephealth.feature_window,
    dephealth.metric_definition,
    dephealth.risk_factor_catalogue
    TO dephealth_ingest;

-- No DELETE. A bad run is corrected by loading over it or by dropping a
-- partition
GRANT SELECT, INSERT, UPDATE ON
    dephealth.ingestion_run,
    dephealth.repository,
    dephealth.package,
    dephealth.package_version,
    dephealth.package_dependency,
    dephealth.download_daily,
    dephealth.activity_feature,
    dephealth.model,
    dephealth.model_metric,
    dephealth.adoption_forecast,
    dephealth.maintenance_risk,
    dephealth.risk_factor
    TO dephealth_ingest;

GRANT SELECT ON
    dephealth.v_data_age,
    dephealth.v_data_quality_finding,
    dephealth.v_kpi1_resolution,
    dephealth.v_kpi1_resolution_by_reason,
    dephealth.v_model_against_baseline
    TO dephealth_ingest;

GRANT EXECUTE ON FUNCTION
    dephealth.start_ingestion_run(dephealth.data_source),
    dephealth.k_anonymity_threshold(),
    dephealth.abandonment_window_days(),
    dephealth.is_abandoned(integer),
    dephealth.disclosed_contributors(integer)
    TO dephealth_ingest;

GRANT EXECUTE ON PROCEDURE
    dephealth.finish_ingestion_run(bigint, dephealth.run_status, date, bigint, bigint, bigint, text)
    TO dephealth_ingest;

-- Web application

GRANT SELECT ON
    dephealth.package,
    dephealth.package_version,
    dephealth.package_dependency,
    dephealth.repository,
    dephealth.resolution_outcome,
    dephealth.feature_window,
    dephealth.metric_definition,
    dephealth.risk_factor_catalogue
    TO dephealth_app;

-- No privilege on activity_feature or on the materialised view. The
-- application reads them only through these
GRANT SELECT ON
    dephealth.v_package_assessment,
    dephealth.v_download_series,
    dephealth.v_data_age,
    dephealth.v_report,
    dephealth.v_report_entry
    TO dephealth_app;

GRANT INSERT ON
    dephealth.report,
    dephealth.report_entry,
    dephealth.report_entry_factor
    TO dephealth_app;

GRANT SELECT ON dephealth.report, dephealth.report_entry, dephealth.report_entry_factor
    TO dephealth_app;

GRANT USAGE ON SEQUENCE dephealth.report_id_seq TO dephealth_app;

-- Column level. Withdrawal is the only field of a stored report that changes
GRANT UPDATE (withdrawn_at, withdrawal_reason) ON dephealth.report TO dephealth_app;

-- The views call these in their projections, and function privileges are
-- checked against the calling role rather than the view owner, so a role that
-- may read a view also needs EXECUTE on the functions inside it
GRANT EXECUTE ON FUNCTION
    dephealth.report_token_digest(text),
    dephealth.manifest_fingerprint(text[], text),
    dephealth.k_anonymity_threshold(),
    dephealth.abandonment_window_days(),
    dephealth.is_abandoned(integer),
    dephealth.disclosed_contributors(integer),
    dephealth.disclosed_share(numeric, integer)
    TO dephealth_app;

GRANT EXECUTE ON PROCEDURE dephealth.withdraw_report(bytea, text) TO dephealth_app;

-- Public read-only API

GRANT SELECT ON
    dephealth.v_package_assessment,
    dephealth.v_download_series,
    dephealth.v_data_age,
    dephealth.v_report,
    dephealth.v_report_entry
    TO dephealth_public_read;

GRANT EXECUTE ON FUNCTION
    dephealth.report_token_digest(text),
    dephealth.k_anonymity_threshold(),
    dephealth.abandonment_window_days(),
    dephealth.is_abandoned(integer),
    dephealth.disclosed_contributors(integer),
    dephealth.disclosed_share(numeric, integer)
    TO dephealth_public_read;
