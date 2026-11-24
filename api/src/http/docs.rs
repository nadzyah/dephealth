use std::sync::Arc;

use axum::{
    http::{StatusCode, header},
    response::{IntoResponse, Redirect, Response},
};

/// The page is a file in `docs/api`, embedded at build time, and it reads the
/// specification this service generates from its own handlers.
const PAGE: &str = include_str!("../../../docs/api/index.html");

pub async fn redirect() -> Redirect {
    Redirect::permanent("/docs/")
}

pub async fn page() -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        PAGE,
    )
        .into_response()
}

pub async fn spec(yaml: Arc<str>) -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/yaml; charset=utf-8")],
        yaml.to_string(),
    )
        .into_response()
}
