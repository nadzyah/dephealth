-- 0006 down
DROP PROCEDURE dephealth.withdraw_report(bytea, text);
DROP PROCEDURE dephealth.finish_ingestion_run(bigint, dephealth.run_status, date, bigint, bigint, bigint, text);
DROP FUNCTION dephealth.start_ingestion_run(dephealth.data_source);
DROP TRIGGER activity_feature_syncs_repository ON dephealth.activity_feature;
DROP FUNCTION dephealth.sync_repository_last_event();
DROP TRIGGER report_counts_match_entries ON dephealth.report;
DROP FUNCTION dephealth.check_report_counts();
DROP TRIGGER report_is_immutable_apart_from_withdrawal ON dephealth.report;
DROP FUNCTION dephealth.guard_report_mutation();
DROP TRIGGER report_entry_factor_is_append_only ON dephealth.report_entry_factor;
DROP TRIGGER report_entry_is_append_only ON dephealth.report_entry;
DROP FUNCTION dephealth.reject_mutation();
DROP FUNCTION dephealth.manifest_fingerprint(text[], text);
DROP FUNCTION dephealth.report_token_digest(text);
