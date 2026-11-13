-- Return a stored report from the token in its permanent link. The three UC2
-- outcomes are all reachable here, live, withdrawn, and never existed.
--
--   psql -v token=d225fa755e5477805d29aeecb7198387ea0364c8082f63f6968adfed890eb503 \
--        -f db/queries/03_report_by_link.sql

\echo '-- header'
SELECT created_at::date          AS assessed_on,
       crates_data_as_of,
       events_data_as_of,
       abandonment_window_days,
       risk_model_name || ' ' || risk_model_version         AS risk_model,
       forecast_model_name || ' ' || forecast_model_version AS forecast_model,
       entry_count,
       resolved_count,
       unresolved_count,
       is_withdrawn,
       withdrawn_at::date,
       withdrawal_reason
  FROM dephealth.v_report
 WHERE token_digest = dephealth.report_token_digest(:'token');

\echo '-- lines, as they stood when the report was generated'
SELECT e.ordinal,
       e.package_name,
       e.package_version,
       CASE WHEN e.is_direct THEN 'direct' ELSE 'indirect' END AS relation,
       e.risk_probability,
       e.forecast_point_downloads,
       e.insufficient_history,
       e.distinct_contributors,
       e.days_since_last_event,
       e.unresolved_label
  FROM dephealth.v_report_entry e
  JOIN dephealth.v_report r ON r.id = e.report_id
 WHERE r.token_digest = dephealth.report_token_digest(:'token')
 ORDER BY e.ordinal;
