use axum::{Json, extract::State, http::StatusCode};

use super::AppState;
use crate::{
    db,
    dto::{Liveness, Readiness},
};

/// Liveness
///
/// Answers as long as the process is running, so an orchestrator does not
/// restart the service for a database it cannot reach.
#[utoipa::path(
    get,
    path = "/health/live",
    tag = "Service",
    operation_id = "getLiveness",
    responses((status = OK, description = "The process is running", body = Liveness))
)]
pub async fn live() -> Json<Liveness> {
    Json(Liveness {
        status: "live".to_owned(),
    })
}

/// Readiness
///
/// Reports whether the database answers and whether every source has been
/// ingested at least once. A source that never has makes the service unready,
/// since an assessment would rest on nothing. This is also the endpoint that
/// external availability monitoring reads.
#[utoipa::path(
    get,
    path = "/health/ready",
    tag = "Service",
    operation_id = "getReadiness",
    responses(
        (status = OK, description = "Ready to serve assessments", body = Readiness),
        (status = SERVICE_UNAVAILABLE, description = "Not ready", body = Readiness)
    )
)]
pub async fn ready(State(state): State<AppState>) -> (StatusCode, Json<Readiness>) {
    if let Err(error) = db::ping(&state.pool).await {
        tracing::error!(error = %error, "readiness check could not reach the database");
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(Readiness {
                status: "not ready".to_owned(),
                database: "unreachable".to_owned(),
                sources: Vec::new(),
                sources_never_ingested: Vec::new(),
            }),
        );
    }

    let sources = db::source_ages(&state.pool).await.unwrap_or_default();
    let never_ingested: Vec<String> = sources
        .iter()
        .filter(|s| s.data_as_of.is_none())
        .map(|s| s.source.clone())
        .collect();

    let ready = never_ingested.is_empty();

    (
        if ready {
            StatusCode::OK
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        Json(Readiness {
            status: if ready { "ready" } else { "not ready" }.to_owned(),
            database: "reachable".to_owned(),
            sources,
            sources_never_ingested: never_ingested,
        }),
    )
}
