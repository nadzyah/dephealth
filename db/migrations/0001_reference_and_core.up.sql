-- 0001 reference data and core entities

CREATE SCHEMA dephealth;

COMMENT ON SCHEMA dephealth IS
    'Application schema of dephealth. Holds aggregated, non-identifying data only.';

-- Domains

CREATE TYPE dephealth.data_source AS ENUM ('crates_io_dump', 'gh_archive');

CREATE TYPE dephealth.run_status AS ENUM ('running', 'succeeded', 'failed');

CREATE TYPE dephealth.dependency_kind AS ENUM ('normal', 'build', 'dev');

CREATE TYPE dephealth.resolution_status AS ENUM (
    'resolved',
    'no_url_declared',
    'url_unparseable',
    'host_unsupported',
    'repository_unreachable'
);

CREATE TYPE dephealth.resolution_method AS ENUM (
    'declared_url',
    'dump_metadata',
    'manual_override'
);

-- Reference tables (fixed data, loaded by db/seed/reference.sql)

CREATE TABLE dephealth.resolution_outcome (
    status      dephealth.resolution_status PRIMARY KEY,
    label       text    NOT NULL,
    is_resolved boolean NOT NULL,
    remedy      text    NOT NULL,

    CONSTRAINT resolution_outcome_label_present CHECK (length(btrim(label)) > 0)
);

COMMENT ON TABLE dephealth.resolution_outcome IS
    'Reference table, one row per value of dephealth.resolution_status.';

CREATE TABLE dephealth.feature_window (
    days  integer PRIMARY KEY,
    label text    NOT NULL,

    CONSTRAINT feature_window_positive CHECK (days > 0),
    CONSTRAINT feature_window_label_present CHECK (length(btrim(label)) > 0)
);

COMMENT ON TABLE dephealth.feature_window IS
    'Reference table of the trailing windows contributor activity is aggregated over. Adding one changes what the model is trained on, so it takes a migration.';

-- Ingestion runs

CREATE TABLE dephealth.ingestion_run (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source              dephealth.data_source NOT NULL,
    status              dephealth.run_status  NOT NULL DEFAULT 'running',
    started_at          timestamptz NOT NULL DEFAULT now(),
    finished_at         timestamptz,
    data_as_of          date,
    window_start        date,
    window_end          date,
    rows_ingested       bigint NOT NULL DEFAULT 0 CHECK (rows_ingested >= 0),
    rows_rejected       bigint NOT NULL DEFAULT 0 CHECK (rows_rejected >= 0),
    raw_bytes_discarded bigint CHECK (raw_bytes_discarded >= 0),
    failure_detail      text,

    CONSTRAINT ingestion_run_finished_with_status CHECK (
        (status = 'running') = (finished_at IS NULL)
    ),
    CONSTRAINT ingestion_run_failure_detail_with_failure CHECK (
        (status = 'failed') = (failure_detail IS NOT NULL)
    ),
    CONSTRAINT ingestion_run_success_has_as_of CHECK (
        status <> 'succeeded' OR data_as_of IS NOT NULL
    ),
    CONSTRAINT ingestion_run_window_ordered CHECK (
        window_start IS NULL OR window_end IS NULL OR window_start <= window_end
    ),
    CONSTRAINT ingestion_run_finished_after_start CHECK (
        finished_at IS NULL OR finished_at >= started_at
    )
);

COMMENT ON TABLE dephealth.ingestion_run IS
    'One pass over one source. Every derived row names the run that produced it, so the age of a served figure is answerable and a bad run is reversible.';

-- One run per source at a time, so a delayed run is not overtaken
CREATE UNIQUE INDEX ingestion_run_one_in_flight_per_source
    ON dephealth.ingestion_run (source)
    WHERE status = 'running';

CREATE INDEX ingestion_run_latest_success
    ON dephealth.ingestion_run (source, data_as_of DESC)
    WHERE status = 'succeeded';

-- Source repositories

CREATE TABLE dephealth.repository (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    host          text NOT NULL,
    owner         text NOT NULL,
    name          text NOT NULL,
    canonical_url text NOT NULL,
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_event_on date,

    CONSTRAINT repository_host_supported CHECK (host = 'github.com'),
    CONSTRAINT repository_owner_present CHECK (length(btrim(owner)) > 0),
    CONSTRAINT repository_name_present CHECK (length(btrim(name)) > 0),
    CONSTRAINT repository_url_wellformed CHECK (canonical_url ~ '^https://[a-z0-9.-]+/[^/]+/[^/]+$')
);

-- GitHub folds case in owner and name, so identity has to fold it too
CREATE UNIQUE INDEX repository_identity
    ON dephealth.repository (host, lower(owner), lower(name));

-- Registry packages

CREATE TABLE dephealth.package (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registry          text NOT NULL DEFAULT 'crates.io',
    name              text NOT NULL,
    created_on        date,
    latest_version    text,
    repository_id     bigint REFERENCES dephealth.repository (id) ON DELETE SET NULL,
    resolution_status dephealth.resolution_status NOT NULL
                          REFERENCES dephealth.resolution_outcome (status),
    resolution_method dephealth.resolution_method,
    resolution_detail text,
    resolved_at       timestamptz,
    first_seen_run_id bigint NOT NULL REFERENCES dephealth.ingestion_run (id),

    CONSTRAINT package_registry_supported CHECK (registry = 'crates.io'),
    CONSTRAINT package_name_wellformed CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'),

    -- A repository with its method and date, or neither plus a reason
    CONSTRAINT package_resolution_coherent CHECK (
        (resolution_status = 'resolved'
             AND repository_id IS NOT NULL
             AND resolution_method IS NOT NULL
             AND resolved_at IS NOT NULL)
        OR
        (resolution_status <> 'resolved'
             AND repository_id IS NULL
             AND resolution_method IS NULL
             AND resolved_at IS NULL)
    )
);

COMMENT ON TABLE dephealth.package IS
    'One package in the registry. The resolution columns record whether it reached a source repository and, if not, why. KPI1 is read from them.';

CREATE UNIQUE INDEX package_identity
    ON dephealth.package (registry, lower(name));

CREATE INDEX package_by_repository
    ON dephealth.package (repository_id)
    WHERE repository_id IS NOT NULL;

CREATE INDEX package_unresolved
    ON dephealth.package (resolution_status)
    WHERE resolution_status <> 'resolved';

-- Published versions

CREATE TABLE dephealth.package_version (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    package_id   bigint NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    version      text   NOT NULL,
    published_at timestamptz,
    yanked       boolean NOT NULL DEFAULT false,

    CONSTRAINT package_version_present CHECK (length(btrim(version)) > 0),
    UNIQUE (package_id, version)
);

COMMENT ON TABLE dephealth.package_version IS
    'Published versions. A lockfile entry names a version rather than a package, and the first publication date bounds how much history a forecast can rest on.';

-- Dependency edges, walked to expand a manifest into its transitive tree

CREATE TABLE dephealth.package_dependency (
    dependent_version_id  bigint NOT NULL REFERENCES dephealth.package_version (id) ON DELETE CASCADE,
    dependency_package_id bigint NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    kind                  dephealth.dependency_kind NOT NULL,
    requirement           text    NOT NULL,
    optional              boolean NOT NULL DEFAULT false,

    PRIMARY KEY (dependent_version_id, dependency_package_id, kind),

    CONSTRAINT package_dependency_requirement_present CHECK (length(btrim(requirement)) > 0)
);

COMMENT ON TABLE dephealth.package_dependency IS
    'Dependency edges from a published version to a required package. The development kind is left out of a consumer tree, since a consumer does not build the test suite of its dependencies.';

-- The primary key covers the forward walk, this one the reverse
CREATE INDEX package_dependency_by_dependency
    ON dephealth.package_dependency (dependency_package_id, kind);
