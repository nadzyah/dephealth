//! The HTTP surface. Routing and the layers every request passes through live
//! here. Each resource has its own module and none of them touch the database
//! directly.
//!
//! The API specification is generated from these handlers rather than written
//! beside them, so the two cannot disagree. `make openapi` writes it out and a
//! test fails if the committed copy is stale.

mod assessments;
mod docs;
mod health;
mod meta;
mod packages;
mod reports;

use std::sync::Arc;

use axum::{
    Router,
    extract::DefaultBodyLimit,
    http::{HeaderValue, Method, Request, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use sqlx::PgPool;
use tower_http::{
    catch_panic::CatchPanicLayer,
    cors::{AllowOrigin, CorsLayer},
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    set_header::SetResponseHeaderLayer,
    timeout::TimeoutLayer,
    trace::TraceLayer,
};
use utoipa::{
    Modify, OpenApi,
    openapi::security::{HttpAuthScheme, HttpBuilder, SecurityScheme},
};
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::{config::Config, error::ApiError};

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
}

#[derive(OpenApi)]
#[openapi(
    info(
        title = "dephealth API",
        description = "\
Submit a dependency manifest and receive the tree ranked by the risk that \
maintenance ceases, with an adoption forecast and the evidence behind every \
score.\n\n\
Nothing is modelled while a request is in flight. Forecasts and risk scores are \
computed on a schedule and this API reads the stored results, which is why every \
response states the date of the data it rests on.\n\n\
There are no accounts. A generated report is addressed by an unguessable link, \
and only withdrawal needs a credential.",
        license(name = "MIT", identifier = "MIT")
    ),
    servers((url = "/", description = "The deployment serving this document")),
    // Every operation but withdrawal is open, which an empty requirement at the
    // root states rather than leaves to be inferred
    security(()),
    tags(
        (name = "Assessments",
         description = "Submitting a manifest and reading the report it produces."),
        (name = "Packages",
         description = "The current assessment of a single package."),
        (name = "Service",
         description = "The method, the age of the data, and liveness.")
    ),
    modifiers(&AdminToken)
)]
pub struct ApiDoc;

struct AdminToken;

impl Modify for AdminToken {
    fn modify(&self, openapi: &mut utoipa::openapi::OpenApi) {
        if let Some(components) = openapi.components.as_mut() {
            components.add_security_scheme(
                "adminToken",
                SecurityScheme::Http(
                    HttpBuilder::new()
                        .scheme(HttpAuthScheme::Bearer)
                        .description(Some(
                            "A bearer token held by the operator and configured as \
                             API_ADMIN_TOKEN. It authorises withdrawal and nothing else.",
                        ))
                        .build(),
                ),
            );
        }
    }
}

fn routes() -> OpenApiRouter<AppState> {
    let api = OpenApiRouter::new()
        .routes(routes!(meta::show))
        .routes(routes!(assessments::create))
        .routes(routes!(reports::show))
        .routes(routes!(reports::changes))
        .routes(routes!(reports::entry))
        .routes(routes!(reports::withdraw))
        .routes(routes!(packages::search))
        .routes(routes!(packages::show))
        .routes(routes!(packages::downloads));

    OpenApiRouter::with_openapi(ApiDoc::openapi())
        .routes(routes!(health::live))
        .routes(routes!(health::ready))
        .nest("/api/v1", api)
}

/// The generated specification, which needs no database and is what `make
/// openapi` writes to `docs/api/openapi.yaml`.
pub fn api_document() -> utoipa::openapi::OpenApi {
    routes().split_for_parts().1
}

pub fn router(state: AppState) -> Router {
    let config = Arc::clone(&state.config);
    let (router, document) = routes().split_for_parts();
    let spec: Arc<str> = Arc::from(document.to_yaml().unwrap_or_default());

    router
        .route("/docs", get(docs::redirect))
        .route("/docs/", get(docs::page))
        .route(
            "/docs/openapi.yaml",
            get(move || docs::spec(Arc::clone(&spec))),
        )
        .fallback(|| async { ApiError::RouteNotFound })
        .method_not_allowed_fallback(|| async { ApiError::MethodNotAllowed })
        // The assessment handler reads the body itself, so that an oversized
        // manifest is refused in the same form as every other refusal
        .layer(DefaultBodyLimit::disable())
        .layer(SetResponseHeaderLayer::overriding(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ))
        .layer(cors(&config))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::SERVICE_UNAVAILABLE,
            config.request_timeout,
        ))
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(TraceLayer::new_for_http().make_span_with(request_span))
        // A panic is answered with a problem document like any other internal
        // failure, rather than closing the connection with nothing in it
        .layer(CatchPanicLayer::custom(panicked))
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .with_state(state)
}

/// The span every log line of a request is recorded in. The identifier is in it
/// because that is what correlates a reported fault with the lines it produced,
/// and the layer above has already assigned one.
fn request_span<B>(request: &Request<B>) -> tracing::Span {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();

    tracing::info_span!(
        "request",
        method = %request.method(),
        path = %request.uri().path(),
        request_id = %request_id,
    )
}

/// A panic is a fault in this service and never something the client sent, so
/// the response says only that, and the detail stays in the log.
fn panicked(error: Box<dyn std::any::Any + Send + 'static>) -> Response {
    let detail = error
        .downcast_ref::<&str>()
        .map(|s| (*s).to_owned())
        .or_else(|| error.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "no description".to_owned());

    tracing::error!(detail = %detail, "a handler panicked");
    ApiError::Panicked.into_response()
}

/// The browser application is served from another origin in development and may
/// be in a deployment, so the origins are configured rather than open.
fn cors(config: &Config) -> CorsLayer {
    let origins: Vec<HeaderValue> = config
        .cors_origins
        .iter()
        .filter_map(|origin| HeaderValue::from_str(origin).ok())
        .collect();

    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([header::CONTENT_TYPE, header::AUTHORIZATION])
}
