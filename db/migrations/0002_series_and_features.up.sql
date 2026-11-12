-- 0002 behavioural series and derived features

-- Daily downloads per package

-- Written one day at a time, read one window at a time, and retention is a
-- partition drop
CREATE TABLE dephealth.download_daily (
    package_id bigint NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    day        date   NOT NULL,
    downloads  bigint NOT NULL CHECK (downloads >= 0),
    run_id     bigint NOT NULL REFERENCES dephealth.ingestion_run (id),

    PRIMARY KEY (package_id, day)
) PARTITION BY RANGE (day);

COMMENT ON TABLE dephealth.download_daily IS
    'Downloads per package per day. The registry publishes the figure per version, and the versions are summed on load, since every requirement is stated at the level of the package.';

CREATE TABLE dephealth.download_daily_2014 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2014-01-01') TO ('2015-01-01');
CREATE TABLE dephealth.download_daily_2015 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2015-01-01') TO ('2016-01-01');
CREATE TABLE dephealth.download_daily_2016 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2016-01-01') TO ('2017-01-01');
CREATE TABLE dephealth.download_daily_2017 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2017-01-01') TO ('2018-01-01');
CREATE TABLE dephealth.download_daily_2018 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2018-01-01') TO ('2019-01-01');
CREATE TABLE dephealth.download_daily_2019 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2019-01-01') TO ('2020-01-01');
CREATE TABLE dephealth.download_daily_2020 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2020-01-01') TO ('2021-01-01');
CREATE TABLE dephealth.download_daily_2021 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2021-01-01') TO ('2022-01-01');
CREATE TABLE dephealth.download_daily_2022 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2022-01-01') TO ('2023-01-01');
CREATE TABLE dephealth.download_daily_2023 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE dephealth.download_daily_2024 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE dephealth.download_daily_2025 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE dephealth.download_daily_2026 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE dephealth.download_daily_2027 PARTITION OF dephealth.download_daily
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

-- Quarantine. A day outside the declared range is a defect in the dump
CREATE TABLE dephealth.download_daily_unexpected
    PARTITION OF dephealth.download_daily DEFAULT;

COMMENT ON TABLE dephealth.download_daily_unexpected IS
    'Quarantine partition. Any row here is a data quality finding, not data to be served.';

-- Contributor activity, aggregated to the package

CREATE TABLE dephealth.activity_feature (
    package_id            bigint  NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    as_of                 date    NOT NULL,
    window_days           integer NOT NULL REFERENCES dephealth.feature_window (days),
    distinct_contributors integer NOT NULL CHECK (distinct_contributors >= 0),
    event_count           integer NOT NULL CHECK (event_count >= 0),
    commit_event_count    integer NOT NULL CHECK (commit_event_count >= 0),
    issue_event_count     integer NOT NULL CHECK (issue_event_count >= 0),
    review_event_count    integer NOT NULL CHECK (review_event_count >= 0),
    days_since_last_event integer CHECK (days_since_last_event >= 0),
    -- how concentrated the work was, not who did it
    top_contributor_share numeric(4,3)
                              CHECK (top_contributor_share > 0 AND top_contributor_share <= 1),
    run_id                bigint  NOT NULL REFERENCES dephealth.ingestion_run (id),

    PRIMARY KEY (package_id, as_of, window_days),

    CONSTRAINT activity_feature_parts_within_total CHECK (
        commit_event_count + issue_event_count + review_event_count <= event_count
    ),
    CONSTRAINT activity_feature_events_need_a_contributor CHECK (
        (event_count = 0) = (distinct_contributors = 0)
    ),
    CONSTRAINT activity_feature_contributors_within_events CHECK (
        distinct_contributors <= event_count
    ),
    CONSTRAINT activity_feature_share_with_events CHECK (
        (event_count = 0) = (top_contributor_share IS NULL)
    ),
    -- with n contributors the most active one holds at least a 1/n share
    CONSTRAINT activity_feature_share_at_least_even CHECK (
        top_contributor_share IS NULL
        OR top_contributor_share >= 1.0 / distinct_contributors - 0.001
    )
);

COMMENT ON TABLE dephealth.activity_feature IS
    'Contributor activity aggregated to the package over a trailing window. The data protection boundary of the system. The raw events identify accounts, these rows hold counts, and the raw files are deleted once a run has produced them.';

COMMENT ON COLUMN dephealth.activity_feature.distinct_contributors IS
    'Accounts that produced at least one event in the window. Published through the read-only views only at or above dephealth.k_anonymity_threshold().';

COMMENT ON COLUMN dephealth.activity_feature.days_since_last_event IS
    'Days between as_of and the most recent development event. The abandonment label derives from this column at 180 days.';

CREATE INDEX activity_feature_recent
    ON dephealth.activity_feature (as_of DESC, window_days);

CREATE INDEX activity_feature_dormant
    ON dephealth.activity_feature (package_id, as_of DESC)
    WHERE days_since_last_event >= 180;

-- Disclosure threshold. The model keeps using the raw counts

CREATE FUNCTION dephealth.k_anonymity_threshold() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    RETURN 5;

COMMENT ON FUNCTION dephealth.k_anonymity_threshold() IS
    'Smallest contributor count publishable through a read-only view. A migration rather than a setting, so the value in force on any date is in the schema history.';
