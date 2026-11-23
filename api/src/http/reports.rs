use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use utoipa::{IntoParams, ToSchema};

use super::AppState;
use crate::{
    db,
    dto::{Changes, Counts, EntryDetail, Problem, Report, ReportDataAge, ReportMethod, Withdrawal},
    error::ApiError,
};

#[derive(Debug, Deserialize, IntoParams)]
#[into_params(parameter_in = Path)]
pub struct ReportToken {
    /// The token from the permanent link, 64 hexadecimal characters. Only its
    /// digest is stored, so a link cannot be recovered from a database dump.
    #[param(
        pattern = "^[0-9a-f]{64}$",
        example = "9f2c1ab4e6d8705318a0cb4df2e9173c5b6a8de0417fc2938b5e60a7d41c8f23"
    )]
    token: String,
}

#[derive(Debug, Deserialize, IntoParams)]
#[into_params(parameter_in = Path)]
pub struct ReportEntryPath {
    /// The token from the permanent link.
    #[param(pattern = "^[0-9a-f]{64}$")]
    token: String,
    /// The package name, matched without regard to case.
    #[param(example = "tiny-config")]
    package: String,
}

/// Read a stored report
///
/// Returns the report as it stood when it was generated, which is not the same
/// as the current scores. A report filed as evidence does not change when the
/// next ingestion run overwrites them.
///
/// A link that never addressed a report answers 404, and one whose report has
/// been withdrawn answers 410. The two are kept apart because they have
/// different consequences for an audit.
#[utoipa::path(
    get,
    path = "/reports/{token}",
    tag = "Assessments",
    operation_id = "getReport",
    params(ReportToken),
    responses(
        (status = OK, description = "The stored report", body = Report),
        (status = NOT_FOUND, description = "The link has never addressed a report here",
         body = Problem, content_type = "application/problem+json"),
        (status = GONE, description = "The report existed and has been withdrawn",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn show(
    State(state): State<AppState>,
    Path(ReportToken { token }): Path<ReportToken>,
) -> Result<Json<Report>, ApiError> {
    let header = require_live_report(&state, &token).await?;
    let entries = db::report_entries(&state.pool, header.id).await?;
    Ok(Json(assemble(header, entries)))
}

/// Read one entry of a report with its evidence
///
/// The entry, the factors that moved its score, the observed download series
/// and the current assessment of the same package.
///
/// The factor decomposition is published as part of a dated report and not on
/// its own, which is why this endpoint is addressed through a report rather than
/// through a package.
#[utoipa::path(
    get,
    path = "/reports/{token}/entries/{package}",
    tag = "Assessments",
    operation_id = "getReportEntry",
    params(ReportEntryPath),
    responses(
        (status = OK, description = "The entry and its evidence", body = EntryDetail),
        (status = NOT_FOUND, description = "No such report, or no such entry in it",
         body = Problem, content_type = "application/problem+json"),
        (status = GONE, description = "The report has been withdrawn",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn entry(
    State(state): State<AppState>,
    Path(ReportEntryPath { token, package }): Path<ReportEntryPath>,
) -> Result<Json<EntryDetail>, ApiError> {
    let header = require_live_report(&state, &token).await?;
    let entries = db::report_entries(&state.pool, header.id).await?;

    let entry = entries
        .into_iter()
        .find(|e| e.package_name.eq_ignore_ascii_case(&package))
        .ok_or(ApiError::EntryNotFound {
            package: package.clone(),
        })?;

    let factors = db::entry_factors(&state.pool, header.id, entry.ordinal).await?;
    let downloads = db::download_series(&state.pool, &entry.package_name, None, None).await?;
    let live = db::assessment(&state.pool, &entry.package_name).await?;

    Ok(Json(EntryDetail {
        entry,
        factors,
        downloads,
        live,
    }))
}

/// Compare a report with the previous assessment of the same manifest
///
/// Matched on the salted fingerprint of the entry set, so a resubmission is
/// recognised without the earlier manifest having been kept. A report that is
/// the first of its manifest answers 404.
#[utoipa::path(
    get,
    path = "/reports/{token}/changes",
    tag = "Assessments",
    operation_id = "getReportChanges",
    params(ReportToken),
    responses(
        (status = OK, description = "What has changed since the earlier assessment",
         body = Changes),
        (status = NOT_FOUND,
         description = "No such report, or no earlier assessment of its manifest",
         body = Problem, content_type = "application/problem+json"),
        (status = GONE, description = "The report has been withdrawn",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn changes(
    State(state): State<AppState>,
    Path(ReportToken { token }): Path<ReportToken>,
) -> Result<Json<Changes>, ApiError> {
    let header = require_live_report(&state, &token).await?;

    let previous = db::previous_report_digest(&state.pool, &token)
        .await?
        .ok_or(ApiError::NoPreviousReport)?;

    let (previous_assessed_on, packages) =
        db::changes_against(&state.pool, header.id, &previous).await?;

    Ok(Json(Changes {
        assessed_on: header.created_at.date_naive(),
        previous_assessed_on,
        packages,
    }))
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct WithdrawalRequest {
    /// Kept with the report and shown to whoever opens the link.
    #[schema(
        min_length = 1,
        example = "Superseded by a later assessment of the same manifest"
    )]
    reason: String,
}

/// Withdraw a report
///
/// Withdrawal keeps the row and the reason, so a withdrawn report stays
/// distinguishable from a link that never existed. It cannot be reversed.
///
/// This is the only operation with a credential, because there are no accounts
/// and a link alone must not be enough to remove the evidence it addresses. A
/// deployment with no administrative token configured answers 501.
#[utoipa::path(
    post,
    path = "/reports/{token}/withdrawal",
    tag = "Assessments",
    operation_id = "withdrawReport",
    security(("adminToken" = [])),
    params(ReportToken),
    request_body = WithdrawalRequest,
    responses(
        (status = NO_CONTENT, description = "The report has been withdrawn"),
        (status = BAD_REQUEST, description = "No reason was given",
         body = Problem, content_type = "application/problem+json"),
        (status = UNAUTHORIZED, description = "No usable credential",
         body = Problem, content_type = "application/problem+json"),
        (status = NOT_FOUND, description = "No such report",
         body = Problem, content_type = "application/problem+json"),
        (status = GONE, description = "Already withdrawn",
         body = Problem, content_type = "application/problem+json"),
        (status = NOT_IMPLEMENTED, description = "Withdrawal is not enabled here",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn withdraw(
    State(state): State<AppState>,
    Path(ReportToken { token }): Path<ReportToken>,
    headers: HeaderMap,
    Json(request): Json<WithdrawalRequest>,
) -> Result<Response, ApiError> {
    let Some(expected) = state.config.admin_token.as_deref() else {
        return Err(ApiError::WithdrawalNotConfigured);
    };

    if !bearer_matches(&headers, expected) {
        return Err(ApiError::Unauthorised);
    }

    if request.reason.trim().is_empty() {
        return Err(ApiError::InvalidQuery {
            detail: "a withdrawal has to state a reason, which is kept with the report".into(),
        });
    }

    require_live_report(&state, &token).await?;
    db::withdraw_report(&state.pool, &token, request.reason.trim()).await?;

    tracing::info!("report withdrawn");
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// Constant time, so a wrong token cannot be found a character at a time.
fn bearer_matches(headers: &HeaderMap, expected: &str) -> bool {
    let Some(value) = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    else {
        return false;
    };
    let Some(presented) = value.strip_prefix("Bearer ") else {
        return false;
    };

    let presented = presented.trim().as_bytes();
    let expected = expected.as_bytes();

    if presented.len() != expected.len() {
        return false;
    }
    presented
        .iter()
        .zip(expected)
        .fold(0u8, |acc, (a, b)| acc | (a ^ b))
        == 0
}

pub(super) async fn load(state: &AppState, token: &str) -> Result<Option<Report>, ApiError> {
    let Some(header) = db::report_header(&state.pool, token).await? else {
        return Ok(None);
    };
    let entries = db::report_entries(&state.pool, header.id).await?;
    Ok(Some(assemble(header, entries)))
}

fn assemble(header: db::ReportHeader, entries: Vec<crate::dto::ReportEntry>) -> Report {
    let withdrawn = match (header.withdrawn_at, header.withdrawal_reason) {
        (Some(at), Some(reason)) => Some(Withdrawal { at, reason }),
        _ => None,
    };

    Report {
        link: None,
        assessed_on: header.created_at.date_naive(),
        created_at: header.created_at,
        data_as_of: ReportDataAge {
            registry: header.crates_data_as_of,
            events: header.events_data_as_of,
        },
        method: ReportMethod {
            abandonment_window_days: header.abandonment_window_days,
            risk_model: header.risk_model,
            forecast_model: header.forecast_model,
        },
        counts: Counts {
            entries: header.entry_count,
            resolved: header.resolved_count,
            unresolved: header.unresolved_count,
        },
        withdrawn,
        entries,
    }
}

async fn require_live_report(state: &AppState, token: &str) -> Result<db::ReportHeader, ApiError> {
    let header = db::report_header(&state.pool, token)
        .await?
        .ok_or(ApiError::ReportNotFound)?;

    match (header.withdrawn_at, &header.withdrawal_reason) {
        (Some(withdrawn_at), Some(reason)) => Err(ApiError::ReportWithdrawn {
            withdrawn_at,
            reason: reason.clone(),
        }),
        _ => Ok(header),
    }
}
