-- 0003 models and their outputs

CREATE TYPE dephealth.model_kind AS ENUM (
    'adoption_forecast',
    'maintenance_risk',
    'download_anomaly'
);

-- Reference data

CREATE TABLE dephealth.metric_definition (
    code            text    PRIMARY KEY,
    label           text    NOT NULL,
    unit            text    NOT NULL,
    lower_is_better boolean NOT NULL,
    kpi             text,

    CONSTRAINT metric_definition_code_wellformed CHECK (code ~ '^[a-z][a-z0-9_]{2,31}$'),
    CONSTRAINT metric_definition_label_present CHECK (length(btrim(label)) > 0),
    CONSTRAINT metric_definition_kpi_wellformed CHECK (kpi IS NULL OR kpi ~ '^KPI[1-9]$')
);

COMMENT ON TABLE dephealth.metric_definition IS
    'Reference table of evaluation metrics. The kpi column links a measured number to the indicator it reports against.';

CREATE TABLE dephealth.risk_factor_catalogue (
    code              text    PRIMARY KEY,
    label             text    NOT NULL,
    description       text    NOT NULL,
    higher_is_riskier boolean NOT NULL,

    CONSTRAINT risk_factor_code_wellformed CHECK (code ~ '^[a-z][a-z0-9_]{2,39}$'),
    CONSTRAINT risk_factor_label_present CHECK (length(btrim(label)) > 0),
    CONSTRAINT risk_factor_description_present CHECK (length(btrim(description)) > 0)
);

COMMENT ON TABLE dephealth.risk_factor_catalogue IS
    'Reference table of the factors a risk score may be decomposed into. A factor takes a migration, since an explanation has to be describable in words before it is shown.';

-- Fitted models, baselines included, so KPI3 and KPI4 read both sides of the
-- comparison from model_metric

CREATE TABLE dephealth.model (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind               dephealth.model_kind NOT NULL,
    name               text NOT NULL,
    version            text NOT NULL,
    is_baseline        boolean NOT NULL DEFAULT false,
    is_current         boolean NOT NULL DEFAULT false,
    trained_at         timestamptz NOT NULL,
    train_window_start date NOT NULL,
    train_window_end   date NOT NULL,
    -- the only jsonb column. Keys differ per model family and nothing joins
    -- on them
    hyperparameters    jsonb NOT NULL DEFAULT '{}'::jsonb,

    UNIQUE (kind, name, version),

    CONSTRAINT model_name_present CHECK (length(btrim(name)) > 0),
    CONSTRAINT model_version_present CHECK (length(btrim(version)) > 0),
    CONSTRAINT model_train_window_ordered CHECK (train_window_start < train_window_end),
    CONSTRAINT model_hyperparameters_is_object CHECK (jsonb_typeof(hyperparameters) = 'object'),
    CONSTRAINT model_baseline_never_current CHECK (NOT (is_baseline AND is_current))
);

COMMENT ON TABLE dephealth.model IS
    'One fitted model. A baseline is a model row rather than a constant, so one metric table measures both sides of the comparison.';

-- One serving model and one baseline per kind
CREATE UNIQUE INDEX model_one_current_per_kind
    ON dephealth.model (kind)
    WHERE is_current;

CREATE UNIQUE INDEX model_one_baseline_per_kind
    ON dephealth.model (kind)
    WHERE is_baseline;

CREATE TABLE dephealth.model_metric (
    model_id              bigint  NOT NULL REFERENCES dephealth.model (id) ON DELETE CASCADE,
    metric                text    NOT NULL REFERENCES dephealth.metric_definition (code),
    value                 numeric NOT NULL,
    evaluated_on_packages integer NOT NULL CHECK (evaluated_on_packages > 0),
    evaluated_at          timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (model_id, metric)
);

COMMENT ON TABLE dephealth.model_metric IS
    'Held-out metrics per model. KPI3 and KPI4 compare the current model with the baseline of the same kind.';

-- Adoption forecasts

CREATE TABLE dephealth.adoption_forecast (
    id                   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    package_id           bigint  NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    model_id             bigint  NOT NULL REFERENCES dephealth.model (id),
    run_id               bigint  NOT NULL REFERENCES dephealth.ingestion_run (id),
    as_of                date    NOT NULL,
    horizon_months       integer NOT NULL,
    point_downloads      numeric(14,2) CHECK (point_downloads >= 0),
    lower_downloads      numeric(14,2) CHECK (lower_downloads >= 0),
    upper_downloads      numeric(14,2) CHECK (upper_downloads >= 0),
    history_days         integer NOT NULL CHECK (history_days >= 0),
    insufficient_history boolean NOT NULL,

    UNIQUE (package_id, model_id, as_of, horizon_months),

    CONSTRAINT forecast_horizon_in_range CHECK (horizon_months BETWEEN 3 AND 12),

    -- derived from the history, not set by the caller: a series shorter than
    -- twelve months cannot carry a forecast
    CONSTRAINT forecast_history_rule CHECK (
        insufficient_history = (history_days < 365)
    ),
    CONSTRAINT forecast_absent_when_history_insufficient CHECK (
        (insufficient_history
             AND point_downloads IS NULL
             AND lower_downloads IS NULL
             AND upper_downloads IS NULL)
        OR
        (NOT insufficient_history AND point_downloads IS NOT NULL)
    ),
    CONSTRAINT forecast_interval_ordered CHECK (
        lower_downloads IS NULL
        OR upper_downloads IS NULL
        OR (lower_downloads <= point_downloads AND point_downloads <= upper_downloads)
    )
);

COMMENT ON TABLE dephealth.adoption_forecast IS
    'Forecast adoption per package and horizon, computed offline. A row with insufficient_history set records that no forecast was produced, which differs from a forecast being absent.';

CREATE INDEX adoption_forecast_serving
    ON dephealth.adoption_forecast (package_id, model_id, as_of DESC);

-- Maintenance risk

CREATE TABLE dephealth.maintenance_risk (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    package_id              bigint  NOT NULL REFERENCES dephealth.package (id) ON DELETE CASCADE,
    model_id                bigint  NOT NULL REFERENCES dephealth.model (id),
    run_id                  bigint  NOT NULL REFERENCES dephealth.ingestion_run (id),
    as_of                   date    NOT NULL,
    horizon_days            integer NOT NULL CHECK (horizon_days > 0),
    probability             numeric(5,4) NOT NULL CHECK (probability >= 0 AND probability <= 1),
    abandonment_window_days integer NOT NULL DEFAULT 180 CHECK (abandonment_window_days > 0),

    UNIQUE (package_id, model_id, as_of, horizon_days)
);

COMMENT ON TABLE dephealth.maintenance_risk IS
    'Probability that a package loses its active maintainers within the horizon, computed offline. numeric rather than float, since the figure is quoted in a stored report and has to round identically on every read.';

CREATE INDEX maintenance_risk_ranking
    ON dephealth.maintenance_risk (as_of DESC, probability DESC);

CREATE INDEX maintenance_risk_serving
    ON dephealth.maintenance_risk (package_id, model_id, as_of DESC);

CREATE TABLE dephealth.risk_factor (
    maintenance_risk_id bigint  NOT NULL REFERENCES dephealth.maintenance_risk (id) ON DELETE CASCADE,
    factor              text    NOT NULL REFERENCES dephealth.risk_factor_catalogue (code),
    observed_value      numeric NOT NULL,
    contribution        numeric NOT NULL,

    PRIMARY KEY (maintenance_risk_id, factor)
);

COMMENT ON TABLE dephealth.risk_factor IS
    'Decomposition of one risk score into named factors. Shown in the detail view, which is what makes the score evidence rather than a number.';
