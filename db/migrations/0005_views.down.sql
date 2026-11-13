-- 0005 down
DROP VIEW dephealth.v_model_against_baseline;
DROP VIEW dephealth.v_kpi1_resolution_by_reason;
DROP VIEW dephealth.v_kpi1_resolution;
DROP VIEW dephealth.v_report_entry;
DROP VIEW dephealth.v_report;
DROP VIEW dephealth.v_download_series;
DROP VIEW dephealth.v_package_assessment;
DROP MATERIALIZED VIEW dephealth.mv_package_current_assessment;
DROP VIEW dephealth.v_data_age;
DROP FUNCTION dephealth.disclosed_share(numeric, integer);
DROP FUNCTION dephealth.disclosed_contributors(integer);
DROP FUNCTION dephealth.is_abandoned(integer);
DROP FUNCTION dephealth.abandonment_window_days();
