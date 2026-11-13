-- Test data. Synthetic, but shaped like the real thing and chosen so every
-- branch the interface handles is present.
--
--   serde, tokio, clap    healthy packages with three years of history
--   failure               a real abandoned crate, silent for years, high risk
--   tiny-config           younger than twelve months, so no forecast is produced
--   solo-crate            two contributors, so the count is withheld on display
--   urlless-crate         no repository declared in the registry
--   gitlab-crate          repository hosted outside GitHub
--   vanished-crate        declared repository no longer reachable
--
-- The download series use a deterministic pseudo-noise term, so two loads
-- produce the same numbers. Run db/seed/reference.sql first.

BEGIN;

-- Ingestion runs

INSERT INTO dephealth.ingestion_run
    (source, status, started_at, finished_at, data_as_of,
     window_start, window_end, rows_ingested, rows_rejected, raw_bytes_discarded)
VALUES
    ('crates_io_dump', 'succeeded',
     now() - interval '7 hours', now() - interval '6 hours', current_date - 1,
     current_date - 1, current_date - 1, 5235, 0, NULL),
    ('gh_archive', 'succeeded',
     now() - interval '6 hours', now() - interval '3 hours', current_date - 1,
     current_date - 365, current_date - 1, 48213, 117, 44739242496);

-- A failed run for the degradation path. Older than the successful one.
INSERT INTO dephealth.ingestion_run
    (source, status, started_at, finished_at, data_as_of,
     window_start, window_end, rows_ingested, failure_detail)
VALUES
    ('gh_archive', 'failed',
     now() - interval '31 hours', now() - interval '30 hours', NULL,
     current_date - 2, current_date - 2, 0,
     'archive for 2 of the 24 hourly files returned 404; run abandoned rather than loading a partial day');

-- Repositories

INSERT INTO dephealth.repository (host, owner, name, canonical_url, first_seen_at) VALUES
    ('github.com', 'serde-rs',          'serde',       'https://github.com/serde-rs/serde',              now() - interval '2 years'),
    ('github.com', 'tokio-rs',          'tokio',       'https://github.com/tokio-rs/tokio',              now() - interval '2 years'),
    ('github.com', 'clap-rs',           'clap',        'https://github.com/clap-rs/clap',                now() - interval '2 years'),
    ('github.com', 'rust-lang-nursery', 'failure',     'https://github.com/rust-lang-nursery/failure',   now() - interval '2 years'),
    ('github.com', 'example-org',       'tiny-config', 'https://github.com/example-org/tiny-config',     now() - interval '200 days'),
    ('github.com', 'example-org',       'solo-crate',  'https://github.com/example-org/solo-crate',      now() - interval '800 days');

-- Packages

INSERT INTO dephealth.package
    (name, created_on, latest_version, repository_id,
     resolution_status, resolution_method, resolution_detail, resolved_at, first_seen_run_id)
SELECT candidate.name,
       candidate.created_on,
       candidate.latest_version,
       r.id,
       candidate.resolution_status,
       candidate.resolution_method,
       candidate.resolution_detail,
       CASE WHEN candidate.resolution_status = 'resolved' THEN now() - interval '6 hours' END,
       (SELECT id FROM dephealth.ingestion_run
         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1)
  FROM (VALUES
    ('serde',         date '2014-12-05', '1.0.228', 'serde-rs/serde',
     'resolved'::dephealth.resolution_status, 'declared_url'::dephealth.resolution_method, NULL),
    ('tokio',         date '2016-08-01', '1.48.0',  'tokio-rs/tokio',
     'resolved', 'declared_url', NULL),
    ('clap',          date '2015-03-28', '4.5.49',  'clap-rs/clap',
     'resolved', 'declared_url', NULL),
    ('failure',       date '2017-10-16', '0.1.8',   'rust-lang-nursery/failure',
     'resolved', 'declared_url', NULL),
    ('tiny-config',   current_date - 200, '0.3.1',  'example-org/tiny-config',
     'resolved', 'declared_url', NULL),
    ('solo-crate',    current_date - 800, '1.1.0',  'example-org/solo-crate',
     'resolved', 'declared_url', NULL),
    ('urlless-crate', date '2019-06-02', '0.2.0',   NULL,
     'no_url_declared', NULL, 'no repository key in the published manifest'),
    ('gitlab-crate',  date '2020-01-14', '2.4.1',   NULL,
     'host_unsupported', NULL, 'declared repository is at gitlab.com/example/gitlab-crate'),
    ('vanished-crate', date '2018-03-09', '0.9.3',  NULL,
     'repository_unreachable', NULL, 'declared repository returned 404 on three consecutive runs')
  ) AS candidate(name, created_on, latest_version, repository_path,
                 resolution_status, resolution_method, resolution_detail)
  LEFT JOIN dephealth.repository r
         ON candidate.repository_path = r.owner || '/' || r.name;

-- Published versions

INSERT INTO dephealth.package_version (package_id, version, published_at, yanked)
SELECT p.id, v.version, v.published_at, v.yanked
  FROM (VALUES
    ('serde',         '1.0.226', now() - interval '120 days', false),
    ('serde',         '1.0.227', now() - interval '47 days',  false),
    ('serde',         '1.0.228', now() - interval '9 days',   false),
    ('tokio',         '1.47.1',  now() - interval '66 days',  false),
    ('tokio',         '1.48.0',  now() - interval '15 days',  false),
    ('clap',          '4.5.48',  now() - interval '38 days',  false),
    ('clap',          '4.5.49',  now() - interval '6 days',   false),
    ('failure',       '0.1.7',   now() - interval '2650 days', false),
    ('failure',       '0.1.8',   now() - interval '2480 days', false),
    ('tiny-config',   '0.3.0',   now() - interval '52 days',  false),
    ('tiny-config',   '0.3.1',   now() - interval '13 days',  false),
    ('solo-crate',    '1.0.4',   now() - interval '300 days', true),
    ('solo-crate',    '1.1.0',   now() - interval '240 days', false),
    ('urlless-crate', '0.2.0',   now() - interval '900 days', false),
    ('gitlab-crate',  '2.4.1',   now() - interval '410 days', false),
    ('vanished-crate','0.9.3',   now() - interval '1500 days', false)
  ) AS v(package_name, version, published_at, yanked)
  JOIN dephealth.package p ON p.name = v.package_name;

-- Dependency edges

-- tiny-config 0.3.1 is the submitted project of the report below. Its tree
-- reaches failure and, through clap, urlless-crate. Neither is in its manifest.
INSERT INTO dephealth.package_dependency
    (dependent_version_id, dependency_package_id, kind, requirement, optional)
SELECT dependent.id, dependency.id, e.kind, e.requirement, e.optional
  FROM (VALUES
    ('tiny-config', '0.3.1', 'serde',         'normal'::dephealth.dependency_kind, '^1.0',  false),
    ('tiny-config', '0.3.1', 'clap',          'normal', '^4.5',  false),
    ('tiny-config', '0.3.1', 'failure',       'normal', '^0.1',  false),
    ('tiny-config', '0.3.1', 'solo-crate',    'normal', '^1.1',  true),
    ('tiny-config', '0.3.1', 'tokio',         'dev',    '^1.47', false),
    ('clap',        '4.5.49', 'urlless-crate', 'normal', '^0.2',  false),
    ('solo-crate',  '1.1.0', 'serde',         'normal', '^1.0',  false)
  ) AS e(dependent_name, dependent_version, dependency_name, kind, requirement, optional)
  JOIN dephealth.package dp ON dp.name = e.dependent_name
  JOIN dephealth.package_version dependent
       ON dependent.package_id = dp.id AND dependent.version = e.dependent_version
  JOIN dephealth.package dependency ON dependency.name = e.dependency_name;

-- Download series

INSERT INTO dephealth.download_daily (package_id, day, downloads, run_id)
SELECT p.id,
       current_date - g.day_offset,
       greatest(0, round(
           profile.base_downloads
           * (1 + profile.daily_drift * (profile.history_days - g.day_offset))
           * CASE WHEN extract(isodow FROM current_date - g.day_offset) IN (6, 7)
                  THEN 0.62 ELSE 1.0 END
           * (1 + ((abs(hashtext(p.name || g.day_offset::text)) % 61) - 30) / 1000.0)
       ))::bigint,
       (SELECT id FROM dephealth.ingestion_run
         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1)
  FROM (VALUES
    ('serde',       1095, 820000, 0.00040),
    ('tokio',       1095, 610000, 0.00055),
    ('clap',        1095, 390000, 0.00030),
    ('failure',     1095,  96000, -0.00072),
    ('solo-crate',   800,    140, 0.00050),
    ('tiny-config',  200,    310, 0.00320)
  ) AS profile(name, history_days, base_downloads, daily_drift)
  JOIN dephealth.package p ON p.name = profile.name
  CROSS JOIN LATERAL generate_series(1, profile.history_days) AS g(day_offset);

-- Contributor activity, aggregated to the package

INSERT INTO dephealth.activity_feature
    (package_id, as_of, window_days, distinct_contributors, event_count,
     commit_event_count, issue_event_count, review_event_count,
     days_since_last_event, top_contributor_share, run_id)
SELECT p.id, current_date - 1, a.window_days, a.contributors, a.events,
       a.commits, a.issues, a.reviews, a.days_since, a.top_share,
       (SELECT id FROM dephealth.ingestion_run
         WHERE source = 'gh_archive' AND status = 'succeeded' ORDER BY id LIMIT 1)
  FROM (VALUES
    -- healthy, many contributors, effort well spread
    ('serde',        30,  24,  310,  170,  100,   40,    2, 0.260),
    ('serde',        90,  42,  980,  520,  300,  150,    2, 0.220),
    ('serde',       180,  58, 1980, 1050,  620,  300,    2, 0.200),
    ('serde',       365,  83, 4100, 2150, 1300,  630,    2, 0.170),
    ('tokio',        30,  38,  480,  230,  160,   90,    1, 0.210),
    ('tokio',        90,  65, 1500,  700,  500,  290,    1, 0.180),
    ('tokio',       180,  88, 3050, 1420, 1010,  600,    1, 0.170),
    ('tokio',       365, 121, 6200, 2900, 2080, 1200,    1, 0.150),
    ('clap',         30,   9,   70,   35,   24,   11,    5, 0.370),
    ('clap',         90,  18,  240,  120,   80,   35,    5, 0.310),
    ('clap',        180,  26,  505,  250,  170,   80,    5, 0.280),
    ('clap',        365,  37, 1040,  520,  350,  160,    5, 0.250),
    -- abandoned: silent in every window
    ('failure',      30,   0,    0,    0,    0,    0, 1920, NULL),
    ('failure',      90,   0,    0,    0,    0,    0, 1920, NULL),
    ('failure',     180,   0,    0,    0,    0,    0, 1920, NULL),
    ('failure',     365,   0,    0,    0,    0,    0, 1920, NULL),
    -- young package, small team, above the disclosure threshold on the longer
    -- windows and below it on the shortest one
    ('tiny-config',  30,   3,   19,   10,    6,    3,   11, 0.520),
    ('tiny-config',  90,   6,   58,   30,   18,    8,   11, 0.450),
    ('tiny-config', 180,   7,   96,   50,   30,   14,   11, 0.420),
    ('tiny-config', 365,   7,  110,   58,   34,   16,   11, 0.400),
    -- one or two contributors: withheld on display in every window
    ('solo-crate',   30,   1,    4,    3,    1,    0,   23, 1.000),
    ('solo-crate',   90,   2,   14,    9,    4,    1,   23, 0.860),
    ('solo-crate',  180,   2,   26,   17,    7,    2,   23, 0.800),
    ('solo-crate',  365,   2,   40,   26,   11,    3,   23, 0.750)
  ) AS a(package_name, window_days, contributors, events,
         commits, issues, reviews, days_since, top_share)
  JOIN dephealth.package p ON p.name = a.package_name;

-- Models

INSERT INTO dephealth.model
    (kind, name, version, is_baseline, is_current, trained_at,
     train_window_start, train_window_end, hyperparameters)
VALUES
    ('adoption_forecast', 'seasonal_naive', '1', true,  false,
     now() - interval '2 days', current_date - 1095, current_date - 180,
     '{"season_length_days": 7}'),
    ('adoption_forecast', 'theta', '1', false, true,
     now() - interval '2 days', current_date - 1095, current_date - 180,
     '{"deseasonalise": true, "season_length_days": 7, "theta": 2.0}'),
    ('maintenance_risk', 'uninformative', '1', true, false,
     now() - interval '2 days', current_date - 1095, current_date - 180,
     '{}'),
    ('maintenance_risk', 'cox_proportional_hazards', '1', false, true,
     now() - interval '2 days', current_date - 1095, current_date - 180,
     '{"penaliser": "l2", "alpha": 0.1, "ties": "efron"}'),
    ('download_anomaly', 'stl_residual', '1', false, true,
     now() - interval '2 days', current_date - 1095, current_date - 180,
     '{"period_days": 7, "threshold_sigma": 3.0}');

INSERT INTO dephealth.model_metric (model_id, metric, value, evaluated_on_packages)
SELECT m.id, s.metric, s.value, s.packages
  FROM (VALUES
    ('seasonal_naive',           'smape',                  31.40, 412),
    ('theta',                    'smape',                  24.80, 412),
    ('theta',                    'mae',                 18420.00, 412),
    ('uninformative',            'concordance_index',       0.500, 1184),
    ('cox_proportional_hazards', 'concordance_index',       0.681, 1184),
    ('cox_proportional_hazards', 'integrated_brier_score',  0.148, 1184)
  ) AS s(model_name, metric, value, packages)
  JOIN dephealth.model m ON m.name = s.model_name;

-- Adoption forecasts

INSERT INTO dephealth.adoption_forecast
    (package_id, model_id, run_id, as_of, horizon_months,
     point_downloads, lower_downloads, upper_downloads,
     history_days, insufficient_history)
SELECT p.id,
       (SELECT id FROM dephealth.model
         WHERE kind = 'adoption_forecast' AND is_current),
       (SELECT id FROM dephealth.ingestion_run
         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1),
       current_date - 1,
       f.horizon_months, f.point, f.lower, f.upper,
       f.history_days, f.insufficient
  FROM (VALUES
    ('serde',        3, 1182000.00,  1034000.00, 1330000.00, 1095, false),
    ('serde',       12, 1294000.00,  1012000.00, 1576000.00, 1095, false),
    ('tokio',       12, 1086000.00,   843000.00, 1329000.00, 1095, false),
    ('clap',        12,  527000.00,   428000.00,  626000.00, 1095, false),
    ('failure',     12,   31400.00,    18900.00,   43900.00, 1095, false),
    ('solo-crate',  12,     247.00,      112.00,     382.00,  800, false),
    -- younger than twelve months: the forecast is withheld rather than guessed
    ('tiny-config', 12,       NULL,        NULL,       NULL,  200, true)
  ) AS f(package_name, horizon_months, point, lower, upper,
         history_days, insufficient)
  JOIN dephealth.package p ON p.name = f.package_name;

-- Maintenance risk and its decomposition

INSERT INTO dephealth.maintenance_risk
    (package_id, model_id, run_id, as_of, horizon_days, probability,
     abandonment_window_days)
SELECT p.id,
       (SELECT id FROM dephealth.model
         WHERE kind = 'maintenance_risk' AND is_current),
       (SELECT id FROM dephealth.ingestion_run
         WHERE source = 'gh_archive' AND status = 'succeeded' ORDER BY id LIMIT 1),
       current_date - 1,
       365,
       r.probability,
       dephealth.abandonment_window_days()
  FROM (VALUES
    ('serde',       0.0310),
    ('tokio',       0.0220),
    ('clap',        0.0940),
    ('tiny-config', 0.4120),
    ('solo-crate',  0.6830),
    ('failure',     0.9710)
  ) AS r(package_name, probability)
  JOIN dephealth.package p ON p.name = r.package_name;

INSERT INTO dephealth.risk_factor
    (maintenance_risk_id, factor, observed_value, contribution)
SELECT mr.id, f.factor, f.observed_value, f.contribution
  FROM (VALUES
    ('failure',     'days_since_last_event', 1920.000,  2.410),
    ('failure',     'contributor_count',        0.000,  1.180),
    ('failure',     'release_gap',           2480.000,  0.940),
    ('failure',     'download_trend',          -0.214,  0.360),
    ('solo-crate',  'top_contributor_share',    0.860,  0.620),
    ('solo-crate',  'contributor_count',        2.000,  0.510),
    ('solo-crate',  'days_since_last_event',   23.000,  0.180),
    ('solo-crate',  'release_gap',            240.000,  0.140),
    ('tiny-config', 'package_age',            200.000,  0.470),
    ('tiny-config', 'contributor_count',        6.000, -0.120),
    ('tiny-config', 'top_contributor_share',    0.450,  0.090),
    ('tiny-config', 'commit_share',             0.517, -0.080),
    ('serde',       'contributor_count',       42.000, -0.910),
    ('serde',       'days_since_last_event',    2.000, -0.430),
    ('serde',       'top_contributor_share',    0.220, -0.260),
    ('serde',       'package_age',           4360.000, -0.190)
  ) AS f(package_name, factor, observed_value, contribution)
  JOIN dephealth.package p ON p.name = f.package_name
  JOIN dephealth.maintenance_risk mr ON mr.package_id = p.id;

-- Stored reports

-- A live report on the tree of tiny-config 0.3.1. The token is written out so
-- the link can be followed. In a deployment it exists only in the user's link.
--   token d225fa755e5477805d29aeecb7198387ea0364c8082f63f6968adfed890eb503
INSERT INTO dephealth.report
    (token_digest, manifest_fingerprint, created_at,
     crates_data_as_of, events_data_as_of, abandonment_window_days,
     risk_model_id, forecast_model_id, entry_count, resolved_count)
VALUES (
    dephealth.report_token_digest('d225fa755e5477805d29aeecb7198387ea0364c8082f63f6968adfed890eb503'),
    dephealth.manifest_fingerprint(
        ARRAY['clap@4.5.49', 'failure@0.1.8', 'serde@1.0.228',
              'solo-crate@1.1.0', 'urlless-crate@0.2.0'],
        'seed-salt-not-a-deployment-secret'),
    now() - interval '2 hours',
    current_date - 1, current_date - 1, dephealth.abandonment_window_days(),
    (SELECT id FROM dephealth.model WHERE kind = 'maintenance_risk'  AND is_current),
    (SELECT id FROM dephealth.model WHERE kind = 'adoption_forecast' AND is_current),
    5, 4);

INSERT INTO dephealth.report_entry
    (report_id, ordinal, package_name, package_version, depth, is_direct,
     package_id, resolved, unresolved_reason,
     risk_probability, risk_horizon_days,
     forecast_point_downloads, forecast_horizon_months, insufficient_history,
     distinct_contributors, days_since_last_event)
SELECT (SELECT id FROM dephealth.report ORDER BY id LIMIT 1),
       e.ordinal, e.package_name, e.package_version, e.depth, e.depth = 0,
       p.id, e.resolved, e.unresolved_reason,
       e.probability, CASE WHEN e.resolved THEN 365 END,
       e.forecast, CASE WHEN e.forecast IS NOT NULL THEN 12 END, false,
       e.contributors, e.days_since
  FROM (VALUES
    (1, 'failure',       '0.1.8',   0, true,  NULL::dephealth.resolution_status,
        0.9710, 31400.00,    0, 1920),
    (2, 'solo-crate',    '1.1.0',   0, true,  NULL,
        0.6830,   247.00,    2,   23),
    (3, 'clap',          '4.5.49',  0, true,  NULL,
        0.0940, 527000.00,  18,    5),
    (4, 'serde',         '1.0.228', 0, true,  NULL,
        0.0310, 1294000.00, 42,    2),
    (5, 'urlless-crate', '0.2.0',   1, false, 'no_url_declared',
        NULL,     NULL,     NULL, NULL)
  ) AS e(ordinal, package_name, package_version, depth, resolved,
         unresolved_reason, probability, forecast, contributors, days_since)
  LEFT JOIN dephealth.package p ON p.name = e.package_name;

INSERT INTO dephealth.report_entry_factor
    (report_id, ordinal, factor, observed_value, contribution)
VALUES
    ((SELECT id FROM dephealth.report ORDER BY id LIMIT 1), 1,
     'days_since_last_event', 1920.000, 2.410),
    ((SELECT id FROM dephealth.report ORDER BY id LIMIT 1), 1,
     'contributor_count', 0.000, 1.180),
    ((SELECT id FROM dephealth.report ORDER BY id LIMIT 1), 1,
     'release_gap', 2480.000, 0.940),
    ((SELECT id FROM dephealth.report ORDER BY id LIMIT 1), 2,
     'top_contributor_share', 0.860, 0.620),
    ((SELECT id FROM dephealth.report ORDER BY id LIMIT 1), 2,
     'contributor_count', 2.000, 0.510);

-- An earlier assessment of the same manifest. Same fingerprint, so US11 finds
-- it without either manifest being retained. solo-crate was not yet in the
-- tree, so the comparison has a new entry and a risen score.
--   token 3f690d5ce7edb117aa26141593f99bea58a8ce699d94ef17e5bbf60497f8b1cc
INSERT INTO dephealth.report
    (token_digest, manifest_fingerprint, created_at,
     crates_data_as_of, events_data_as_of, abandonment_window_days,
     risk_model_id, forecast_model_id, entry_count, resolved_count)
VALUES (
    dephealth.report_token_digest('3f690d5ce7edb117aa26141593f99bea58a8ce699d94ef17e5bbf60497f8b1cc'),
    dephealth.manifest_fingerprint(
        ARRAY['clap@4.5.49', 'failure@0.1.8', 'serde@1.0.228',
              'solo-crate@1.1.0', 'urlless-crate@0.2.0'],
        'seed-salt-not-a-deployment-secret'),
    now() - interval '43 days',
    current_date - 44, current_date - 44, dephealth.abandonment_window_days(),
    (SELECT id FROM dephealth.model WHERE kind = 'maintenance_risk'  AND is_current),
    (SELECT id FROM dephealth.model WHERE kind = 'adoption_forecast' AND is_current),
    4, 3);

INSERT INTO dephealth.report_entry
    (report_id, ordinal, package_name, package_version, depth, is_direct,
     package_id, resolved, unresolved_reason,
     risk_probability, risk_horizon_days,
     forecast_point_downloads, forecast_horizon_months, insufficient_history,
     distinct_contributors, days_since_last_event)
SELECT (SELECT id FROM dephealth.report
         WHERE token_digest = dephealth.report_token_digest(
               '3f690d5ce7edb117aa26141593f99bea58a8ce699d94ef17e5bbf60497f8b1cc')),
       e.ordinal, e.package_name, e.package_version, e.depth, e.depth = 0,
       p.id, e.resolved, e.unresolved_reason,
       e.probability, CASE WHEN e.resolved THEN 365 END,
       e.forecast, CASE WHEN e.forecast IS NOT NULL THEN 12 END, false,
       e.contributors, e.days_since
  FROM (VALUES
    (1, 'failure',       '0.1.8',   0, true,  NULL::dephealth.resolution_status,
        0.9390, 34800.00,    0, 1877),
    (2, 'clap',          '4.5.48',  0, true,  NULL,
        0.1020, 511000.00,  16,    9),
    (3, 'serde',         '1.0.227', 0, true,  NULL,
        0.0290, 1261000.00, 40,    3),
    (4, 'urlless-crate', '0.2.0',   1, false, 'no_url_declared',
        NULL,     NULL,     NULL, NULL)
  ) AS e(ordinal, package_name, package_version, depth, resolved,
         unresolved_reason, probability, forecast, contributors, days_since)
  LEFT JOIN dephealth.package p ON p.name = e.package_name;

-- A withdrawn report, so a link that once worked differs from one that never
-- existed.
--   token: 13da22d5c63c4d44baed655ba6504d53d5192e8d213d9c664e52bf7fcd3bf240
INSERT INTO dephealth.report
    (token_digest, created_at, crates_data_as_of, events_data_as_of,
     abandonment_window_days, risk_model_id, forecast_model_id,
     entry_count, resolved_count, withdrawn_at, withdrawal_reason)
VALUES (
    dephealth.report_token_digest('13da22d5c63c4d44baed655ba6504d53d5192e8d213d9c664e52bf7fcd3bf240'),
    now() - interval '40 days',
    current_date - 41, current_date - 41, dephealth.abandonment_window_days(),
    (SELECT id FROM dephealth.model WHERE kind = 'maintenance_risk'  AND is_current),
    (SELECT id FROM dephealth.model WHERE kind = 'adoption_forecast' AND is_current),
    2, 2,
    now() - interval '11 days',
    'generated from a manifest submitted in error by its author, who asked for it to be withdrawn');

INSERT INTO dephealth.report_entry
    (report_id, ordinal, package_name, package_version, depth, is_direct,
     package_id, resolved, risk_probability, risk_horizon_days,
     distinct_contributors, days_since_last_event)
SELECT (SELECT id FROM dephealth.report ORDER BY id DESC LIMIT 1),
       e.ordinal, e.package_name, e.package_version, 0, true,
       p.id, true, e.probability, 365, e.contributors, e.days_since
  FROM (VALUES
    (1, 'failure', '0.1.8',   0.9680, 0,  1879),
    (2, 'serde',   '1.0.227', 0.0340, 40,    3)
  ) AS e(ordinal, package_name, package_version, probability, contributors, days_since)
  JOIN dephealth.package p ON p.name = e.package_name;

COMMIT;

REFRESH MATERIALIZED VIEW CONCURRENTLY dephealth.mv_package_current_assessment;

ANALYZE;
