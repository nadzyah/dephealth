use axum::{
    Json,
    extract::{Path, Query, State},
};
use chrono::NaiveDate;
use serde::Deserialize;
use utoipa::IntoParams;

use super::AppState;
use crate::{
    db,
    dto::{Assessment, DownloadPoint, PackagePage, Problem},
    error::ApiError,
};

/// The current assessment of one package
///
/// The stored score, the forecast and the age of the data behind both, for a
/// client that is not reading a report.
///
/// A contributor count below the disclosure threshold is withheld rather than
/// rounded, and `contributor_count_withheld` says which happened. A count of
/// zero is published, because it describes nobody.
#[utoipa::path(
    get,
    path = "/packages/{name}",
    tag = "Packages",
    operation_id = "getPackage",
    params(("name" = String, Path, description = "The package name, matched without regard to case", example = "serde")),
    responses(
        (status = OK, description = "The current assessment", body = Assessment),
        (status = NOT_FOUND, description = "No package of that name is in the registry snapshot",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn show(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> Result<Json<Assessment>, ApiError> {
    db::assessment(&state.pool, &name)
        .await?
        .map(Json)
        .ok_or(ApiError::PackageNotFound { name })
}

#[derive(Debug, Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub struct SearchParams {
    /// Matches anywhere in the name, without regard to case.
    #[param(example = "serde")]
    q: Option<String>,
    #[param(minimum = 1, maximum = 200, default = 50)]
    limit: Option<i64>,
    #[param(minimum = 0, default = 0)]
    offset: Option<i64>,
}

/// List packages
///
/// Ordered by descending risk, so the first page is the one worth reading.
#[utoipa::path(
    get,
    path = "/packages",
    tag = "Packages",
    operation_id = "listPackages",
    params(SearchParams),
    responses(
        (status = OK, description = "One page of packages", body = PackagePage),
        (status = BAD_REQUEST, description = "A query parameter is not usable",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn search(
    State(state): State<AppState>,
    Query(params): Query<SearchParams>,
) -> Result<Json<PackagePage>, ApiError> {
    let limit = params.limit.unwrap_or(50);
    let offset = params.offset.unwrap_or(0);

    if !(1..=200).contains(&limit) {
        return Err(ApiError::InvalidQuery {
            detail: "limit has to be between 1 and 200".into(),
        });
    }
    if offset < 0 {
        return Err(ApiError::InvalidQuery {
            detail: "offset cannot be negative".into(),
        });
    }

    let query = params.q.as_deref().map(str::trim).filter(|q| !q.is_empty());
    let items = db::search_packages(&state.pool, query, limit, offset).await?;

    Ok(Json(PackagePage {
        items,
        limit,
        offset,
    }))
}

#[derive(Debug, Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
pub struct SeriesParams {
    #[param(example = "2026-01-01")]
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
}

/// The observed download series
///
/// The series a package has even when its history is too short for a forecast
/// to be given.
#[utoipa::path(
    get,
    path = "/packages/{name}/downloads",
    tag = "Packages",
    operation_id = "getPackageDownloads",
    params(
        ("name" = String, Path, description = "The package name", example = "serde"),
        SeriesParams
    ),
    responses(
        (status = OK, description = "One point per day, ascending", body = Vec<DownloadPoint>),
        (status = BAD_REQUEST, description = "A query parameter is not usable",
         body = Problem, content_type = "application/problem+json"),
        (status = NOT_FOUND, description = "No package of that name is in the registry snapshot",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn downloads(
    State(state): State<AppState>,
    Path(name): Path<String>,
    Query(params): Query<SeriesParams>,
) -> Result<Json<Vec<DownloadPoint>>, ApiError> {
    if let (Some(from), Some(to)) = (params.from, params.to)
        && from > to
    {
        return Err(ApiError::InvalidQuery {
            detail: "from is later than to".into(),
        });
    }

    if db::assessment(&state.pool, &name).await?.is_none() {
        return Err(ApiError::PackageNotFound { name });
    }

    let series = db::download_series(&state.pool, &name, params.from, params.to).await?;
    Ok(Json(series))
}
