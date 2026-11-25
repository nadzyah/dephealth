--
-- Consolidated DDL for the dephealth application schema.
--
-- GENERATED FILE. Do not edit. Regenerate with `make ddl` after a migration.
-- The source of truth is db/migrations, applied in order; this file is the
-- same structure in one piece, for reading and for creating the schema in an
-- environment where the migration tool is not available.
--
-- The group roles the GRANT statements below refer to are created by
-- db/migrations/0008_roles_and_grants.up.sql, because a role is a cluster
-- object rather than part of a schema. Create them before applying this file.
--
--
-- PostgreSQL database dump
--


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: dephealth; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA dephealth;


--
-- Name: SCHEMA dephealth; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA dephealth IS 'Application schema of dephealth. Holds aggregated, non-identifying data only.';


--
-- Name: data_source; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.data_source AS ENUM (
    'crates_io_dump',
    'gh_archive'
);


--
-- Name: dependency_kind; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.dependency_kind AS ENUM (
    'normal',
    'build',
    'dev'
);


--
-- Name: model_kind; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.model_kind AS ENUM (
    'adoption_forecast',
    'maintenance_risk',
    'download_anomaly'
);


--
-- Name: resolution_method; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.resolution_method AS ENUM (
    'declared_url',
    'dump_metadata',
    'manual_override'
);


--
-- Name: resolution_status; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.resolution_status AS ENUM (
    'resolved',
    'no_url_declared',
    'url_unparseable',
    'host_unsupported',
    'repository_unreachable',
    'absent_from_snapshot',
    'not_a_registry_package',
    'awaiting_first_score'
);


--
-- Name: run_status; Type: TYPE; Schema: dephealth; Owner: -
--

CREATE TYPE dephealth.run_status AS ENUM (
    'running',
    'succeeded',
    'failed'
);


--
-- Name: abandonment_window_days(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.abandonment_window_days() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN 180;


--
-- Name: check_report_counts(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.check_report_counts() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: create_report(text, text, jsonb); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.create_report(in_token text, in_salt text, in_entries jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'dephealth', 'pg_temp'
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


--
-- Name: FUNCTION create_report(in_token text, in_salt text, in_entries jsonb); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.create_report(in_token text, in_salt text, in_entries jsonb) IS 'Store one assessment of a submitted manifest. Definer rights, because the caller may not read the models, the live scores or the factor decomposition that the snapshot is taken from. The token is hashed here and never stored.';


--
-- Name: k_anonymity_threshold(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.k_anonymity_threshold() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN 5;


--
-- Name: FUNCTION k_anonymity_threshold(); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.k_anonymity_threshold() IS 'Smallest contributor count publishable through a read-only view. A migration rather than a setting, so the value in force on any date is in the schema history.';


--
-- Name: disclosed_contributors(integer); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN CASE WHEN ((distinct_contributors = 0) OR (distinct_contributors >= dephealth.k_anonymity_threshold())) THEN distinct_contributors ELSE NULL::integer END;


--
-- Name: FUNCTION disclosed_contributors(distinct_contributors integer); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) IS 'Applies the disclosure threshold. Returns null between one and the threshold, the only range in which a count describes identifiable people. Every read-only view passes its counts through this.';


--
-- Name: disclosed_share(numeric, integer); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer) RETURNS numeric
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN CASE WHEN (in_contributors >= dephealth.k_anonymity_threshold()) THEN in_share ELSE NULL::numeric END;


--
-- Name: finish_ingestion_run(bigint, dephealth.run_status, date, bigint, bigint, bigint, text); Type: PROCEDURE; Schema: dephealth; Owner: -
--

CREATE PROCEDURE dephealth.finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date DEFAULT NULL::date, IN in_rows_ingested bigint DEFAULT 0, IN in_rows_rejected bigint DEFAULT 0, IN in_raw_bytes_discarded bigint DEFAULT NULL::bigint, IN in_failure_detail text DEFAULT NULL::text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
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
$$;


--
-- Name: PROCEDURE finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON PROCEDURE dephealth.finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text) IS 'Closes a run and, on success, refreshes the serving view. Runs with the owner privileges, since refreshing a materialised view requires ownership. Every identifier inside is schema qualified and the search path is fixed.';


--
-- Name: guard_report_mutation(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.guard_report_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: is_abandoned(integer); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.is_abandoned(days_since_last_event integer) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN (days_since_last_event >= dephealth.abandonment_window_days());


--
-- Name: FUNCTION is_abandoned(days_since_last_event integer); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) IS 'The abandonment label of the requirements document. The training label and the interface both read it, so the two cannot drift apart.';


--
-- Name: manifest_fingerprint(text[], text); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text) RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
    SELECT sha256(convert_to(
        in_salt || ':' || array_to_string(
            (SELECT array_agg(entry ORDER BY entry) FROM unnest(in_entries) AS entry),
            ','),
        'UTF8'))
$$;


--
-- Name: FUNCTION manifest_fingerprint(in_entries text[], in_salt text); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text) IS 'Salted digest of the sorted name@version set of a manifest. Recognises a resubmission without retaining the manifest. The salt is held by the application, not the database.';


--
-- Name: previous_report_of(bytea); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.previous_report_of(in_token_digest bytea) RETURNS bytea
    LANGUAGE sql STABLE
    SET search_path TO 'dephealth', 'pg_temp'
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


--
-- Name: FUNCTION previous_report_of(in_token_digest bytea); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.previous_report_of(in_token_digest bytea) IS 'The digest of the report before this one for the same manifest, or nothing if this is the first. Invoker rights, since both rows are readable by whoever may read the report.';


--
-- Name: reject_mutation(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.reject_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION
        'relation %.% is append only',
        TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation',
              HINT = 'A filed report must return the figures it held when it was generated.';
END;
$$;


--
-- Name: report_token_digest(text); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.report_token_digest(in_token text) RETURNS bytea
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    RETURN sha256(convert_to(in_token, 'UTF8'::name));


--
-- Name: FUNCTION report_token_digest(in_token text); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.report_token_digest(in_token text) IS 'SHA-256 of a report link token. A fast digest is correct here and a password digest would not be, since the token is random.';


--
-- Name: start_ingestion_run(dephealth.data_source); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: FUNCTION start_ingestion_run(in_source dephealth.data_source); Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source) IS 'Opens a run and returns its id. Every row a run writes carries that id, so a bad run can be found and removed afterwards.';


--
-- Name: sync_repository_last_event(); Type: FUNCTION; Schema: dephealth; Owner: -
--

CREATE FUNCTION dephealth.sync_repository_last_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: withdraw_report(bytea, text); Type: PROCEDURE; Schema: dephealth; Owner: -
--

CREATE PROCEDURE dephealth.withdraw_report(IN in_token_digest bytea, IN in_reason text)
    LANGUAGE plpgsql
    AS $$
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


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_feature; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.activity_feature (
    package_id bigint NOT NULL,
    as_of date NOT NULL,
    window_days integer NOT NULL,
    distinct_contributors integer NOT NULL,
    event_count integer NOT NULL,
    commit_event_count integer NOT NULL,
    issue_event_count integer NOT NULL,
    review_event_count integer NOT NULL,
    days_since_last_event integer,
    top_contributor_share numeric(4,3),
    run_id bigint NOT NULL,
    CONSTRAINT activity_feature_commit_event_count_check CHECK ((commit_event_count >= 0)),
    CONSTRAINT activity_feature_contributors_within_events CHECK ((distinct_contributors <= event_count)),
    CONSTRAINT activity_feature_days_since_last_event_check CHECK ((days_since_last_event >= 0)),
    CONSTRAINT activity_feature_distinct_contributors_check CHECK ((distinct_contributors >= 0)),
    CONSTRAINT activity_feature_event_count_check CHECK ((event_count >= 0)),
    CONSTRAINT activity_feature_events_need_a_contributor CHECK (((event_count = 0) = (distinct_contributors = 0))),
    CONSTRAINT activity_feature_issue_event_count_check CHECK ((issue_event_count >= 0)),
    CONSTRAINT activity_feature_parts_within_total CHECK ((((commit_event_count + issue_event_count) + review_event_count) <= event_count)),
    CONSTRAINT activity_feature_review_event_count_check CHECK ((review_event_count >= 0)),
    CONSTRAINT activity_feature_share_at_least_even CHECK (((top_contributor_share IS NULL) OR (top_contributor_share >= ((1.0 / (distinct_contributors)::numeric) - 0.001)))),
    CONSTRAINT activity_feature_share_with_events CHECK (((event_count = 0) = (top_contributor_share IS NULL))),
    CONSTRAINT activity_feature_top_contributor_share_check CHECK (((top_contributor_share > (0)::numeric) AND (top_contributor_share <= (1)::numeric)))
);


--
-- Name: TABLE activity_feature; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.activity_feature IS 'Contributor activity aggregated to the package over a trailing window. The data protection boundary of the system. The raw events identify accounts, these rows hold counts, and the raw files are deleted once a run has produced them.';


--
-- Name: COLUMN activity_feature.distinct_contributors; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON COLUMN dephealth.activity_feature.distinct_contributors IS 'Accounts that produced at least one event in the window. Published through the read-only views only at or above dephealth.k_anonymity_threshold().';


--
-- Name: COLUMN activity_feature.days_since_last_event; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON COLUMN dephealth.activity_feature.days_since_last_event IS 'Days between as_of and the most recent development event. The abandonment label derives from this column at 180 days.';


--
-- Name: adoption_forecast; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.adoption_forecast (
    id bigint NOT NULL,
    package_id bigint NOT NULL,
    model_id bigint NOT NULL,
    run_id bigint NOT NULL,
    as_of date NOT NULL,
    horizon_months integer NOT NULL,
    point_downloads numeric(14,2),
    lower_downloads numeric(14,2),
    upper_downloads numeric(14,2),
    history_days integer NOT NULL,
    insufficient_history boolean NOT NULL,
    CONSTRAINT adoption_forecast_history_days_check CHECK ((history_days >= 0)),
    CONSTRAINT adoption_forecast_lower_downloads_check CHECK ((lower_downloads >= (0)::numeric)),
    CONSTRAINT adoption_forecast_point_downloads_check CHECK ((point_downloads >= (0)::numeric)),
    CONSTRAINT adoption_forecast_upper_downloads_check CHECK ((upper_downloads >= (0)::numeric)),
    CONSTRAINT forecast_absent_when_history_insufficient CHECK (((insufficient_history AND (point_downloads IS NULL) AND (lower_downloads IS NULL) AND (upper_downloads IS NULL)) OR ((NOT insufficient_history) AND (point_downloads IS NOT NULL)))),
    CONSTRAINT forecast_history_rule CHECK ((insufficient_history = (history_days < 365))),
    CONSTRAINT forecast_horizon_in_range CHECK (((horizon_months >= 3) AND (horizon_months <= 12))),
    CONSTRAINT forecast_interval_ordered CHECK (((lower_downloads IS NULL) OR (upper_downloads IS NULL) OR ((lower_downloads <= point_downloads) AND (point_downloads <= upper_downloads))))
);


--
-- Name: TABLE adoption_forecast; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.adoption_forecast IS 'Forecast adoption per package and horizon, computed offline. A row with insufficient_history set records that no forecast was produced, which differs from a forecast being absent.';


--
-- Name: adoption_forecast_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.adoption_forecast ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.adoption_forecast_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: download_daily; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily (
    package_id bigint NOT NULL,
    day date NOT NULL,
    downloads bigint NOT NULL,
    run_id bigint NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
)
PARTITION BY RANGE (day);


--
-- Name: TABLE download_daily; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.download_daily IS 'Downloads per package per day. The registry publishes the figure per version, and the versions are summed on load, since every requirement is stated at the level of the package.';


--
-- Name: download_daily_2014; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2014 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2015; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2015 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2016; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2016 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2017; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2017 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2018; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2018 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2019; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2019 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2020; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2020 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2021; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2021 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2022; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2022 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2023; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2023 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2024; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2024 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2025; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2025 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2026; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2026 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_2027; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_2027 (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: download_daily_unexpected; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.download_daily_unexpected (
    package_id bigint CONSTRAINT download_daily_package_id_not_null NOT NULL,
    day date CONSTRAINT download_daily_day_not_null NOT NULL,
    downloads bigint CONSTRAINT download_daily_downloads_not_null NOT NULL,
    run_id bigint CONSTRAINT download_daily_run_id_not_null NOT NULL,
    CONSTRAINT download_daily_downloads_check CHECK ((downloads >= 0))
);


--
-- Name: TABLE download_daily_unexpected; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.download_daily_unexpected IS 'Quarantine partition. Any row here is a data quality finding, not data to be served.';


--
-- Name: feature_window; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.feature_window (
    days integer NOT NULL,
    label text NOT NULL,
    CONSTRAINT feature_window_label_present CHECK ((length(btrim(label)) > 0)),
    CONSTRAINT feature_window_positive CHECK ((days > 0))
);


--
-- Name: TABLE feature_window; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.feature_window IS 'Reference table of the trailing windows contributor activity is aggregated over. Adding one changes what the model is trained on, so it takes a migration.';


--
-- Name: ingestion_run; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.ingestion_run (
    id bigint NOT NULL,
    source dephealth.data_source NOT NULL,
    status dephealth.run_status DEFAULT 'running'::dephealth.run_status NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    data_as_of date,
    window_start date,
    window_end date,
    rows_ingested bigint DEFAULT 0 NOT NULL,
    rows_rejected bigint DEFAULT 0 NOT NULL,
    raw_bytes_discarded bigint,
    failure_detail text,
    CONSTRAINT ingestion_run_failure_detail_with_failure CHECK (((status = 'failed'::dephealth.run_status) = (failure_detail IS NOT NULL))),
    CONSTRAINT ingestion_run_finished_after_start CHECK (((finished_at IS NULL) OR (finished_at >= started_at))),
    CONSTRAINT ingestion_run_finished_with_status CHECK (((status = 'running'::dephealth.run_status) = (finished_at IS NULL))),
    CONSTRAINT ingestion_run_raw_bytes_discarded_check CHECK ((raw_bytes_discarded >= 0)),
    CONSTRAINT ingestion_run_rows_ingested_check CHECK ((rows_ingested >= 0)),
    CONSTRAINT ingestion_run_rows_rejected_check CHECK ((rows_rejected >= 0)),
    CONSTRAINT ingestion_run_success_has_as_of CHECK (((status <> 'succeeded'::dephealth.run_status) OR (data_as_of IS NOT NULL))),
    CONSTRAINT ingestion_run_window_ordered CHECK (((window_start IS NULL) OR (window_end IS NULL) OR (window_start <= window_end)))
);


--
-- Name: TABLE ingestion_run; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.ingestion_run IS 'One pass over one source. Every derived row names the run that produced it, so the age of a served figure is answerable and a bad run is reversible.';


--
-- Name: ingestion_run_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.ingestion_run ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.ingestion_run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: maintenance_risk; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.maintenance_risk (
    id bigint NOT NULL,
    package_id bigint NOT NULL,
    model_id bigint NOT NULL,
    run_id bigint NOT NULL,
    as_of date NOT NULL,
    horizon_days integer NOT NULL,
    probability numeric(5,4) NOT NULL,
    abandonment_window_days integer DEFAULT 180 NOT NULL,
    CONSTRAINT maintenance_risk_abandonment_window_days_check CHECK ((abandonment_window_days > 0)),
    CONSTRAINT maintenance_risk_horizon_days_check CHECK ((horizon_days > 0)),
    CONSTRAINT maintenance_risk_probability_check CHECK (((probability >= (0)::numeric) AND (probability <= (1)::numeric)))
);


--
-- Name: TABLE maintenance_risk; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.maintenance_risk IS 'Probability that a package loses its active maintainers within the horizon, computed offline. numeric rather than float, since the figure is quoted in a stored report and has to round identically on every read.';


--
-- Name: maintenance_risk_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.maintenance_risk ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.maintenance_risk_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: metric_definition; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.metric_definition (
    code text NOT NULL,
    label text NOT NULL,
    unit text NOT NULL,
    lower_is_better boolean NOT NULL,
    kpi text,
    CONSTRAINT metric_definition_code_wellformed CHECK ((code ~ '^[a-z][a-z0-9_]{2,31}$'::text)),
    CONSTRAINT metric_definition_kpi_wellformed CHECK (((kpi IS NULL) OR (kpi ~ '^KPI[1-9]$'::text))),
    CONSTRAINT metric_definition_label_present CHECK ((length(btrim(label)) > 0))
);


--
-- Name: TABLE metric_definition; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.metric_definition IS 'Reference table of evaluation metrics. The kpi column links a measured number to the indicator it reports against.';


--
-- Name: model; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.model (
    id bigint NOT NULL,
    kind dephealth.model_kind NOT NULL,
    name text NOT NULL,
    version text NOT NULL,
    is_baseline boolean DEFAULT false NOT NULL,
    is_current boolean DEFAULT false NOT NULL,
    trained_at timestamp with time zone NOT NULL,
    train_window_start date NOT NULL,
    train_window_end date NOT NULL,
    hyperparameters jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT model_baseline_never_current CHECK ((NOT (is_baseline AND is_current))),
    CONSTRAINT model_hyperparameters_is_object CHECK ((jsonb_typeof(hyperparameters) = 'object'::text)),
    CONSTRAINT model_name_present CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT model_train_window_ordered CHECK ((train_window_start < train_window_end)),
    CONSTRAINT model_version_present CHECK ((length(btrim(version)) > 0))
);


--
-- Name: TABLE model; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.model IS 'One fitted model. A baseline is a model row rather than a constant, so one metric table measures both sides of the comparison.';


--
-- Name: model_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.model ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.model_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: model_metric; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.model_metric (
    model_id bigint NOT NULL,
    metric text NOT NULL,
    value numeric NOT NULL,
    evaluated_on_packages integer NOT NULL,
    evaluated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT model_metric_evaluated_on_packages_check CHECK ((evaluated_on_packages > 0))
);


--
-- Name: TABLE model_metric; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.model_metric IS 'Held-out metrics per model. KPI3 and KPI4 compare the current model with the baseline of the same kind.';


--
-- Name: package; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.package (
    id bigint NOT NULL,
    registry text DEFAULT 'crates.io'::text NOT NULL,
    name text NOT NULL,
    created_on date,
    latest_version text,
    repository_id bigint,
    resolution_status dephealth.resolution_status NOT NULL,
    resolution_method dephealth.resolution_method,
    resolution_detail text,
    resolved_at timestamp with time zone,
    first_seen_run_id bigint NOT NULL,
    CONSTRAINT package_name_wellformed CHECK ((name ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'::text)),
    CONSTRAINT package_registry_supported CHECK ((registry = 'crates.io'::text)),
    CONSTRAINT package_resolution_coherent CHECK ((((resolution_status = 'resolved'::dephealth.resolution_status) AND (repository_id IS NOT NULL) AND (resolution_method IS NOT NULL) AND (resolved_at IS NOT NULL)) OR ((resolution_status <> 'resolved'::dephealth.resolution_status) AND (repository_id IS NULL) AND (resolution_method IS NULL) AND (resolved_at IS NULL))))
);


--
-- Name: TABLE package; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.package IS 'One package in the registry. The resolution columns record whether it reached a source repository and, if not, why. KPI1 is read from them.';


--
-- Name: repository; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.repository (
    id bigint NOT NULL,
    host text NOT NULL,
    owner text NOT NULL,
    name text NOT NULL,
    canonical_url text NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_event_on date,
    CONSTRAINT repository_host_supported CHECK ((host = 'github.com'::text)),
    CONSTRAINT repository_name_present CHECK ((length(btrim(name)) > 0)),
    CONSTRAINT repository_owner_present CHECK ((length(btrim(owner)) > 0)),
    CONSTRAINT repository_url_wellformed CHECK ((canonical_url ~ '^https://[a-z0-9.-]+/[^/]+/[^/]+$'::text))
);


--
-- Name: mv_package_current_assessment; Type: MATERIALIZED VIEW; Schema: dephealth; Owner: -
--

CREATE MATERIALIZED VIEW dephealth.mv_package_current_assessment AS
 WITH current_risk AS (
         SELECT DISTINCT ON (mr.package_id) mr.package_id,
            mr.id AS maintenance_risk_id,
            mr.probability,
            mr.horizon_days,
            mr.abandonment_window_days,
            mr.as_of
           FROM (dephealth.maintenance_risk mr
             JOIN dephealth.model m ON (((m.id = mr.model_id) AND m.is_current)))
          ORDER BY mr.package_id, mr.as_of DESC
        ), current_forecast AS (
         SELECT DISTINCT ON (f.package_id) f.package_id,
            f.point_downloads,
            f.lower_downloads,
            f.upper_downloads,
            f.horizon_months,
            f.insufficient_history,
            f.history_days,
            f.as_of
           FROM (dephealth.adoption_forecast f
             JOIN dephealth.model m ON (((m.id = f.model_id) AND m.is_current)))
          ORDER BY f.package_id, f.as_of DESC, f.horizon_months DESC
        ), current_activity AS (
         SELECT DISTINCT ON (a.package_id) a.package_id,
            a.distinct_contributors,
            a.event_count,
            a.days_since_last_event,
            a.top_contributor_share,
            a.as_of
           FROM dephealth.activity_feature a
          WHERE (a.window_days = 90)
          ORDER BY a.package_id, a.as_of DESC
        )
 SELECT p.id AS package_id,
    p.name AS package_name,
    p.latest_version,
    p.resolution_status,
    rp.canonical_url AS repository_url,
    cr.maintenance_risk_id,
    cr.probability AS risk_probability,
    cr.horizon_days AS risk_horizon_days,
    cr.abandonment_window_days,
    cr.as_of AS risk_as_of,
    cf.point_downloads AS forecast_point_downloads,
    cf.lower_downloads AS forecast_lower_downloads,
    cf.upper_downloads AS forecast_upper_downloads,
    cf.horizon_months AS forecast_horizon_months,
    cf.insufficient_history,
    cf.history_days,
    ca.distinct_contributors,
    ca.event_count,
    ca.days_since_last_event,
    ca.top_contributor_share,
    dephealth.is_abandoned(ca.days_since_last_event) AS is_abandoned
   FROM ((((dephealth.package p
     LEFT JOIN dephealth.repository rp ON ((rp.id = p.repository_id)))
     LEFT JOIN current_risk cr ON ((cr.package_id = p.id)))
     LEFT JOIN current_forecast cf ON ((cf.package_id = p.id)))
     LEFT JOIN current_activity ca ON ((ca.package_id = p.id)))
  WITH NO DATA;


--
-- Name: MATERIALIZED VIEW mv_package_current_assessment; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON MATERIALIZED VIEW dephealth.mv_package_current_assessment IS 'One row per package with the figures of the current models, refreshed concurrently at the end of a run. The ranked tree is built from it.';


--
-- Name: package_dependency; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.package_dependency (
    dependent_version_id bigint NOT NULL,
    dependency_package_id bigint NOT NULL,
    kind dephealth.dependency_kind NOT NULL,
    requirement text NOT NULL,
    optional boolean DEFAULT false NOT NULL,
    CONSTRAINT package_dependency_requirement_present CHECK ((length(btrim(requirement)) > 0))
);


--
-- Name: TABLE package_dependency; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.package_dependency IS 'Dependency edges from a published version to a required package. The development kind is left out of a consumer tree, since a consumer does not build the test suite of its dependencies.';


--
-- Name: package_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.package ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.package_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: package_version; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.package_version (
    id bigint NOT NULL,
    package_id bigint NOT NULL,
    version text NOT NULL,
    published_at timestamp with time zone,
    yanked boolean DEFAULT false NOT NULL,
    CONSTRAINT package_version_present CHECK ((length(btrim(version)) > 0))
);


--
-- Name: TABLE package_version; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.package_version IS 'Published versions. A lockfile entry names a version rather than a package, and the first publication date bounds how much history a forecast can rest on.';


--
-- Name: package_version_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.package_version ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.package_version_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: report; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.report (
    id bigint NOT NULL,
    token_digest bytea NOT NULL,
    manifest_fingerprint bytea,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    crates_data_as_of date NOT NULL,
    events_data_as_of date NOT NULL,
    abandonment_window_days integer NOT NULL,
    risk_model_id bigint NOT NULL,
    forecast_model_id bigint NOT NULL,
    entry_count integer NOT NULL,
    resolved_count integer NOT NULL,
    withdrawn_at timestamp with time zone,
    withdrawal_reason text,
    CONSTRAINT report_abandonment_window_days_check CHECK ((abandonment_window_days > 0)),
    CONSTRAINT report_entry_count_check CHECK ((entry_count > 0)),
    CONSTRAINT report_fingerprint_is_sha256 CHECK (((manifest_fingerprint IS NULL) OR (length(manifest_fingerprint) = 32))),
    CONSTRAINT report_resolved_count_check CHECK ((resolved_count >= 0)),
    CONSTRAINT report_resolved_within_total CHECK ((resolved_count <= entry_count)),
    CONSTRAINT report_token_digest_is_sha256 CHECK ((length(token_digest) = 32)),
    CONSTRAINT report_withdrawal_coherent CHECK (((withdrawn_at IS NULL) = (withdrawal_reason IS NULL))),
    CONSTRAINT report_withdrawn_after_created CHECK (((withdrawn_at IS NULL) OR (withdrawn_at >= created_at)))
);


--
-- Name: TABLE report; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.report IS 'One generated assessment, addressable by a permanent link. Append only except for withdrawal, enforced by trigger and by column level privileges.';


--
-- Name: COLUMN report.token_digest; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON COLUMN dephealth.report.token_digest IS 'SHA-256 of the random token in the permanent link. The token is never stored, so links cannot be recovered from a database dump.';


--
-- Name: COLUMN report.manifest_fingerprint; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON COLUMN dephealth.report.manifest_fingerprint IS 'Salted SHA-256 of the sorted name@version set. Lets a resubmission be recognised without retaining the manifest.';


--
-- Name: report_entry; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.report_entry (
    report_id bigint NOT NULL,
    ordinal integer NOT NULL,
    package_name text NOT NULL,
    package_version text NOT NULL,
    depth integer NOT NULL,
    is_direct boolean NOT NULL,
    package_id bigint,
    resolved boolean NOT NULL,
    unresolved_reason dephealth.resolution_status,
    risk_probability numeric(5,4),
    risk_horizon_days integer,
    forecast_point_downloads numeric(14,2),
    forecast_horizon_months integer,
    insufficient_history boolean DEFAULT false NOT NULL,
    distinct_contributors integer,
    days_since_last_event integer,
    CONSTRAINT report_entry_days_since_last_event_check CHECK ((days_since_last_event >= 0)),
    CONSTRAINT report_entry_depth_check CHECK ((depth >= 0)),
    CONSTRAINT report_entry_direct_matches_depth CHECK ((is_direct = (depth = 0))),
    CONSTRAINT report_entry_distinct_contributors_check CHECK ((distinct_contributors >= 0)),
    CONSTRAINT report_entry_forecast_coherent CHECK (((insufficient_history AND (forecast_point_downloads IS NULL)) OR (NOT insufficient_history))),
    CONSTRAINT report_entry_forecast_horizon_months_check CHECK (((forecast_horizon_months >= 3) AND (forecast_horizon_months <= 12))),
    CONSTRAINT report_entry_forecast_point_downloads_check CHECK ((forecast_point_downloads >= (0)::numeric)),
    CONSTRAINT report_entry_name_present CHECK ((length(btrim(package_name)) > 0)),
    CONSTRAINT report_entry_ordinal_check CHECK ((ordinal > 0)),
    CONSTRAINT report_entry_resolution_coherent CHECK (((resolved AND (unresolved_reason IS NULL) AND (risk_probability IS NOT NULL) AND (risk_horizon_days IS NOT NULL)) OR ((NOT resolved) AND (unresolved_reason IS NOT NULL) AND (risk_probability IS NULL) AND (risk_horizon_days IS NULL)))),
    CONSTRAINT report_entry_risk_horizon_days_check CHECK ((risk_horizon_days > 0)),
    CONSTRAINT report_entry_risk_probability_check CHECK (((risk_probability >= (0)::numeric) AND (risk_probability <= (1)::numeric))),
    CONSTRAINT report_entry_version_present CHECK ((length(btrim(package_version)) > 0))
);


--
-- Name: TABLE report_entry; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.report_entry IS 'One line of a stored report, holding the figures as they stood when it was generated. Append only, so a report filed as evidence does not change when the next run overwrites the live scores.';


--
-- Name: report_entry_factor; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.report_entry_factor (
    report_id bigint NOT NULL,
    ordinal integer NOT NULL,
    factor text NOT NULL,
    observed_value numeric NOT NULL,
    contribution numeric NOT NULL
);


--
-- Name: TABLE report_entry_factor; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.report_entry_factor IS 'The factor decomposition as it stood when the report was generated, so the evidence behind a filed score is as durable as the score. A child table rather than a document column, since it is read as rows ordered by contribution.';


--
-- Name: report_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.report ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.report_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: repository_id_seq; Type: SEQUENCE; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.repository ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME dephealth.repository_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: resolution_outcome; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.resolution_outcome (
    status dephealth.resolution_status NOT NULL,
    label text NOT NULL,
    is_resolved boolean NOT NULL,
    remedy text NOT NULL,
    CONSTRAINT resolution_outcome_label_present CHECK ((length(btrim(label)) > 0))
);


--
-- Name: TABLE resolution_outcome; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.resolution_outcome IS 'Reference table, one row per value of dephealth.resolution_status.';


--
-- Name: risk_factor; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.risk_factor (
    maintenance_risk_id bigint NOT NULL,
    factor text NOT NULL,
    observed_value numeric NOT NULL,
    contribution numeric NOT NULL
);


--
-- Name: TABLE risk_factor; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.risk_factor IS 'Decomposition of one risk score into named factors. Shown in the detail view, which is what makes the score evidence rather than a number.';


--
-- Name: risk_factor_catalogue; Type: TABLE; Schema: dephealth; Owner: -
--

CREATE TABLE dephealth.risk_factor_catalogue (
    code text NOT NULL,
    label text NOT NULL,
    description text NOT NULL,
    higher_is_riskier boolean NOT NULL,
    CONSTRAINT risk_factor_code_wellformed CHECK ((code ~ '^[a-z][a-z0-9_]{2,39}$'::text)),
    CONSTRAINT risk_factor_description_present CHECK ((length(btrim(description)) > 0)),
    CONSTRAINT risk_factor_label_present CHECK ((length(btrim(label)) > 0))
);


--
-- Name: TABLE risk_factor_catalogue; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON TABLE dephealth.risk_factor_catalogue IS 'Reference table of the factors a risk score may be decomposed into. A factor takes a migration, since an explanation has to be describable in words before it is shown.';


--
-- Name: v_data_age; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_data_age AS
 SELECT s.source,
    succeeded.data_as_of,
    (CURRENT_DATE - succeeded.data_as_of) AS age_days,
    succeeded.finished_at AS last_success_at,
    latest.status AS last_attempt_status,
    latest.started_at AS last_attempt_at
   FROM ((( SELECT unnest(enum_range(NULL::dephealth.data_source)) AS source) s
     LEFT JOIN LATERAL ( SELECT r.data_as_of,
            r.finished_at
           FROM dephealth.ingestion_run r
          WHERE ((r.source = s.source) AND (r.status = 'succeeded'::dephealth.run_status))
          ORDER BY r.data_as_of DESC
         LIMIT 1) succeeded ON (true))
     LEFT JOIN LATERAL ( SELECT r.status,
            r.started_at
           FROM dephealth.ingestion_run r
          WHERE (r.source = s.source)
          ORDER BY r.started_at DESC
         LIMIT 1) latest ON (true));


--
-- Name: VIEW v_data_age; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_data_age IS 'Age of each source and the outcome of its last attempt. Read on every request, since no score may be shown without the age of the data behind it.';


--
-- Name: v_data_quality_finding; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_data_quality_finding AS
 SELECT 'download_day_out_of_range'::text AS check_code,
    'error'::text AS severity,
    p.name AS subject,
    format('%s rows land in the quarantine partition, earliest %s'::text, count(*), min(d.day)) AS detail
   FROM (dephealth.download_daily_unexpected d
     JOIN dephealth.package p ON ((p.id = d.package_id)))
  GROUP BY p.name
UNION ALL
 SELECT 'download_day_in_future'::text AS check_code,
    'error'::text AS severity,
    p.name AS subject,
    format('latest day is %s'::text, max(d.day)) AS detail
   FROM (dephealth.download_daily d
     JOIN dephealth.package p ON ((p.id = d.package_id)))
  GROUP BY p.name
 HAVING (max(d.day) > CURRENT_DATE)
UNION ALL
 SELECT 'download_series_gap'::text AS check_code,
    'warning'::text AS severity,
    p.name AS subject,
    format('%s of the 30 days ending yesterday are missing'::text, (30 - count(DISTINCT d.day))) AS detail
   FROM (dephealth.package p
     JOIN dephealth.download_daily d ON (((d.package_id = p.id) AND ((d.day >= (CURRENT_DATE - 30)) AND (d.day <= (CURRENT_DATE - 1))))))
  GROUP BY p.name
 HAVING (count(DISTINCT d.day) < 30)
UNION ALL
 SELECT 'package_depends_on_itself'::text AS check_code,
    'error'::text AS severity,
    p.name AS subject,
    format('version %s requires its own package'::text, v.version) AS detail
   FROM ((dephealth.package_dependency pd
     JOIN dephealth.package_version v ON ((v.id = pd.dependent_version_id)))
     JOIN dephealth.package p ON ((p.id = v.package_id)))
  WHERE (p.id = pd.dependency_package_id)
UNION ALL
 SELECT 'resolved_without_activity'::text AS check_code,
    'warning'::text AS severity,
    p.name AS subject,
    'resolved to a repository but no activity features were derived'::text AS detail
   FROM (dephealth.package p
     JOIN dephealth.resolution_outcome o ON ((o.status = p.resolution_status)))
  WHERE (o.is_resolved AND (NOT (EXISTS ( SELECT 1
           FROM dephealth.activity_feature a
          WHERE (a.package_id = p.id)))))
UNION ALL
 SELECT 'scored_without_resolution'::text AS check_code,
    'error'::text AS severity,
    p.name AS subject,
    format('risk score %s on a package with status %s'::text, mr.probability, p.resolution_status) AS detail
   FROM ((dephealth.maintenance_risk mr
     JOIN dephealth.package p ON ((p.id = mr.package_id)))
     JOIN dephealth.resolution_outcome o ON ((o.status = p.resolution_status)))
  WHERE (NOT o.is_resolved)
UNION ALL
 SELECT 'serving_model_without_metric'::text AS check_code,
    'error'::text AS severity,
    (m.kind)::text AS subject,
    format('%s %s carries no %s'::text, m.name, m.version, d.code) AS detail
   FROM (dephealth.model m
     JOIN dephealth.metric_definition d ON ((((m.kind = 'maintenance_risk'::dephealth.model_kind) AND (d.code = 'concordance_index'::text)) OR ((m.kind = 'adoption_forecast'::dephealth.model_kind) AND (d.code = 'smape'::text)))))
  WHERE (m.is_current AND (NOT (EXISTS ( SELECT 1
           FROM dephealth.model_metric mm
          WHERE ((mm.model_id = m.id) AND (mm.metric = d.code))))))
UNION ALL
 SELECT 'empty_successful_run'::text AS check_code,
    'warning'::text AS severity,
    (r.source)::text AS subject,
    format('run %s succeeded on %s having loaded no rows'::text, r.id, r.data_as_of) AS detail
   FROM dephealth.ingestion_run r
  WHERE ((r.status = 'succeeded'::dephealth.run_status) AND (r.rows_ingested = 0))
UNION ALL
 SELECT 'activity_without_last_event'::text AS check_code,
    'error'::text AS severity,
    p.name AS subject,
    format('window of %s days as of %s has %s contributors and no last event date'::text, a.window_days, a.as_of, a.distinct_contributors) AS detail
   FROM (dephealth.activity_feature a
     JOIN dephealth.package p ON ((p.id = a.package_id)))
  WHERE ((a.distinct_contributors > 0) AND (a.days_since_last_event IS NULL))
UNION ALL
 SELECT 'report_counts_disagree'::text AS check_code,
    'error'::text AS severity,
    (r.id)::text AS subject,
    format('declares %s entries, holds %s'::text, r.entry_count, count(e.ordinal)) AS detail
   FROM (dephealth.report r
     LEFT JOIN dephealth.report_entry e ON ((e.report_id = r.id)))
  GROUP BY r.id, r.entry_count
 HAVING (count(e.ordinal) <> r.entry_count);


--
-- Name: VIEW v_data_quality_finding; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_data_quality_finding IS 'Data quality conditions the constraints cannot express. An empty result is the expected state. Error means the data should not be served, warning means it should be looked at.';


--
-- Name: v_download_series; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_download_series AS
 SELECT p.name AS package_name,
    d.day,
    d.downloads
   FROM (dephealth.download_daily d
     JOIN dephealth.package p ON ((p.id = d.package_id)));


--
-- Name: VIEW v_download_series; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_download_series IS 'The observed download series, plotted beside the forecast in the detail view.';


--
-- Name: v_kpi1_resolution; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_kpi1_resolution AS
 SELECT count(*) AS packages,
    count(*) FILTER (WHERE o.is_resolved) AS resolved,
    round(((100.0 * (count(*) FILTER (WHERE o.is_resolved))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS resolved_percent,
    90.0 AS target_percent
   FROM (dephealth.package p
     JOIN dephealth.resolution_outcome o ON ((o.status = p.resolution_status)));


--
-- Name: v_kpi1_resolution_by_reason; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_kpi1_resolution_by_reason AS
 SELECT o.status,
    o.label,
    count(p.id) AS packages,
    round(((100.0 * (count(p.id))::numeric) / NULLIF(sum(count(p.id)) OVER (), (0)::numeric)), 2) AS share_percent
   FROM (dephealth.resolution_outcome o
     LEFT JOIN dephealth.package p ON ((p.resolution_status = o.status)))
  GROUP BY o.status, o.label;


--
-- Name: v_model_against_baseline; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_model_against_baseline AS
 SELECT current_model.kind,
    d.code AS metric,
    d.label AS metric_label,
    d.kpi,
    d.lower_is_better,
    current_model.name AS model_name,
    current_model.version AS model_version,
    current_metric.value AS model_value,
    baseline_model.name AS baseline_name,
    baseline_metric.value AS baseline_value,
        CASE
            WHEN (baseline_metric.value IS NULL) THEN NULL::boolean
            WHEN d.lower_is_better THEN (current_metric.value < baseline_metric.value)
            ELSE (current_metric.value > baseline_metric.value)
        END AS beats_baseline
   FROM ((((dephealth.model current_model
     JOIN dephealth.model_metric current_metric ON ((current_metric.model_id = current_model.id)))
     JOIN dephealth.metric_definition d ON ((d.code = current_metric.metric)))
     LEFT JOIN dephealth.model baseline_model ON (((baseline_model.kind = current_model.kind) AND baseline_model.is_baseline)))
     LEFT JOIN dephealth.model_metric baseline_metric ON (((baseline_metric.model_id = baseline_model.id) AND (baseline_metric.metric = current_metric.metric))))
  WHERE current_model.is_current;


--
-- Name: VIEW v_model_against_baseline; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_model_against_baseline IS 'Every held-out metric of the serving models beside the same metric of the baseline of the same kind. KPI3 and KPI4 are rows of this view.';


--
-- Name: v_package_assessment; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_package_assessment AS
 SELECT a.package_name,
    a.latest_version,
    a.repository_url,
    a.risk_probability,
    a.risk_horizon_days,
    a.abandonment_window_days,
    a.risk_as_of,
    a.forecast_point_downloads,
    a.forecast_lower_downloads,
    a.forecast_upper_downloads,
    a.forecast_horizon_months,
    a.insufficient_history,
    dephealth.disclosed_contributors(a.distinct_contributors) AS distinct_contributors,
    dephealth.disclosed_share(a.top_contributor_share, a.distinct_contributors) AS top_contributor_share,
    ((dephealth.disclosed_contributors(a.distinct_contributors) IS NULL) AND (a.distinct_contributors IS NOT NULL)) AS contributor_count_withheld,
    a.days_since_last_event,
    a.is_abandoned,
    o.label AS resolution_label,
    o.is_resolved,
    o.remedy AS resolution_remedy,
    registry_age.data_as_of AS registry_data_as_of,
    events_age.data_as_of AS events_data_as_of
   FROM (((dephealth.mv_package_current_assessment a
     JOIN dephealth.resolution_outcome o ON ((o.status = a.resolution_status)))
     LEFT JOIN dephealth.v_data_age registry_age ON ((registry_age.source = 'crates_io_dump'::dephealth.data_source)))
     LEFT JOIN dephealth.v_data_age events_age ON ((events_age.source = 'gh_archive'::dephealth.data_source)));


--
-- Name: VIEW v_package_assessment; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_package_assessment IS 'The read-only assessment of one package, with the disclosure threshold applied and the age of both sources attached. The public API role holds this view and no base table.';


--
-- Name: v_report; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_report AS
 SELECT r.id,
    r.token_digest,
    r.created_at,
    r.crates_data_as_of,
    r.events_data_as_of,
    r.abandonment_window_days,
    risk_model.name AS risk_model_name,
    risk_model.version AS risk_model_version,
    fc_model.name AS forecast_model_name,
    fc_model.version AS forecast_model_version,
    r.entry_count,
    r.resolved_count,
    (r.entry_count - r.resolved_count) AS unresolved_count,
    (r.withdrawn_at IS NOT NULL) AS is_withdrawn,
    r.withdrawn_at,
    r.withdrawal_reason
   FROM ((dephealth.report r
     JOIN dephealth.model risk_model ON ((risk_model.id = r.risk_model_id)))
     JOIN dephealth.model fc_model ON ((fc_model.id = r.forecast_model_id)));


--
-- Name: VIEW v_report; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_report IS 'A stored report with the models and the definition it was generated under, so a reader who did not run the assessment can interpret it.';


--
-- Name: v_report_entry; Type: VIEW; Schema: dephealth; Owner: -
--

CREATE VIEW dephealth.v_report_entry AS
 SELECT e.report_id,
    e.ordinal,
    e.package_name,
    e.package_version,
    e.depth,
    e.is_direct,
    e.resolved,
    o.label AS unresolved_label,
    o.remedy AS unresolved_remedy,
    e.risk_probability,
    e.risk_horizon_days,
    e.forecast_point_downloads,
    e.forecast_horizon_months,
    e.insufficient_history,
    dephealth.disclosed_contributors(e.distinct_contributors) AS distinct_contributors,
    e.days_since_last_event,
    e.unresolved_reason,
    ((dephealth.disclosed_contributors(e.distinct_contributors) IS NULL) AND (e.distinct_contributors IS NOT NULL)) AS contributor_count_withheld
   FROM (dephealth.report_entry e
     LEFT JOIN dephealth.resolution_outcome o ON ((o.status = e.unresolved_reason)));


--
-- Name: VIEW v_report_entry; Type: COMMENT; Schema: dephealth; Owner: -
--

COMMENT ON VIEW dephealth.v_report_entry IS 'The lines of a stored report. The disclosure threshold applies here too, so a report is not a route by which a withheld count is published.';


--
-- Name: download_daily_2014; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2014 FOR VALUES FROM ('2014-01-01') TO ('2015-01-01');


--
-- Name: download_daily_2015; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2015 FOR VALUES FROM ('2015-01-01') TO ('2016-01-01');


--
-- Name: download_daily_2016; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2016 FOR VALUES FROM ('2016-01-01') TO ('2017-01-01');


--
-- Name: download_daily_2017; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2017 FOR VALUES FROM ('2017-01-01') TO ('2018-01-01');


--
-- Name: download_daily_2018; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2018 FOR VALUES FROM ('2018-01-01') TO ('2019-01-01');


--
-- Name: download_daily_2019; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2019 FOR VALUES FROM ('2019-01-01') TO ('2020-01-01');


--
-- Name: download_daily_2020; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2020 FOR VALUES FROM ('2020-01-01') TO ('2021-01-01');


--
-- Name: download_daily_2021; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2021 FOR VALUES FROM ('2021-01-01') TO ('2022-01-01');


--
-- Name: download_daily_2022; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2022 FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');


--
-- Name: download_daily_2023; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2023 FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');


--
-- Name: download_daily_2024; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2024 FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');


--
-- Name: download_daily_2025; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2025 FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');


--
-- Name: download_daily_2026; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2026 FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');


--
-- Name: download_daily_2027; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_2027 FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');


--
-- Name: download_daily_unexpected; Type: TABLE ATTACH; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily ATTACH PARTITION dephealth.download_daily_unexpected DEFAULT;


--
-- Name: activity_feature activity_feature_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.activity_feature
    ADD CONSTRAINT activity_feature_pkey PRIMARY KEY (package_id, as_of, window_days);


--
-- Name: adoption_forecast adoption_forecast_package_id_model_id_as_of_horizon_months_key; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.adoption_forecast
    ADD CONSTRAINT adoption_forecast_package_id_model_id_as_of_horizon_months_key UNIQUE (package_id, model_id, as_of, horizon_months);


--
-- Name: adoption_forecast adoption_forecast_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.adoption_forecast
    ADD CONSTRAINT adoption_forecast_pkey PRIMARY KEY (id);


--
-- Name: download_daily download_daily_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily
    ADD CONSTRAINT download_daily_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2014 download_daily_2014_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2014
    ADD CONSTRAINT download_daily_2014_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2015 download_daily_2015_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2015
    ADD CONSTRAINT download_daily_2015_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2016 download_daily_2016_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2016
    ADD CONSTRAINT download_daily_2016_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2017 download_daily_2017_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2017
    ADD CONSTRAINT download_daily_2017_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2018 download_daily_2018_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2018
    ADD CONSTRAINT download_daily_2018_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2019 download_daily_2019_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2019
    ADD CONSTRAINT download_daily_2019_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2020 download_daily_2020_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2020
    ADD CONSTRAINT download_daily_2020_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2021 download_daily_2021_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2021
    ADD CONSTRAINT download_daily_2021_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2022 download_daily_2022_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2022
    ADD CONSTRAINT download_daily_2022_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2023 download_daily_2023_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2023
    ADD CONSTRAINT download_daily_2023_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2024 download_daily_2024_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2024
    ADD CONSTRAINT download_daily_2024_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2025 download_daily_2025_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2025
    ADD CONSTRAINT download_daily_2025_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2026 download_daily_2026_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2026
    ADD CONSTRAINT download_daily_2026_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_2027 download_daily_2027_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_2027
    ADD CONSTRAINT download_daily_2027_pkey PRIMARY KEY (package_id, day);


--
-- Name: download_daily_unexpected download_daily_unexpected_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.download_daily_unexpected
    ADD CONSTRAINT download_daily_unexpected_pkey PRIMARY KEY (package_id, day);


--
-- Name: feature_window feature_window_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.feature_window
    ADD CONSTRAINT feature_window_pkey PRIMARY KEY (days);


--
-- Name: ingestion_run ingestion_run_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.ingestion_run
    ADD CONSTRAINT ingestion_run_pkey PRIMARY KEY (id);


--
-- Name: maintenance_risk maintenance_risk_package_id_model_id_as_of_horizon_days_key; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.maintenance_risk
    ADD CONSTRAINT maintenance_risk_package_id_model_id_as_of_horizon_days_key UNIQUE (package_id, model_id, as_of, horizon_days);


--
-- Name: maintenance_risk maintenance_risk_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.maintenance_risk
    ADD CONSTRAINT maintenance_risk_pkey PRIMARY KEY (id);


--
-- Name: metric_definition metric_definition_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.metric_definition
    ADD CONSTRAINT metric_definition_pkey PRIMARY KEY (code);


--
-- Name: model model_kind_name_version_key; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.model
    ADD CONSTRAINT model_kind_name_version_key UNIQUE (kind, name, version);


--
-- Name: model_metric model_metric_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.model_metric
    ADD CONSTRAINT model_metric_pkey PRIMARY KEY (model_id, metric);


--
-- Name: model model_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.model
    ADD CONSTRAINT model_pkey PRIMARY KEY (id);


--
-- Name: package_dependency package_dependency_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_dependency
    ADD CONSTRAINT package_dependency_pkey PRIMARY KEY (dependent_version_id, dependency_package_id, kind);


--
-- Name: package package_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package
    ADD CONSTRAINT package_pkey PRIMARY KEY (id);


--
-- Name: package_version package_version_package_id_version_key; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_version
    ADD CONSTRAINT package_version_package_id_version_key UNIQUE (package_id, version);


--
-- Name: package_version package_version_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_version
    ADD CONSTRAINT package_version_pkey PRIMARY KEY (id);


--
-- Name: report_entry_factor report_entry_factor_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry_factor
    ADD CONSTRAINT report_entry_factor_pkey PRIMARY KEY (report_id, ordinal, factor);


--
-- Name: report_entry report_entry_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry
    ADD CONSTRAINT report_entry_pkey PRIMARY KEY (report_id, ordinal);


--
-- Name: report report_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report
    ADD CONSTRAINT report_pkey PRIMARY KEY (id);


--
-- Name: report report_token_digest_key; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report
    ADD CONSTRAINT report_token_digest_key UNIQUE (token_digest);


--
-- Name: repository repository_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.repository
    ADD CONSTRAINT repository_pkey PRIMARY KEY (id);


--
-- Name: resolution_outcome resolution_outcome_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.resolution_outcome
    ADD CONSTRAINT resolution_outcome_pkey PRIMARY KEY (status);


--
-- Name: risk_factor_catalogue risk_factor_catalogue_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.risk_factor_catalogue
    ADD CONSTRAINT risk_factor_catalogue_pkey PRIMARY KEY (code);


--
-- Name: risk_factor risk_factor_pkey; Type: CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.risk_factor
    ADD CONSTRAINT risk_factor_pkey PRIMARY KEY (maintenance_risk_id, factor);


--
-- Name: activity_feature_dormant; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX activity_feature_dormant ON dephealth.activity_feature USING btree (package_id, as_of DESC) WHERE (days_since_last_event >= 180);


--
-- Name: activity_feature_recent; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX activity_feature_recent ON dephealth.activity_feature USING btree (as_of DESC, window_days);


--
-- Name: adoption_forecast_serving; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX adoption_forecast_serving ON dephealth.adoption_forecast USING btree (package_id, model_id, as_of DESC);


--
-- Name: ingestion_run_latest_success; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX ingestion_run_latest_success ON dephealth.ingestion_run USING btree (source, data_as_of DESC) WHERE (status = 'succeeded'::dephealth.run_status);


--
-- Name: ingestion_run_one_in_flight_per_source; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX ingestion_run_one_in_flight_per_source ON dephealth.ingestion_run USING btree (source) WHERE (status = 'running'::dephealth.run_status);


--
-- Name: maintenance_risk_ranking; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX maintenance_risk_ranking ON dephealth.maintenance_risk USING btree (as_of DESC, probability DESC);


--
-- Name: maintenance_risk_serving; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX maintenance_risk_serving ON dephealth.maintenance_risk USING btree (package_id, model_id, as_of DESC);


--
-- Name: model_one_baseline_per_kind; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX model_one_baseline_per_kind ON dephealth.model USING btree (kind) WHERE is_baseline;


--
-- Name: model_one_current_per_kind; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX model_one_current_per_kind ON dephealth.model USING btree (kind) WHERE is_current;


--
-- Name: mv_package_current_assessment_name; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX mv_package_current_assessment_name ON dephealth.mv_package_current_assessment USING btree (lower(package_name));


--
-- Name: mv_package_current_assessment_package_id; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX mv_package_current_assessment_package_id ON dephealth.mv_package_current_assessment USING btree (package_id);


--
-- Name: mv_package_current_assessment_risk; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX mv_package_current_assessment_risk ON dephealth.mv_package_current_assessment USING btree (risk_probability DESC NULLS LAST);


--
-- Name: package_by_repository; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX package_by_repository ON dephealth.package USING btree (repository_id) WHERE (repository_id IS NOT NULL);


--
-- Name: package_dependency_by_dependency; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX package_dependency_by_dependency ON dephealth.package_dependency USING btree (dependency_package_id, kind);


--
-- Name: package_identity; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX package_identity ON dephealth.package USING btree (registry, lower(name));


--
-- Name: package_unresolved; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX package_unresolved ON dephealth.package USING btree (resolution_status) WHERE (resolution_status <> 'resolved'::dephealth.resolution_status);


--
-- Name: report_by_fingerprint; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX report_by_fingerprint ON dephealth.report USING btree (manifest_fingerprint, created_at DESC) WHERE (manifest_fingerprint IS NOT NULL);


--
-- Name: report_entry_by_package; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE INDEX report_entry_by_package ON dephealth.report_entry USING btree (lower(package_name));


--
-- Name: report_entry_one_row_per_package_version; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX report_entry_one_row_per_package_version ON dephealth.report_entry USING btree (report_id, lower(package_name), package_version);


--
-- Name: repository_identity; Type: INDEX; Schema: dephealth; Owner: -
--

CREATE UNIQUE INDEX repository_identity ON dephealth.repository USING btree (host, lower(owner), lower(name));


--
-- Name: download_daily_2014_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2014_pkey;


--
-- Name: download_daily_2015_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2015_pkey;


--
-- Name: download_daily_2016_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2016_pkey;


--
-- Name: download_daily_2017_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2017_pkey;


--
-- Name: download_daily_2018_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2018_pkey;


--
-- Name: download_daily_2019_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2019_pkey;


--
-- Name: download_daily_2020_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2020_pkey;


--
-- Name: download_daily_2021_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2021_pkey;


--
-- Name: download_daily_2022_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2022_pkey;


--
-- Name: download_daily_2023_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2023_pkey;


--
-- Name: download_daily_2024_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2024_pkey;


--
-- Name: download_daily_2025_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2025_pkey;


--
-- Name: download_daily_2026_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2026_pkey;


--
-- Name: download_daily_2027_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_2027_pkey;


--
-- Name: download_daily_unexpected_pkey; Type: INDEX ATTACH; Schema: dephealth; Owner: -
--

ALTER INDEX dephealth.download_daily_pkey ATTACH PARTITION dephealth.download_daily_unexpected_pkey;


--
-- Name: activity_feature activity_feature_syncs_repository; Type: TRIGGER; Schema: dephealth; Owner: -
--

CREATE TRIGGER activity_feature_syncs_repository AFTER INSERT OR UPDATE OF days_since_last_event ON dephealth.activity_feature FOR EACH ROW EXECUTE FUNCTION dephealth.sync_repository_last_event();


--
-- Name: report report_counts_match_entries; Type: TRIGGER; Schema: dephealth; Owner: -
--

CREATE CONSTRAINT TRIGGER report_counts_match_entries AFTER INSERT ON dephealth.report DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION dephealth.check_report_counts();


--
-- Name: report_entry_factor report_entry_factor_is_append_only; Type: TRIGGER; Schema: dephealth; Owner: -
--

CREATE TRIGGER report_entry_factor_is_append_only BEFORE DELETE OR UPDATE ON dephealth.report_entry_factor FOR EACH STATEMENT EXECUTE FUNCTION dephealth.reject_mutation();


--
-- Name: report_entry report_entry_is_append_only; Type: TRIGGER; Schema: dephealth; Owner: -
--

CREATE TRIGGER report_entry_is_append_only BEFORE DELETE OR UPDATE ON dephealth.report_entry FOR EACH STATEMENT EXECUTE FUNCTION dephealth.reject_mutation();


--
-- Name: report report_is_immutable_apart_from_withdrawal; Type: TRIGGER; Schema: dephealth; Owner: -
--

CREATE TRIGGER report_is_immutable_apart_from_withdrawal BEFORE DELETE OR UPDATE ON dephealth.report FOR EACH ROW EXECUTE FUNCTION dephealth.guard_report_mutation();


--
-- Name: activity_feature activity_feature_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.activity_feature
    ADD CONSTRAINT activity_feature_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: activity_feature activity_feature_run_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.activity_feature
    ADD CONSTRAINT activity_feature_run_id_fkey FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id);


--
-- Name: activity_feature activity_feature_window_days_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.activity_feature
    ADD CONSTRAINT activity_feature_window_days_fkey FOREIGN KEY (window_days) REFERENCES dephealth.feature_window(days);


--
-- Name: adoption_forecast adoption_forecast_model_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.adoption_forecast
    ADD CONSTRAINT adoption_forecast_model_id_fkey FOREIGN KEY (model_id) REFERENCES dephealth.model(id);


--
-- Name: adoption_forecast adoption_forecast_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.adoption_forecast
    ADD CONSTRAINT adoption_forecast_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: adoption_forecast adoption_forecast_run_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.adoption_forecast
    ADD CONSTRAINT adoption_forecast_run_id_fkey FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id);


--
-- Name: download_daily download_daily_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.download_daily
    ADD CONSTRAINT download_daily_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: download_daily download_daily_run_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE dephealth.download_daily
    ADD CONSTRAINT download_daily_run_id_fkey FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id);


--
-- Name: maintenance_risk maintenance_risk_model_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.maintenance_risk
    ADD CONSTRAINT maintenance_risk_model_id_fkey FOREIGN KEY (model_id) REFERENCES dephealth.model(id);


--
-- Name: maintenance_risk maintenance_risk_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.maintenance_risk
    ADD CONSTRAINT maintenance_risk_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: maintenance_risk maintenance_risk_run_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.maintenance_risk
    ADD CONSTRAINT maintenance_risk_run_id_fkey FOREIGN KEY (run_id) REFERENCES dephealth.ingestion_run(id);


--
-- Name: model_metric model_metric_metric_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.model_metric
    ADD CONSTRAINT model_metric_metric_fkey FOREIGN KEY (metric) REFERENCES dephealth.metric_definition(code);


--
-- Name: model_metric model_metric_model_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.model_metric
    ADD CONSTRAINT model_metric_model_id_fkey FOREIGN KEY (model_id) REFERENCES dephealth.model(id) ON DELETE CASCADE;


--
-- Name: package_dependency package_dependency_dependency_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_dependency
    ADD CONSTRAINT package_dependency_dependency_package_id_fkey FOREIGN KEY (dependency_package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: package_dependency package_dependency_dependent_version_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_dependency
    ADD CONSTRAINT package_dependency_dependent_version_id_fkey FOREIGN KEY (dependent_version_id) REFERENCES dephealth.package_version(id) ON DELETE CASCADE;


--
-- Name: package package_first_seen_run_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package
    ADD CONSTRAINT package_first_seen_run_id_fkey FOREIGN KEY (first_seen_run_id) REFERENCES dephealth.ingestion_run(id);


--
-- Name: package package_repository_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package
    ADD CONSTRAINT package_repository_id_fkey FOREIGN KEY (repository_id) REFERENCES dephealth.repository(id) ON DELETE SET NULL;


--
-- Name: package package_resolution_status_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package
    ADD CONSTRAINT package_resolution_status_fkey FOREIGN KEY (resolution_status) REFERENCES dephealth.resolution_outcome(status);


--
-- Name: package_version package_version_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.package_version
    ADD CONSTRAINT package_version_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE CASCADE;


--
-- Name: report_entry_factor report_entry_factor_factor_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry_factor
    ADD CONSTRAINT report_entry_factor_factor_fkey FOREIGN KEY (factor) REFERENCES dephealth.risk_factor_catalogue(code);


--
-- Name: report_entry_factor report_entry_factor_report_id_ordinal_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry_factor
    ADD CONSTRAINT report_entry_factor_report_id_ordinal_fkey FOREIGN KEY (report_id, ordinal) REFERENCES dephealth.report_entry(report_id, ordinal) ON DELETE RESTRICT;


--
-- Name: report_entry report_entry_package_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry
    ADD CONSTRAINT report_entry_package_id_fkey FOREIGN KEY (package_id) REFERENCES dephealth.package(id) ON DELETE SET NULL;


--
-- Name: report_entry report_entry_report_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry
    ADD CONSTRAINT report_entry_report_id_fkey FOREIGN KEY (report_id) REFERENCES dephealth.report(id) ON DELETE RESTRICT;


--
-- Name: report_entry report_entry_unresolved_reason_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report_entry
    ADD CONSTRAINT report_entry_unresolved_reason_fkey FOREIGN KEY (unresolved_reason) REFERENCES dephealth.resolution_outcome(status);


--
-- Name: report report_forecast_model_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report
    ADD CONSTRAINT report_forecast_model_id_fkey FOREIGN KEY (forecast_model_id) REFERENCES dephealth.model(id);


--
-- Name: report report_risk_model_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.report
    ADD CONSTRAINT report_risk_model_id_fkey FOREIGN KEY (risk_model_id) REFERENCES dephealth.model(id);


--
-- Name: risk_factor risk_factor_factor_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.risk_factor
    ADD CONSTRAINT risk_factor_factor_fkey FOREIGN KEY (factor) REFERENCES dephealth.risk_factor_catalogue(code);


--
-- Name: risk_factor risk_factor_maintenance_risk_id_fkey; Type: FK CONSTRAINT; Schema: dephealth; Owner: -
--

ALTER TABLE ONLY dephealth.risk_factor
    ADD CONSTRAINT risk_factor_maintenance_risk_id_fkey FOREIGN KEY (maintenance_risk_id) REFERENCES dephealth.maintenance_risk(id) ON DELETE CASCADE;


--
-- Name: SCHEMA dephealth; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA dephealth TO dephealth_admin;
GRANT USAGE ON SCHEMA dephealth TO dephealth_ingest;
GRANT USAGE ON SCHEMA dephealth TO dephealth_app;
GRANT USAGE ON SCHEMA dephealth TO dephealth_public_read;


--
-- Name: FUNCTION abandonment_window_days(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.abandonment_window_days() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.abandonment_window_days() TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.abandonment_window_days() TO dephealth_ingest;
GRANT ALL ON FUNCTION dephealth.abandonment_window_days() TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.abandonment_window_days() TO dephealth_public_read;


--
-- Name: FUNCTION check_report_counts(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.check_report_counts() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.check_report_counts() TO dephealth_admin;


--
-- Name: FUNCTION create_report(in_token text, in_salt text, in_entries jsonb); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.create_report(in_token text, in_salt text, in_entries jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.create_report(in_token text, in_salt text, in_entries jsonb) TO dephealth_app;


--
-- Name: FUNCTION k_anonymity_threshold(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.k_anonymity_threshold() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.k_anonymity_threshold() TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.k_anonymity_threshold() TO dephealth_ingest;
GRANT ALL ON FUNCTION dephealth.k_anonymity_threshold() TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.k_anonymity_threshold() TO dephealth_public_read;


--
-- Name: FUNCTION disclosed_contributors(distinct_contributors integer); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) TO dephealth_ingest;
GRANT ALL ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.disclosed_contributors(distinct_contributors integer) TO dephealth_public_read;


--
-- Name: FUNCTION disclosed_share(in_share numeric, in_contributors integer); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer) TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.disclosed_share(in_share numeric, in_contributors integer) TO dephealth_public_read;


--
-- Name: PROCEDURE finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON PROCEDURE dephealth.finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text) FROM PUBLIC;
GRANT ALL ON PROCEDURE dephealth.finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text) TO dephealth_admin;
GRANT ALL ON PROCEDURE dephealth.finish_ingestion_run(IN in_run_id bigint, IN in_status dephealth.run_status, IN in_data_as_of date, IN in_rows_ingested bigint, IN in_rows_rejected bigint, IN in_raw_bytes_discarded bigint, IN in_failure_detail text) TO dephealth_ingest;


--
-- Name: FUNCTION guard_report_mutation(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.guard_report_mutation() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.guard_report_mutation() TO dephealth_admin;


--
-- Name: FUNCTION is_abandoned(days_since_last_event integer); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) TO dephealth_ingest;
GRANT ALL ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.is_abandoned(days_since_last_event integer) TO dephealth_public_read;


--
-- Name: FUNCTION manifest_fingerprint(in_entries text[], in_salt text); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.manifest_fingerprint(in_entries text[], in_salt text) TO dephealth_app;


--
-- Name: FUNCTION previous_report_of(in_token_digest bytea); Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON FUNCTION dephealth.previous_report_of(in_token_digest bytea) TO dephealth_app;


--
-- Name: FUNCTION reject_mutation(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.reject_mutation() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.reject_mutation() TO dephealth_admin;


--
-- Name: FUNCTION report_token_digest(in_token text); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.report_token_digest(in_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.report_token_digest(in_token text) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.report_token_digest(in_token text) TO dephealth_app;
GRANT ALL ON FUNCTION dephealth.report_token_digest(in_token text) TO dephealth_public_read;


--
-- Name: FUNCTION start_ingestion_run(in_source dephealth.data_source); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source) FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source) TO dephealth_admin;
GRANT ALL ON FUNCTION dephealth.start_ingestion_run(in_source dephealth.data_source) TO dephealth_ingest;


--
-- Name: FUNCTION sync_repository_last_event(); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON FUNCTION dephealth.sync_repository_last_event() FROM PUBLIC;
GRANT ALL ON FUNCTION dephealth.sync_repository_last_event() TO dephealth_admin;


--
-- Name: PROCEDURE withdraw_report(IN in_token_digest bytea, IN in_reason text); Type: ACL; Schema: dephealth; Owner: -
--

REVOKE ALL ON PROCEDURE dephealth.withdraw_report(IN in_token_digest bytea, IN in_reason text) FROM PUBLIC;
GRANT ALL ON PROCEDURE dephealth.withdraw_report(IN in_token_digest bytea, IN in_reason text) TO dephealth_admin;
GRANT ALL ON PROCEDURE dephealth.withdraw_report(IN in_token_digest bytea, IN in_reason text) TO dephealth_app;


--
-- Name: TABLE activity_feature; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.activity_feature TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.activity_feature TO dephealth_ingest;


--
-- Name: TABLE adoption_forecast; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.adoption_forecast TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.adoption_forecast TO dephealth_ingest;


--
-- Name: SEQUENCE adoption_forecast_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.adoption_forecast_id_seq TO dephealth_admin;


--
-- Name: TABLE download_daily; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.download_daily TO dephealth_ingest;


--
-- Name: TABLE download_daily_2014; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2014 TO dephealth_admin;


--
-- Name: TABLE download_daily_2015; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2015 TO dephealth_admin;


--
-- Name: TABLE download_daily_2016; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2016 TO dephealth_admin;


--
-- Name: TABLE download_daily_2017; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2017 TO dephealth_admin;


--
-- Name: TABLE download_daily_2018; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2018 TO dephealth_admin;


--
-- Name: TABLE download_daily_2019; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2019 TO dephealth_admin;


--
-- Name: TABLE download_daily_2020; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2020 TO dephealth_admin;


--
-- Name: TABLE download_daily_2021; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2021 TO dephealth_admin;


--
-- Name: TABLE download_daily_2022; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2022 TO dephealth_admin;


--
-- Name: TABLE download_daily_2023; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2023 TO dephealth_admin;


--
-- Name: TABLE download_daily_2024; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2024 TO dephealth_admin;


--
-- Name: TABLE download_daily_2025; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2025 TO dephealth_admin;


--
-- Name: TABLE download_daily_2026; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2026 TO dephealth_admin;


--
-- Name: TABLE download_daily_2027; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_2027 TO dephealth_admin;


--
-- Name: TABLE download_daily_unexpected; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.download_daily_unexpected TO dephealth_admin;


--
-- Name: TABLE feature_window; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.feature_window TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.feature_window TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.feature_window TO dephealth_app;


--
-- Name: TABLE ingestion_run; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.ingestion_run TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.ingestion_run TO dephealth_ingest;


--
-- Name: SEQUENCE ingestion_run_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.ingestion_run_id_seq TO dephealth_admin;


--
-- Name: TABLE maintenance_risk; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.maintenance_risk TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.maintenance_risk TO dephealth_ingest;


--
-- Name: SEQUENCE maintenance_risk_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.maintenance_risk_id_seq TO dephealth_admin;


--
-- Name: TABLE metric_definition; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.metric_definition TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.metric_definition TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.metric_definition TO dephealth_app;


--
-- Name: TABLE model; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.model TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.model TO dephealth_ingest;


--
-- Name: SEQUENCE model_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.model_id_seq TO dephealth_admin;


--
-- Name: TABLE model_metric; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.model_metric TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.model_metric TO dephealth_ingest;


--
-- Name: TABLE package; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.package TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.package TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.package TO dephealth_app;


--
-- Name: TABLE repository; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.repository TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.repository TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.repository TO dephealth_app;


--
-- Name: TABLE mv_package_current_assessment; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.mv_package_current_assessment TO dephealth_admin;


--
-- Name: TABLE package_dependency; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.package_dependency TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.package_dependency TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.package_dependency TO dephealth_app;


--
-- Name: SEQUENCE package_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.package_id_seq TO dephealth_admin;


--
-- Name: TABLE package_version; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.package_version TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.package_version TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.package_version TO dephealth_app;


--
-- Name: SEQUENCE package_version_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.package_version_id_seq TO dephealth_admin;


--
-- Name: TABLE report; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.report TO dephealth_admin;
GRANT SELECT,INSERT ON TABLE dephealth.report TO dephealth_app;


--
-- Name: COLUMN report.withdrawn_at; Type: ACL; Schema: dephealth; Owner: -
--

GRANT UPDATE(withdrawn_at) ON TABLE dephealth.report TO dephealth_app;


--
-- Name: COLUMN report.withdrawal_reason; Type: ACL; Schema: dephealth; Owner: -
--

GRANT UPDATE(withdrawal_reason) ON TABLE dephealth.report TO dephealth_app;


--
-- Name: TABLE report_entry; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.report_entry TO dephealth_admin;
GRANT SELECT,INSERT ON TABLE dephealth.report_entry TO dephealth_app;


--
-- Name: TABLE report_entry_factor; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.report_entry_factor TO dephealth_admin;
GRANT SELECT,INSERT ON TABLE dephealth.report_entry_factor TO dephealth_app;


--
-- Name: SEQUENCE report_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.report_id_seq TO dephealth_admin;
GRANT USAGE ON SEQUENCE dephealth.report_id_seq TO dephealth_app;


--
-- Name: SEQUENCE repository_id_seq; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON SEQUENCE dephealth.repository_id_seq TO dephealth_admin;


--
-- Name: TABLE resolution_outcome; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.resolution_outcome TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.resolution_outcome TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.resolution_outcome TO dephealth_app;


--
-- Name: TABLE risk_factor; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.risk_factor TO dephealth_admin;
GRANT SELECT,INSERT,UPDATE ON TABLE dephealth.risk_factor TO dephealth_ingest;


--
-- Name: TABLE risk_factor_catalogue; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.risk_factor_catalogue TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.risk_factor_catalogue TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.risk_factor_catalogue TO dephealth_app;


--
-- Name: TABLE v_data_age; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_data_age TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_data_age TO dephealth_ingest;
GRANT SELECT ON TABLE dephealth.v_data_age TO dephealth_app;
GRANT SELECT ON TABLE dephealth.v_data_age TO dephealth_public_read;


--
-- Name: TABLE v_data_quality_finding; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_data_quality_finding TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_data_quality_finding TO dephealth_ingest;


--
-- Name: TABLE v_download_series; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_download_series TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_download_series TO dephealth_app;
GRANT SELECT ON TABLE dephealth.v_download_series TO dephealth_public_read;


--
-- Name: TABLE v_kpi1_resolution; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_kpi1_resolution TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_kpi1_resolution TO dephealth_ingest;


--
-- Name: TABLE v_kpi1_resolution_by_reason; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_kpi1_resolution_by_reason TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_kpi1_resolution_by_reason TO dephealth_ingest;


--
-- Name: TABLE v_model_against_baseline; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_model_against_baseline TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_model_against_baseline TO dephealth_ingest;


--
-- Name: TABLE v_package_assessment; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_package_assessment TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_package_assessment TO dephealth_app;
GRANT SELECT ON TABLE dephealth.v_package_assessment TO dephealth_public_read;


--
-- Name: TABLE v_report; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_report TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_report TO dephealth_app;
GRANT SELECT ON TABLE dephealth.v_report TO dephealth_public_read;


--
-- Name: TABLE v_report_entry; Type: ACL; Schema: dephealth; Owner: -
--

GRANT ALL ON TABLE dephealth.v_report_entry TO dephealth_admin;
GRANT SELECT ON TABLE dephealth.v_report_entry TO dephealth_app;
GRANT SELECT ON TABLE dephealth.v_report_entry TO dephealth_public_read;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: dephealth; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE dephealth_owner IN SCHEMA dephealth GRANT ALL ON SEQUENCES TO dephealth_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: dephealth; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE dephealth_owner IN SCHEMA dephealth GRANT ALL ON TABLES TO dephealth_admin;


--
-- PostgreSQL database dump complete
--

