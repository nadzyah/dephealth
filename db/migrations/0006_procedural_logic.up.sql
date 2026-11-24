-- 0006 procedural logic

-- Digests

-- A fast digest, not a password digest. The token is random, so there is no
-- small search space for a slow digest to protect
CREATE FUNCTION dephealth.report_token_digest(in_token text) RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    RETURN sha256(convert_to(in_token, 'UTF8'));

COMMENT ON FUNCTION dephealth.report_token_digest(text) IS
    'SHA-256 of a report link token. A fast digest is correct here and a password digest would not be, since the token is random.';

-- The salt comes from the application and is not stored, so a reader of the
-- report table cannot test a guessed dependency set against a fingerprint
CREATE FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text)
    RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT sha256(convert_to(
        in_salt || ':' || array_to_string(
            (SELECT array_agg(entry ORDER BY entry) FROM unnest(in_entries) AS entry),
            ','),
        'UTF8'))
$$;

COMMENT ON FUNCTION dephealth.manifest_fingerprint(text[], text) IS
    'Salted digest of the sorted name@version set of a manifest. Recognises a resubmission without retaining the manifest. The salt is held by the application, not the database.';

-- A stored report is append only

CREATE FUNCTION dephealth.reject_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION
        'relation %.% is append only',
        TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation',
              HINT = 'A filed report must return the figures it held when it was generated.';
END;
$$;

CREATE TRIGGER report_entry_is_append_only
    BEFORE UPDATE OR DELETE ON dephealth.report_entry
    FOR EACH STATEMENT EXECUTE FUNCTION dephealth.reject_mutation();

CREATE TRIGGER report_entry_factor_is_append_only
    BEFORE UPDATE OR DELETE ON dephealth.report_entry_factor
    FOR EACH STATEMENT EXECUTE FUNCTION dephealth.reject_mutation();

CREATE FUNCTION dephealth.guard_report_mutation() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'a stored report may not be deleted'
            USING ERRCODE = 'restrict_violation',
                  HINT = 'Withdraw it instead. A deleted row cannot tell an audit whether the report was removed or never existed.';
    END IF;

    IF (to_jsonb(NEW) - 'withdrawn_at' - 'withdrawal_reason')
       IS DISTINCT FROM
       (to_jsonb(OLD) - 'withdrawn_at' - 'withdrawal_reason') THEN
        RAISE EXCEPTION 'a stored report is immutable apart from withdrawal'
            USING ERRCODE = 'restrict_violation';
    END IF;

    IF OLD.withdrawn_at IS NOT NULL AND NEW.withdrawn_at IS NULL THEN
        RAISE EXCEPTION 'a withdrawn report may not be reinstated'
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER report_is_immutable_apart_from_withdrawal
    BEFORE UPDATE OR DELETE ON dephealth.report
    FOR EACH ROW EXECUTE FUNCTION dephealth.guard_report_mutation();

-- A report and its entries agree

CREATE FUNCTION dephealth.check_report_counts() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    actual_entries  integer;
    actual_resolved integer;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE resolved)
      INTO actual_entries, actual_resolved
      FROM dephealth.report_entry
     WHERE report_id = NEW.id;

    IF actual_entries <> NEW.entry_count THEN
        RAISE EXCEPTION 'report % declares % entries but holds %',
            NEW.id, NEW.entry_count, actual_entries
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF actual_resolved <> NEW.resolved_count THEN
        RAISE EXCEPTION 'report % declares % resolved entries but holds %',
            NEW.id, NEW.resolved_count, actual_resolved
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NULL;
END;
$$;

-- Deferred, since the header is written before its lines
CREATE CONSTRAINT TRIGGER report_counts_match_entries
    AFTER INSERT ON dephealth.report
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION dephealth.check_report_counts();

-- Keeps repository.last_event_on in step with the features it comes from

CREATE FUNCTION dephealth.sync_repository_last_event() RETURNS trigger
    LANGUAGE plpgsql AS $$
DECLARE
    event_on date;
BEGIN
    IF NEW.days_since_last_event IS NULL THEN
        RETURN NULL;
    END IF;

    event_on := NEW.as_of - NEW.days_since_last_event;

    UPDATE dephealth.repository r
       SET last_event_on = event_on
      FROM dephealth.package p
     WHERE p.id = NEW.package_id
       AND r.id = p.repository_id
       AND (r.last_event_on IS NULL OR r.last_event_on < event_on);

    RETURN NULL;
END;
$$;

CREATE TRIGGER activity_feature_syncs_repository
    AFTER INSERT OR UPDATE OF days_since_last_event ON dephealth.activity_feature
    FOR EACH ROW EXECUTE FUNCTION dephealth.sync_repository_last_event();

-- Ingestion run lifecycle

CREATE FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source)
    RETURNS bigint
    LANGUAGE plpgsql AS $$
DECLARE
    new_id bigint;
BEGIN
    -- a second scheduler waits here rather than failing on the unique index
    PERFORM pg_advisory_xact_lock(hashtext('dephealth.ingestion_run:' || in_source::text));

    INSERT INTO dephealth.ingestion_run (source)
    VALUES (in_source)
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

COMMENT ON FUNCTION dephealth.start_ingestion_run(dephealth.data_source) IS
    'Opens a run and returns its id. Every row a run writes carries that id, so a bad run can be found and removed afterwards.';

-- SECURITY DEFINER, since REFRESH needs ownership of the view and the
-- ingestion role has none
CREATE PROCEDURE dephealth.finish_ingestion_run(
    in_run_id              bigint,
    in_status              dephealth.run_status,
    in_data_as_of          date    DEFAULT NULL,
    in_rows_ingested       bigint  DEFAULT 0,
    in_rows_rejected       bigint  DEFAULT 0,
    in_raw_bytes_discarded bigint  DEFAULT NULL,
    in_failure_detail      text    DEFAULT NULL
)
    LANGUAGE plpgsql AS $$
BEGIN
    IF in_status = 'running' THEN
        RAISE EXCEPTION 'a run cannot be finished as running'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE dephealth.ingestion_run
       SET status              = in_status,
           finished_at         = now(),
           data_as_of          = coalesce(in_data_as_of, data_as_of),
           rows_ingested       = in_rows_ingested,
           rows_rejected       = in_rows_rejected,
           raw_bytes_discarded = in_raw_bytes_discarded,
           failure_detail      = in_failure_detail
     WHERE id = in_run_id
       AND status = 'running';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ingestion run % is not in flight', in_run_id
            USING ERRCODE = 'no_data_found';
    END IF;

    IF in_status = 'succeeded' THEN
        BEGIN
            -- a failed refresh leaves the previous figures served, which is
            -- acceptable because every response states their date. Losing the
            -- run record would not be
            REFRESH MATERIALIZED VIEW CONCURRENTLY dephealth.mv_package_current_assessment;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'run % recorded, serving view not refreshed: %',
                in_run_id, SQLERRM;
        END;
    END IF;
END;
$$ SECURITY DEFINER SET search_path = pg_catalog;

COMMENT ON PROCEDURE dephealth.finish_ingestion_run(bigint, dephealth.run_status, date, bigint, bigint, bigint, text) IS
    'Closes a run and, on success, refreshes the serving view. Runs with the owner privileges, since refreshing a materialised view requires ownership. Every identifier inside is schema qualified and the search path is fixed.';

-- Withdrawal of a report

CREATE PROCEDURE dephealth.withdraw_report(in_token_digest bytea, in_reason text)
    LANGUAGE plpgsql AS $$
BEGIN
    IF in_reason IS NULL OR length(btrim(in_reason)) = 0 THEN
        RAISE EXCEPTION 'a withdrawal must state a reason'
            USING ERRCODE = 'null_value_not_allowed',
                  HINT = 'The reason is shown in place of the report.';
    END IF;

    UPDATE dephealth.report
       SET withdrawn_at      = now(),
           withdrawal_reason = in_reason
     WHERE token_digest = in_token_digest
       AND withdrawn_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no live report for that link'
            USING ERRCODE = 'no_data_found';
    END IF;
END;
$$;
