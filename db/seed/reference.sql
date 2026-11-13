-- Reference data. Idempotent, so it runs after every migration.

INSERT INTO dephealth.resolution_outcome (status, label, is_resolved, remedy) VALUES
    ('resolved',
     'Resolved to a source repository',
     true,
     'None needed'),
    ('no_url_declared',
     'No repository declared in the registry',
     false,
     'Ask the maintainer to declare a repository, or supply one by hand'),
    ('url_unparseable',
     'The declared repository address could not be read',
     false,
     'The address is malformed in the registry metadata and has to be corrected there'),
    ('host_unsupported',
     'The repository is hosted outside GitHub',
     false,
     'This version derives maintenance signals from GitHub events only, so the package is reported without a score rather than scored on the consumption side alone'),
    ('repository_unreachable',
     'The declared repository could not be reached',
     false,
     'The repository has been renamed, made private or deleted since the version was published')
ON CONFLICT (status) DO UPDATE
    SET label = excluded.label,
        is_resolved = excluded.is_resolved,
        remedy = excluded.remedy;

INSERT INTO dephealth.feature_window (days, label) VALUES
    (30,  'Last 30 days'),
    (90,  'Last 90 days'),
    (180, 'Last 180 days'),
    (365, 'Last 12 months')
ON CONFLICT (days) DO UPDATE SET label = excluded.label;

INSERT INTO dephealth.metric_definition (code, label, unit, lower_is_better, kpi) VALUES
    ('smape',
     'Symmetric mean absolute percentage error',
     'per cent',
     true,
     'KPI3'),
    ('concordance_index',
     'Concordance index',
     'index',
     false,
     'KPI4'),
    ('mae',
     'Mean absolute error',
     'downloads',
     true,
     NULL),
    ('integrated_brier_score',
     'Integrated Brier score',
     'score',
     true,
     NULL)
ON CONFLICT (code) DO UPDATE
    SET label = excluded.label,
        unit = excluded.unit,
        lower_is_better = excluded.lower_is_better,
        kpi = excluded.kpi;

INSERT INTO dephealth.risk_factor_catalogue (code, label, description, higher_is_riskier) VALUES
    ('days_since_last_event',
     'Days since the last development event',
     'Days between the date of assessment and the most recent public development event in the source repository. The abandonment definition rests on this quantity, so it is the factor with the largest influence on the score.',
     true),
    ('contributor_count',
     'Active contributors',
     'Distinct accounts that produced at least one event in the trailing 90 days. A package with several active contributors survives the departure of one of them.',
     false),
    ('contributor_trend',
     'Change in active contributors',
     'Active contributors in the last 90 days against the 90 days before that. A falling count precedes abandonment more often than a low count does.',
     false),
    ('top_contributor_share',
     'Concentration of effort',
     'Share of events in the window produced by the single most active account. A share near one means the package depends on one person, which is the condition the published score is meant to surface.',
     true),
    ('commit_share',
     'Share of events that change code',
     'Commit events as a share of all events. A repository where only issues move is being answered rather than developed.',
     false),
    ('release_gap',
     'Days since the last release',
     'Days since the most recent version was published to the registry. A long gap beside continuing commits means a maintained but unreleased package, which is a different condition from abandonment.',
     true),
    ('download_trend',
     'Change in downloads',
     'Downloads in the last 90 days against the 90 days before that. A falling series means the consumers are leaving, which is the consumption side of the same question.',
     false),
    ('package_age',
     'Age of the package',
     'Days since the first version was published. A young package has a higher rate of abandonment than an established one, independently of its current activity.',
     true)
ON CONFLICT (code) DO UPDATE
    SET label = excluded.label,
        description = excluded.description,
        higher_is_riskier = excluded.higher_is_riskier;
