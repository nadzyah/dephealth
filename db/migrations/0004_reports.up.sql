-- 0004 stored reports

-- A snapshot rather than a view over the live scores. UC2 needs the figures
-- the report held when it was generated, and each run overwrites those
CREATE TABLE dephealth.report (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- digest only, so a dump of this table yields no working links
    token_digest            bytea NOT NULL UNIQUE,

    -- recognises a resubmission for US11 without keeping the manifest
    manifest_fingerprint    bytea,

    created_at              timestamptz NOT NULL DEFAULT now(),

    crates_data_as_of       date NOT NULL,
    events_data_as_of       date NOT NULL,

    abandonment_window_days integer NOT NULL CHECK (abandonment_window_days > 0),
    risk_model_id           bigint NOT NULL REFERENCES dephealth.model (id),
    forecast_model_id       bigint NOT NULL REFERENCES dephealth.model (id),

    entry_count             integer NOT NULL CHECK (entry_count > 0),
    resolved_count          integer NOT NULL CHECK (resolved_count >= 0),

    -- withdrawal keeps the row, so a removed report differs from a link that
    -- never existed
    withdrawn_at            timestamptz,
    withdrawal_reason       text,

    CONSTRAINT report_token_digest_is_sha256 CHECK (length(token_digest) = 32),
    CONSTRAINT report_fingerprint_is_sha256 CHECK (
        manifest_fingerprint IS NULL OR length(manifest_fingerprint) = 32
    ),
    CONSTRAINT report_resolved_within_total CHECK (resolved_count <= entry_count),
    CONSTRAINT report_withdrawal_coherent CHECK (
        (withdrawn_at IS NULL) = (withdrawal_reason IS NULL)
    ),
    CONSTRAINT report_withdrawn_after_created CHECK (
        withdrawn_at IS NULL OR withdrawn_at >= created_at
    )
);

COMMENT ON TABLE dephealth.report IS
    'One generated assessment, addressable by a permanent link. Append only except for withdrawal, enforced by trigger and by column level privileges.';

COMMENT ON COLUMN dephealth.report.token_digest IS
    'SHA-256 of the random token in the permanent link. The token is never stored, so links cannot be recovered from a database dump.';

COMMENT ON COLUMN dephealth.report.manifest_fingerprint IS
    'Salted SHA-256 of the sorted name@version set. Lets a resubmission be recognised without retaining the manifest.';

CREATE INDEX report_by_fingerprint
    ON dephealth.report (manifest_fingerprint, created_at DESC)
    WHERE manifest_fingerprint IS NOT NULL;

-- Report entries, append only. The values are copies by design

CREATE TABLE dephealth.report_entry (
    report_id                bigint  NOT NULL REFERENCES dephealth.report (id) ON DELETE RESTRICT,
    ordinal                  integer NOT NULL CHECK (ordinal > 0),

    package_name             text    NOT NULL,
    package_version          text    NOT NULL,
    depth                    integer NOT NULL CHECK (depth >= 0),
    is_direct                boolean NOT NULL,

    package_id               bigint  REFERENCES dephealth.package (id) ON DELETE SET NULL,
    resolved                 boolean NOT NULL,
    unresolved_reason        dephealth.resolution_status
                                 REFERENCES dephealth.resolution_outcome (status),

    risk_probability         numeric(5,4) CHECK (risk_probability >= 0 AND risk_probability <= 1),
    risk_horizon_days        integer CHECK (risk_horizon_days > 0),
    forecast_point_downloads numeric(14,2) CHECK (forecast_point_downloads >= 0),
    forecast_horizon_months  integer CHECK (forecast_horizon_months BETWEEN 3 AND 12),
    insufficient_history     boolean NOT NULL DEFAULT false,

    distinct_contributors    integer CHECK (distinct_contributors >= 0),
    days_since_last_event    integer CHECK (days_since_last_event >= 0),

    PRIMARY KEY (report_id, ordinal),

    CONSTRAINT report_entry_name_present CHECK (length(btrim(package_name)) > 0),
    CONSTRAINT report_entry_version_present CHECK (length(btrim(package_version)) > 0),
    CONSTRAINT report_entry_direct_matches_depth CHECK (is_direct = (depth = 0)),

    CONSTRAINT report_entry_resolution_coherent CHECK (
        (resolved
             AND unresolved_reason IS NULL
             AND risk_probability IS NOT NULL
             AND risk_horizon_days IS NOT NULL)
        OR
        (NOT resolved
             AND unresolved_reason IS NOT NULL
             AND risk_probability IS NULL
             AND risk_horizon_days IS NULL)
    ),
    CONSTRAINT report_entry_forecast_coherent CHECK (
        (insufficient_history AND forecast_point_downloads IS NULL)
        OR NOT insufficient_history
    )
);

COMMENT ON TABLE dephealth.report_entry IS
    'One line of a stored report, holding the figures as they stood when it was generated. Append only, so a report filed as evidence does not change when the next run overwrites the live scores.';

CREATE UNIQUE INDEX report_entry_one_row_per_package_version
    ON dephealth.report_entry (report_id, lower(package_name), package_version);

CREATE INDEX report_entry_by_package
    ON dephealth.report_entry (lower(package_name));

-- Stored factor decomposition

CREATE TABLE dephealth.report_entry_factor (
    report_id      bigint  NOT NULL,
    ordinal        integer NOT NULL,
    factor         text    NOT NULL REFERENCES dephealth.risk_factor_catalogue (code),
    observed_value numeric NOT NULL,
    contribution   numeric NOT NULL,

    PRIMARY KEY (report_id, ordinal, factor),
    FOREIGN KEY (report_id, ordinal)
        REFERENCES dephealth.report_entry (report_id, ordinal) ON DELETE RESTRICT
);

COMMENT ON TABLE dephealth.report_entry_factor IS
    'The factor decomposition as it stood when the report was generated, so the evidence behind a filed score is as durable as the score. A child table rather than a document column, since it is read as rows ordered by contribution.';
