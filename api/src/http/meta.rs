use axum::{Json, extract::State};

use super::AppState;
use crate::{
    db,
    dto::{Meta, Method},
    error::ApiError,
};

const ABANDONMENT_DEFINITION: &str = "A package is treated as abandoned at the end of the first \
    interval of consecutive days containing no development event from any contributor on its \
    repository. Packages still active at the end of the observation window are right censored \
    rather than labelled healthy.";

/// The method and the age of the data
///
/// What a reader needs in order to interpret a score. The definition it rests
/// on, the disclosure threshold, and how old each source is. The constants are
/// read from the database, so this endpoint cannot disagree with the scores it
/// describes.
#[utoipa::path(
    get,
    path = "/meta",
    tag = "Service",
    operation_id = "getMeta",
    responses(
        (status = OK, description = "The method and the state of each source", body = Meta),
        (status = METHOD_NOT_ALLOWED, description = "The path is served for GET alone",
         body = crate::dto::Problem, content_type = "application/problem+json"),
        (status = INTERNAL_SERVER_ERROR, description = "The request could not be completed",
         body = crate::dto::Problem, content_type = "application/problem+json")
    )
)]
pub async fn show(State(state): State<AppState>) -> Result<Json<Meta>, ApiError> {
    let (abandonment_window_days, contributor_disclosure_threshold) =
        db::method_constants(&state.pool).await?;
    let sources = db::source_ages(&state.pool).await?;

    Ok(Json(Meta {
        service: "dephealth".to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        method: Method {
            abandonment_window_days,
            contributor_disclosure_threshold,
            abandonment_definition: ABANDONMENT_DEFINITION.to_owned(),
        },
        sources,
    }))
}
