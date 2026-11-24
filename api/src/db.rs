//! Every statement the service runs. The connection belongs to the application
//! role, which reads through the published views and writes reports through one
//! function, so a mistake here cannot reach the contributor counts or the live
//! model output.

use std::time::Duration;

use chrono::{DateTime, NaiveDate, Utc};
use sqlx::{
    postgres::{PgPool, PgPoolOptions},
    types::Json,
};

use crate::{
    config::Config,
    dto::{
        self, Activity, Assessment, Change, DownloadPoint, Factor, Forecast, LiveDataAge, ModelRef,
        PackageSummary, Resolution, Risk, SourceAge,
    },
    manifest::Entry,
};

pub async fn connect(config: &Config) -> Result<PgPool, sqlx::Error> {
    PgPoolOptions::new()
        .max_connections(config.pool_size)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&config.database_url)
        .await
}

pub struct ReportHeader {
    pub id: i64,
    pub created_at: DateTime<Utc>,
    pub crates_data_as_of: NaiveDate,
    pub events_data_as_of: NaiveDate,
    pub abandonment_window_days: i32,
    pub risk_model: ModelRef,
    pub forecast_model: ModelRef,
    pub entry_count: i32,
    pub resolved_count: i32,
    pub unresolved_count: i32,
    pub withdrawn_at: Option<DateTime<Utc>>,
    pub withdrawal_reason: Option<String>,
}

/// Store one assessment. The token is hashed inside the function and never
/// leaves the process in any other form.
pub async fn create_report(
    pool: &PgPool,
    token: &str,
    salt: &str,
    entries: &[Entry],
) -> Result<i64, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT dephealth.create_report($1, $2, $3) AS "id!""#,
        token,
        salt,
        Json(entries) as _
    )
    .fetch_one(pool)
    .await
}

pub async fn report_header(
    pool: &PgPool,
    token: &str,
) -> Result<Option<ReportHeader>, sqlx::Error> {
    let row = sqlx::query!(
        r#"
        SELECT r.id                      AS "id!",
               r.created_at              AS "created_at!",
               r.crates_data_as_of       AS "crates_data_as_of!",
               r.events_data_as_of       AS "events_data_as_of!",
               r.abandonment_window_days AS "abandonment_window_days!",
               r.risk_model_name         AS "risk_model_name!",
               r.risk_model_version      AS "risk_model_version!",
               r.forecast_model_name     AS "forecast_model_name!",
               r.forecast_model_version  AS "forecast_model_version!",
               r.entry_count             AS "entry_count!",
               r.resolved_count          AS "resolved_count!",
               r.unresolved_count        AS "unresolved_count!",
               r.withdrawn_at,
               r.withdrawal_reason
          FROM dephealth.v_report r
         WHERE r.token_digest = dephealth.report_token_digest($1)
        "#,
        token
    )
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|r| ReportHeader {
        id: r.id,
        created_at: r.created_at,
        crates_data_as_of: r.crates_data_as_of,
        events_data_as_of: r.events_data_as_of,
        abandonment_window_days: r.abandonment_window_days,
        risk_model: ModelRef {
            name: r.risk_model_name,
            version: r.risk_model_version,
        },
        forecast_model: ModelRef {
            name: r.forecast_model_name,
            version: r.forecast_model_version,
        },
        entry_count: r.entry_count,
        resolved_count: r.resolved_count,
        unresolved_count: r.unresolved_count,
        withdrawn_at: r.withdrawn_at,
        withdrawal_reason: r.withdrawal_reason,
    }))
}

pub async fn report_entries(
    pool: &PgPool,
    report_id: i64,
) -> Result<Vec<dto::ReportEntry>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"
        SELECT e.ordinal                    AS "ordinal!",
               e.package_name               AS "package_name!",
               e.package_version            AS "package_version!",
               e.depth                      AS "depth!",
               e.is_direct                  AS "is_direct!",
               e.resolved                   AS "resolved!",
               e.unresolved_reason::text    AS unresolved_reason,
               e.unresolved_label,
               e.unresolved_remedy,
               e.risk_probability::float8   AS risk_probability,
               e.risk_horizon_days,
               e.forecast_point_downloads::float8 AS forecast_point_downloads,
               e.forecast_horizon_months,
               e.insufficient_history       AS "insufficient_history!",
               e.distinct_contributors,
               e.days_since_last_event,
               e.contributor_count_withheld AS "contributor_count_withheld!"
          FROM dephealth.v_report_entry e
         WHERE e.report_id = $1
         ORDER BY e.ordinal
        "#,
        report_id
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| dto::ReportEntry {
            ordinal: r.ordinal,
            package_name: r.package_name,
            package_version: r.package_version,
            depth: r.depth,
            relation: dto::relation(r.is_direct),
            resolved: r.resolved,
            risk: match (r.risk_probability, r.risk_horizon_days) {
                (Some(probability), Some(horizon_days)) => Some(Risk {
                    probability,
                    horizon_days,
                }),
                _ => None,
            },
            forecast: r.resolved.then_some(Forecast {
                point_downloads: r.forecast_point_downloads,
                horizon_months: r.forecast_horizon_months,
                insufficient_history: r.insufficient_history,
            }),
            activity: r.resolved.then_some(Activity {
                distinct_contributors: r.distinct_contributors,
                days_since_last_event: r.days_since_last_event,
                contributor_count_withheld: r.contributor_count_withheld,
            }),
            unresolved: match (r.unresolved_reason, r.unresolved_label, r.unresolved_remedy) {
                (Some(reason), Some(label), Some(remedy)) => Some(dto::Unresolved {
                    reason,
                    label,
                    remedy,
                }),
                _ => None,
            },
        })
        .collect())
}

/// The factor decomposition as the report stored it. The live decomposition is
/// not readable by this role, by design: the evidence behind a score is
/// published as part of a dated report and not on its own.
pub async fn entry_factors(
    pool: &PgPool,
    report_id: i64,
    ordinal: i32,
) -> Result<Vec<Factor>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"
        SELECT f.factor                  AS "code!",
               c.label                   AS "label!",
               c.description             AS "description!",
               f.observed_value::float8  AS "observed_value!",
               f.contribution::float8    AS "contribution!"
          FROM dephealth.report_entry_factor f
          JOIN dephealth.risk_factor_catalogue c ON c.code = f.factor
         WHERE f.report_id = $1 AND f.ordinal = $2
         ORDER BY abs(f.contribution) DESC, f.factor
        "#,
        report_id,
        ordinal
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| Factor {
            code: r.code,
            label: r.label,
            description: r.description,
            observed_value: r.observed_value,
            contribution: r.contribution,
            direction: dto::direction(r.contribution),
        })
        .collect())
}

pub async fn previous_report_digest(
    pool: &PgPool,
    token: &str,
) -> Result<Option<Vec<u8>>, sqlx::Error> {
    sqlx::query_scalar!(
        "SELECT dephealth.previous_report_of(dephealth.report_token_digest($1))",
        token
    )
    .fetch_one(pool)
    .await
}

/// Matched on the fingerprint, since the manifest itself is not kept.
pub async fn changes_against(
    pool: &PgPool,
    report_id: i64,
    previous_digest: &[u8],
) -> Result<(NaiveDate, Vec<Change>), sqlx::Error> {
    let previous_created_on = sqlx::query_scalar!(
        r#"SELECT created_at::date AS "day!" FROM dephealth.v_report WHERE token_digest = $1"#,
        previous_digest
    )
    .fetch_one(pool)
    .await?;

    let rows = sqlx::query!(
        r#"
        WITH previous AS (
            SELECT id FROM dephealth.v_report WHERE token_digest = $2
        )
        SELECT coalesce(now_entry.package_name, then_entry.package_name) AS "package_name!",
               then_entry.risk_probability::float8 AS risk_then,
               now_entry.risk_probability::float8  AS risk_now,
               round(now_entry.risk_probability - then_entry.risk_probability, 4)::float8
                                                   AS change,
               CASE
                   WHEN then_entry.package_name IS NULL THEN 'new in the tree'
                   WHEN now_entry.package_name IS NULL  THEN 'no longer in the tree'
                   WHEN now_entry.risk_probability IS NULL
                    AND then_entry.risk_probability IS NULL THEN 'still unresolved'
                   WHEN now_entry.risk_probability > then_entry.risk_probability
                        THEN 'risk has risen'
                   WHEN now_entry.risk_probability < then_entry.risk_probability
                        THEN 'risk has fallen'
                   ELSE 'unchanged'
               END                                 AS "verdict!"
          FROM (SELECT e.package_name, e.risk_probability
                  FROM dephealth.v_report_entry e
                 WHERE e.report_id = $1) now_entry
          FULL JOIN (SELECT e.package_name, e.risk_probability
                       FROM dephealth.v_report_entry e
                       JOIN previous p ON p.id = e.report_id) then_entry
                 ON lower(then_entry.package_name) = lower(now_entry.package_name)
         ORDER BY change DESC NULLS LAST, 1
        "#,
        report_id,
        previous_digest
    )
    .fetch_all(pool)
    .await?;

    let packages = rows
        .into_iter()
        .map(|r| Change {
            package_name: r.package_name,
            risk_then: r.risk_then,
            risk_now: r.risk_now,
            change: r.change,
            verdict: r.verdict,
        })
        .collect();

    Ok((previous_created_on, packages))
}

pub async fn withdraw_report(pool: &PgPool, token: &str, reason: &str) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "CALL dephealth.withdraw_report(dephealth.report_token_digest($1), $2)",
        token,
        reason
    )
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn assessment(pool: &PgPool, name: &str) -> Result<Option<Assessment>, sqlx::Error> {
    let row = sqlx::query!(
        r#"
        SELECT a.package_name                    AS "package_name!",
               a.latest_version,
               a.repository_url,
               a.is_resolved                     AS "is_resolved!",
               a.resolution_label                AS "resolution_label!",
               a.resolution_remedy               AS "resolution_remedy!",
               a.risk_probability::float8        AS risk_probability,
               a.risk_horizon_days,
               a.forecast_point_downloads::float8 AS forecast_point_downloads,
               a.forecast_horizon_months,
               a.insufficient_history,
               a.distinct_contributors,
               a.contributor_count_withheld      AS "contributor_count_withheld!",
               a.days_since_last_event,
               a.is_abandoned,
               a.registry_data_as_of,
               a.events_data_as_of
          FROM dephealth.v_package_assessment a
         WHERE lower(a.package_name) = lower($1)
        "#,
        name
    )
    .fetch_optional(pool)
    .await?;

    Ok(row.map(|r| Assessment {
        package_name: r.package_name,
        latest_version: r.latest_version,
        repository_url: r.repository_url,
        resolution: Resolution {
            is_resolved: r.is_resolved,
            label: r.resolution_label,
            remedy: r.resolution_remedy,
        },
        risk: match (r.risk_probability, r.risk_horizon_days) {
            (Some(probability), Some(horizon_days)) => Some(Risk {
                probability,
                horizon_days,
            }),
            _ => None,
        },
        forecast: r.insufficient_history.map(|insufficient_history| Forecast {
            point_downloads: r.forecast_point_downloads,
            horizon_months: r.forecast_horizon_months,
            insufficient_history,
        }),
        activity: Activity {
            distinct_contributors: r.distinct_contributors,
            days_since_last_event: r.days_since_last_event,
            contributor_count_withheld: r.contributor_count_withheld,
        },
        is_abandoned: r.is_abandoned,
        data_as_of: LiveDataAge {
            registry: r.registry_data_as_of,
            events: r.events_data_as_of,
        },
    }))
}

pub async fn download_series(
    pool: &PgPool,
    name: &str,
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
) -> Result<Vec<DownloadPoint>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"
        SELECT s.day       AS "day!",
               s.downloads AS "downloads!"
          FROM dephealth.v_download_series s
         WHERE lower(s.package_name) = lower($1)
           AND ($2::date IS NULL OR s.day >= $2)
           AND ($3::date IS NULL OR s.day <= $3)
         ORDER BY s.day
        "#,
        name,
        from,
        to
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| DownloadPoint {
            day: r.day,
            downloads: r.downloads,
        })
        .collect())
}

pub async fn search_packages(
    pool: &PgPool,
    query: Option<&str>,
    limit: i64,
    offset: i64,
) -> Result<Vec<PackageSummary>, sqlx::Error> {
    let pattern = query.map(|q| format!("%{q}%"));

    let rows = sqlx::query!(
        r#"
        SELECT a.package_name              AS "package_name!",
               a.latest_version,
               a.risk_probability::float8  AS risk_probability,
               a.is_resolved               AS "is_resolved!"
          FROM dephealth.v_package_assessment a
         WHERE $1::text IS NULL OR a.package_name ILIKE $1
         ORDER BY a.risk_probability DESC NULLS LAST, a.package_name
         LIMIT $2 OFFSET $3
        "#,
        pattern,
        limit,
        offset
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| PackageSummary {
            package_name: r.package_name,
            latest_version: r.latest_version,
            risk_probability: r.risk_probability,
            is_resolved: r.is_resolved,
        })
        .collect())
}

pub async fn source_ages(pool: &PgPool) -> Result<Vec<SourceAge>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"
        SELECT d.source::text              AS "source!",
               d.data_as_of,
               d.age_days,
               d.last_success_at,
               d.last_attempt_status::text AS last_attempt_status,
               d.last_attempt_at
          FROM dephealth.v_data_age d
         ORDER BY d.source
        "#
    )
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(|r| SourceAge {
            source: r.source,
            data_as_of: r.data_as_of,
            age_days: r.age_days,
            last_success_at: r.last_success_at,
            last_attempt_status: r.last_attempt_status,
            last_attempt_at: r.last_attempt_at,
        })
        .collect())
}

/// The two constants the published method rests on, read from the database so
/// that the service cannot disagree with the scores it serves.
pub async fn method_constants(pool: &PgPool) -> Result<(i32, i32), sqlx::Error> {
    let row = sqlx::query!(
        r#"
        SELECT dephealth.abandonment_window_days() AS "window!",
               dephealth.k_anonymity_threshold()   AS "threshold!"
        "#
    )
    .fetch_one(pool)
    .await?;

    Ok((row.window, row.threshold))
}

pub async fn ping(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query_scalar!(r#"SELECT 1 AS "one!""#)
        .fetch_one(pool)
        .await
        .map(|_| ())
}
