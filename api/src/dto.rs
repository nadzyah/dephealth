//! The shapes the service returns, and the source of the schemas in the
//! generated API specification. Field names follow the database rather than the
//! JavaScript convention, so a value can be traced from a screen to a column.

use chrono::{DateTime, NaiveDate, Utc};
use serde::Serialize;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema)]
pub struct Meta {
    pub service: String,
    pub version: String,
    pub method: Method,
    pub sources: Vec<SourceAge>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Method {
    #[schema(example = 180)]
    pub abandonment_window_days: i32,
    #[schema(example = 5)]
    pub contributor_disclosure_threshold: i32,
    pub abandonment_definition: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct SourceAge {
    #[schema(example = "crates_io_dump")]
    pub source: String,
    pub data_as_of: Option<NaiveDate>,
    pub age_days: Option<i32>,
    pub last_success_at: Option<DateTime<Utc>>,
    #[schema(example = "succeeded")]
    pub last_attempt_status: Option<String>,
    pub last_attempt_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Report {
    /// Returned only when the report is created, since the token is not
    /// recoverable afterwards.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
    pub assessed_on: NaiveDate,
    pub created_at: DateTime<Utc>,
    pub data_as_of: ReportDataAge,
    pub method: ReportMethod,
    pub counts: Counts,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub withdrawn: Option<Withdrawal>,
    /// Ranked, scored entries first and then by descending risk.
    pub entries: Vec<ReportEntry>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ReportDataAge {
    pub registry: NaiveDate,
    pub events: NaiveDate,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ReportMethod {
    pub abandonment_window_days: i32,
    pub risk_model: ModelRef,
    pub forecast_model: ModelRef,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ModelRef {
    #[schema(example = "cox_proportional_hazards")]
    pub name: String,
    #[schema(example = "1")]
    pub version: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Counts {
    pub entries: i32,
    pub resolved: i32,
    pub unresolved: i32,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Withdrawal {
    pub at: DateTime<Utc>,
    pub reason: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct ReportEntry {
    /// The rank within the report, which is the order it is displayed in.
    pub ordinal: i32,
    #[schema(example = "serde")]
    pub package_name: String,
    #[schema(example = "1.0.228")]
    pub package_version: String,
    pub depth: i32,
    /// Whether the submitting project depends on this package itself or
    /// inherits it through another.
    #[schema(example = "direct")]
    pub relation: String,
    /// True only when a score stands behind the entry. A package resolved to a
    /// repository but not yet scored is reported as unresolved, with its own
    /// reason.
    pub resolved: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub risk: Option<Risk>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forecast: Option<Forecast>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub activity: Option<Activity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unresolved: Option<Unresolved>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Risk {
    #[schema(minimum = 0, maximum = 1, example = 0.031)]
    pub probability: f64,
    #[schema(example = 365)]
    pub horizon_days: i32,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Forecast {
    pub point_downloads: Option<f64>,
    #[schema(minimum = 3, maximum = 12)]
    pub horizon_months: Option<i32>,
    /// True when the package has under twelve months of history, in which case
    /// the observed series is given and no forecast.
    pub insufficient_history: bool,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Activity {
    /// Null when withheld, and zero when the repository genuinely had no
    /// contributor in the window.
    pub distinct_contributors: Option<i32>,
    pub days_since_last_event: Option<i32>,
    /// True when a count exists but falls below the disclosure threshold.
    pub contributor_count_withheld: bool,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Unresolved {
    #[schema(example = "no_url_declared")]
    pub reason: String,
    pub label: String,
    /// What the submitter can do about it.
    pub remedy: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct EntryDetail {
    pub entry: ReportEntry,
    /// Ordered by the size of the contribution, as the report stored them.
    pub factors: Vec<Factor>,
    pub downloads: Vec<DownloadPoint>,
    /// The current assessment of the same package, which may differ from the
    /// stored one.
    pub live: Option<Assessment>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Factor {
    #[schema(example = "days_since_last_event")]
    pub code: String,
    pub label: String,
    pub description: String,
    pub observed_value: f64,
    /// Positive raised the risk, negative lowered it.
    pub contribution: f64,
    #[schema(example = "raised the risk")]
    pub direction: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct DownloadPoint {
    pub day: NaiveDate,
    pub downloads: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Assessment {
    #[schema(example = "serde")]
    pub package_name: String,
    pub latest_version: Option<String>,
    pub repository_url: Option<String>,
    pub resolution: Resolution,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub risk: Option<Risk>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub forecast: Option<Forecast>,
    pub activity: Activity,
    /// Null when no development event has been observed, which is not the same
    /// as inactivity.
    pub is_abandoned: Option<bool>,
    pub data_as_of: LiveDataAge,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Resolution {
    pub is_resolved: bool,
    pub label: String,
    pub remedy: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct LiveDataAge {
    pub registry: Option<NaiveDate>,
    pub events: Option<NaiveDate>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct PackageSummary {
    pub package_name: String,
    pub latest_version: Option<String>,
    pub risk_probability: Option<f64>,
    pub is_resolved: bool,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct PackagePage {
    pub items: Vec<PackageSummary>,
    pub limit: i64,
    pub offset: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Changes {
    pub assessed_on: NaiveDate,
    pub previous_assessed_on: NaiveDate,
    pub packages: Vec<Change>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Change {
    pub package_name: String,
    pub risk_then: Option<f64>,
    pub risk_now: Option<f64>,
    pub change: Option<f64>,
    #[schema(example = "risk has risen")]
    pub verdict: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Readiness {
    #[schema(example = "ready")]
    pub status: String,
    #[schema(example = "reachable")]
    pub database: String,
    pub sources: Vec<SourceAge>,
    pub sources_never_ingested: Vec<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct Liveness {
    #[schema(example = "live")]
    pub status: String,
}

/// An error, as RFC 9457 describes one. `type` is a stable identifier a client
/// may branch on, while the prose in `title` and `detail` is not. Some problems
/// carry further fields, which the reference gives per endpoint.
#[derive(Debug, Serialize, ToSchema)]
pub struct Problem {
    #[serde(rename = "type")]
    #[schema(example = "/problems/report-not-found")]
    pub kind: String,
    pub title: String,
    pub status: u16,
    pub detail: String,
}

pub fn relation(is_direct: bool) -> String {
    if is_direct { "direct" } else { "indirect" }.to_owned()
}

pub fn direction(contribution: f64) -> String {
    if contribution > 0.0 {
        "raised the risk"
    } else if contribution < 0.0 {
        "lowered the risk"
    } else {
        "made no difference"
    }
    .to_owned()
}
