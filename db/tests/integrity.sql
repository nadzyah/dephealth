-- Integrity tests. Each block attempts something the schema should refuse and
-- fails the run if it succeeds. Needs the seed data loaded.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/integrity.sql

\set ON_ERROR_STOP on
\timing off
SET client_min_messages = notice;

-- 1. A line of a stored report may not be edited.
DO $$
BEGIN
    BEGIN
        UPDATE dephealth.report_entry SET risk_probability = 0.1 WHERE ordinal = 1;
        RAISE EXCEPTION 'report_entry accepted an update' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN restrict_violation THEN
        RAISE NOTICE 'pass: a line of a stored report may not be edited';
    END;
END;
$$;

-- 2. A line of a stored report may not be removed.
DO $$
BEGIN
    BEGIN
        DELETE FROM dephealth.report_entry WHERE ordinal = 5;
        RAISE EXCEPTION 'report_entry accepted a delete' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN restrict_violation THEN
        RAISE NOTICE 'pass: a line of a stored report may not be removed';
    END;
END;
$$;

-- 3. A report may not be deleted, because an audit has to tell a withdrawn
--    report from one that never existed.
DO $$
BEGIN
    BEGIN
        DELETE FROM dephealth.report WHERE id = (SELECT min(id) FROM dephealth.report);
        RAISE EXCEPTION 'report accepted a delete' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN restrict_violation THEN
        RAISE NOTICE 'pass: a stored report may not be deleted';
    END;
END;
$$;

-- 4. A report may not be edited except to withdraw it.
DO $$
BEGIN
    BEGIN
        UPDATE dephealth.report SET entry_count = 99
         WHERE id = (SELECT min(id) FROM dephealth.report);
        RAISE EXCEPTION 'report accepted an edit' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN restrict_violation THEN
        RAISE NOTICE 'pass: a stored report is immutable apart from withdrawal';
    END;
END;
$$;

-- 5. A withdrawn report may not be reinstated.
DO $$
BEGIN
    BEGIN
        UPDATE dephealth.report
           SET withdrawn_at = NULL, withdrawal_reason = NULL
         WHERE withdrawn_at IS NOT NULL;
        RAISE EXCEPTION 'withdrawal was reversed' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN restrict_violation THEN
        RAISE NOTICE 'pass: a withdrawn report may not be reinstated';
    END;
END;
$$;

-- 6. The header counts of a report must agree with its lines. Checked at
--    commit, so the test forces the deferred constraint to fire early.
DO $$
DECLARE
    new_report_id bigint;
BEGIN
    BEGIN
        INSERT INTO dephealth.report
            (token_digest, crates_data_as_of, events_data_as_of,
             abandonment_window_days, risk_model_id, forecast_model_id,
             entry_count, resolved_count)
        VALUES (
            dephealth.report_token_digest('integrity-test-token'),
            current_date - 1, current_date - 1,
            dephealth.abandonment_window_days(),
            (SELECT id FROM dephealth.model WHERE kind = 'maintenance_risk'  AND is_current),
            (SELECT id FROM dephealth.model WHERE kind = 'adoption_forecast' AND is_current),
            4, 4)
        RETURNING id INTO new_report_id;

        INSERT INTO dephealth.report_entry
            (report_id, ordinal, package_name, package_version, depth, is_direct,
             package_id, resolved, risk_probability, risk_horizon_days)
        VALUES (new_report_id, 1, 'serde', '1.0.228', 0, true,
                (SELECT id FROM dephealth.package WHERE name = 'serde'), true, 0.0310, 365);

        SET CONSTRAINTS ALL IMMEDIATE;

        RAISE EXCEPTION 'a report declaring four lines was accepted with one'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN integrity_constraint_violation THEN
        RAISE NOTICE 'pass: a report must hold as many lines as it declares';
    END;
END;
$$;

-- 7. A package cannot be resolved without a repository.
DO $$
BEGIN
    BEGIN
        INSERT INTO dephealth.package
            (name, resolution_status, first_seen_run_id)
        VALUES ('integrity-test-crate', 'resolved',
                (SELECT min(id) FROM dephealth.ingestion_run));
        RAISE EXCEPTION 'a resolved package was accepted with no repository'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'pass: resolution requires a repository, a method and a date';
    END;
END;
$$;

-- 8. A forecast cannot be produced from less than twelve months of history.
DO $$
BEGIN
    BEGIN
        INSERT INTO dephealth.adoption_forecast
            (package_id, model_id, run_id, as_of, horizon_months,
             point_downloads, history_days, insufficient_history)
        VALUES (
            (SELECT id FROM dephealth.package WHERE name = 'tiny-config'),
            (SELECT id FROM dephealth.model WHERE kind = 'adoption_forecast' AND is_current),
            (SELECT min(id) FROM dephealth.ingestion_run),
            current_date - 2, 12, 900.00, 200, false);
        RAISE EXCEPTION 'a forecast was accepted on 200 days of history'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'pass: a forecast requires twelve months of history';
    END;
END;
$$;

-- 9. A window with events must name how many accounts produced them.
DO $$
BEGIN
    BEGIN
        INSERT INTO dephealth.activity_feature
            (package_id, as_of, window_days, distinct_contributors, event_count,
             commit_event_count, issue_event_count, review_event_count,
             days_since_last_event, top_contributor_share, run_id)
        VALUES (
            (SELECT id FROM dephealth.package WHERE name = 'serde'),
            current_date - 2, 90, 0, 400, 200, 150, 50, 1, 0.3,
            (SELECT min(id) FROM dephealth.ingestion_run));
        RAISE EXCEPTION 'activity with no contributors was accepted'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'pass: events and contributors cannot disagree';
    END;
END;
$$;

-- 10. A run that is not in flight cannot be closed.
DO $$
DECLARE
    finished_run_id bigint;
BEGIN
    SELECT min(id) INTO finished_run_id FROM dephealth.ingestion_run;
    BEGIN
        CALL dephealth.finish_ingestion_run(finished_run_id, 'succeeded', current_date - 1);
        RAISE EXCEPTION 'a finished run was closed twice' USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN no_data_found THEN
        RAISE NOTICE 'pass: only a run in flight can be closed';
    END;
END;
$$;

-- 11. The disclosure threshold holds on the published view. solo-crate has two
--     contributors, so neither the count nor the concentration of effort may
--     appear, while tokio has forty and both appear.
DO $$
DECLARE
    withheld   record;
    disclosed  record;
BEGIN
    SELECT distinct_contributors, top_contributor_share, contributor_count_withheld
      INTO withheld
      FROM dephealth.v_package_assessment WHERE package_name = 'solo-crate';

    IF withheld.distinct_contributors IS NOT NULL
       OR withheld.top_contributor_share IS NOT NULL
       OR NOT withheld.contributor_count_withheld THEN
        RAISE EXCEPTION 'a contributor count below the threshold was published'
            USING ERRCODE = 'assert_failure';
    END IF;

    SELECT distinct_contributors, top_contributor_share, contributor_count_withheld
      INTO disclosed
      FROM dephealth.v_package_assessment WHERE package_name = 'tokio';

    IF disclosed.distinct_contributors IS NULL
       OR disclosed.top_contributor_share IS NULL
       OR disclosed.contributor_count_withheld THEN
        RAISE EXCEPTION 'a contributor count above the threshold was withheld'
            USING ERRCODE = 'assert_failure';
    END IF;

    RAISE NOTICE 'pass: the disclosure threshold is applied on the published view';
END;
$$;

-- 12. The application role cannot reach the contributor counts directly, and
--     the public role cannot write anywhere.
DO $$
BEGIN
    BEGIN
        SET LOCAL ROLE dephealth_app;
        PERFORM count(*) FROM dephealth.activity_feature;
        RESET ROLE;
        RAISE EXCEPTION 'the application read the contributor counts directly'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'pass: only ingestion and the administrator may read the contributor counts';
    END;
END;
$$;

RESET ROLE;

-- 13. The public role can select the whole projection of every view it is
--     granted, functions included.
--
--     Three things make this test easy to get wrong. A count does not evaluate
--     the projection, so the functions are never called. An empty table does
--     not either. And inside a plpgsql block SET ROLE changes current_user
--     without enforcing function privileges, so this has to be plain
--     statements against seeded data, and ON_ERROR_STOP has to be on.
SET ROLE dephealth_public_read;
\o /dev/null
SELECT package_name,
       distinct_contributors,
       top_contributor_share,
       contributor_count_withheld,
       is_abandoned,
       resolution_remedy
  FROM dephealth.v_package_assessment;
SELECT package_name, day, downloads
  FROM dephealth.v_download_series;
SELECT report_id, ordinal, distinct_contributors, unresolved_remedy
  FROM dephealth.v_report_entry;
SELECT source, age_days FROM dephealth.v_data_age;
\o
RESET ROLE;
\echo 'pass: the public role can read every view it is granted, in full'

-- 14. A stored report does not follow the live score. The whole block is rolled
--     back, so the change to the live row leaves no trace.
BEGIN;

SELECT dephealth.create_report(
    'integrity0000000000000000000000000000000000000000000000000014',
    'integrity-test-salt',
    '[{"name":"serde","version":"1.0.228","depth":0}]'::jsonb
) AS created \gset

UPDATE dephealth.maintenance_risk
   SET probability = 0.9990
 WHERE package_id = (SELECT id FROM dephealth.package WHERE name = 'serde')
   AND model_id = (SELECT id FROM dephealth.model
                    WHERE kind = 'maintenance_risk' AND is_current);

REFRESH MATERIALIZED VIEW dephealth.mv_package_current_assessment;

DO $$
DECLARE
    reported numeric;
    live     numeric;
BEGIN
    SELECT e.risk_probability INTO reported
      FROM dephealth.v_report_entry e
      JOIN dephealth.v_report r ON r.id = e.report_id
     WHERE r.token_digest = dephealth.report_token_digest(
               'integrity0000000000000000000000000000000000000000000000000014')
       AND e.package_name = 'serde';

    SELECT risk_probability INTO live
      FROM dephealth.v_package_assessment WHERE package_name = 'serde';

    IF live <> 0.9990 THEN
        RAISE EXCEPTION 'the live score did not change, so the test proves nothing'
            USING ERRCODE = 'assert_failure';
    END IF;

    IF reported = live THEN
        RAISE EXCEPTION 'the stored report followed the live score'
            USING ERRCODE = 'assert_failure';
    END IF;

    RAISE NOTICE 'pass: a stored report holds the figures of the day it was generated';
END;
$$;

ROLLBACK;

-- 15. Report creation refuses a manifest it cannot store, rather than storing
--     an empty report.
DO $$
BEGIN
    BEGIN
        PERFORM dephealth.create_report(
            'integrity0000000000000000000000000000000000000000000000000015',
            'integrity-test-salt',
            '[]'::jsonb);
        RAISE EXCEPTION 'an empty manifest was accepted'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN invalid_parameter_value THEN
        RAISE NOTICE 'pass: a report needs at least one entry';
    END;

    BEGIN
        PERFORM dephealth.create_report(
            'short',
            'integrity-test-salt',
            '[{"name":"serde","version":"1.0.228","depth":0}]'::jsonb);
        RAISE EXCEPTION 'a guessable link token was accepted'
            USING ERRCODE = 'assert_failure';
    EXCEPTION WHEN invalid_parameter_value THEN
        RAISE NOTICE 'pass: a link token below the minimum length is refused';
    END;
END;
$$;

\echo 'all integrity tests passed'
