use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

/// Every way a request can fail. The variants carry what the client needs to
/// act, and nothing that describes the inside of the service.
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    #[error("the manifest could not be read")]
    ManifestUnreadable { detail: String, line: Option<usize> },

    #[error("the manifest holds no dependency to assess")]
    ManifestEmpty,

    #[error("the manifest holds more entries than this service accepts")]
    ManifestTooLarge { entries: usize, limit: usize },

    #[error("the request body is larger than this service accepts")]
    BodyTooLarge { limit_bytes: usize },

    #[error("the request body is not in a form this endpoint accepts")]
    UnsupportedMediaType { received: String },

    #[error("a query parameter is not usable")]
    InvalidQuery { detail: String },

    #[error("no such endpoint")]
    RouteNotFound,

    #[error("that method is not allowed on this endpoint")]
    MethodNotAllowed,

    #[error("no report exists for that link")]
    ReportNotFound,

    #[error("the report has been withdrawn")]
    ReportWithdrawn {
        withdrawn_at: DateTime<Utc>,
        reason: String,
    },

    #[error("the report holds no entry for that package")]
    EntryNotFound { package: String },

    #[error("no package of that name is known")]
    PackageNotFound { name: String },

    #[error("that report is the first assessment of its manifest")]
    NoPreviousReport,

    #[error("the request carries no credential for this operation")]
    Unauthorised,

    #[error("withdrawal is not enabled on this deployment")]
    WithdrawalNotConfigured,

    #[error("the service cannot serve assessments at the moment")]
    NotReady { detail: String },

    #[error(transparent)]
    Database(#[from] sqlx::Error),

    /// A fault in this service with no further description. Indistinguishable
    /// from a database failure to the client, deliberately, since neither is
    /// something the request can be corrected for.
    #[error("a handler panicked")]
    Panicked,
}

impl ApiError {
    fn status(&self) -> StatusCode {
        match self {
            Self::ManifestUnreadable { .. } | Self::ManifestEmpty => {
                StatusCode::UNPROCESSABLE_ENTITY
            }
            Self::ManifestTooLarge { .. } | Self::BodyTooLarge { .. } => {
                StatusCode::PAYLOAD_TOO_LARGE
            }
            Self::UnsupportedMediaType { .. } => StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Self::InvalidQuery { .. } => StatusCode::BAD_REQUEST,
            Self::RouteNotFound
            | Self::ReportNotFound
            | Self::EntryNotFound { .. }
            | Self::PackageNotFound { .. } => StatusCode::NOT_FOUND,
            Self::MethodNotAllowed => StatusCode::METHOD_NOT_ALLOWED,
            Self::ReportWithdrawn { .. } => StatusCode::GONE,
            Self::NoPreviousReport => StatusCode::NOT_FOUND,
            Self::Unauthorised => StatusCode::UNAUTHORIZED,
            Self::WithdrawalNotConfigured => StatusCode::NOT_IMPLEMENTED,
            Self::NotReady { .. } => StatusCode::SERVICE_UNAVAILABLE,
            Self::Database(_) | Self::Panicked => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    /// The stable identifier of the problem. Documented in the API reference,
    /// so a client may branch on it instead of on the prose.
    fn slug(&self) -> &'static str {
        match self {
            Self::ManifestUnreadable { .. } => "manifest-unreadable",
            Self::ManifestEmpty => "manifest-empty",
            Self::ManifestTooLarge { .. } | Self::BodyTooLarge { .. } => "manifest-too-large",
            Self::UnsupportedMediaType { .. } => "unsupported-media-type",
            Self::InvalidQuery { .. } => "invalid-query-parameter",
            Self::RouteNotFound => "no-such-endpoint",
            Self::MethodNotAllowed => "method-not-allowed",
            Self::ReportNotFound => "report-not-found",
            Self::ReportWithdrawn { .. } => "report-withdrawn",
            Self::EntryNotFound { .. } => "entry-not-found",
            Self::PackageNotFound { .. } => "package-not-found",
            Self::NoPreviousReport => "no-previous-report",
            Self::Unauthorised => "unauthorised",
            Self::WithdrawalNotConfigured => "withdrawal-not-configured",
            Self::NotReady { .. } => "not-ready",
            Self::Database(_) | Self::Panicked => "internal-error",
        }
    }

    fn title(&self) -> &'static str {
        match self {
            Self::ManifestUnreadable { .. } => "The manifest could not be read",
            Self::ManifestEmpty => "The manifest holds nothing to assess",
            Self::ManifestTooLarge { .. } | Self::BodyTooLarge { .. } => {
                "The manifest is too large"
            }
            Self::UnsupportedMediaType { .. } => "Unsupported media type",
            Self::InvalidQuery { .. } => "Unusable query parameter",
            Self::RouteNotFound => "No such endpoint",
            Self::MethodNotAllowed => "Method not allowed",
            Self::ReportNotFound => "No such report",
            Self::ReportWithdrawn { .. } => "The report has been withdrawn",
            Self::EntryNotFound { .. } => "No such entry in this report",
            Self::PackageNotFound { .. } => "No such package",
            Self::NoPreviousReport => "No earlier assessment of this manifest",
            Self::Unauthorised => "Authentication required",
            Self::WithdrawalNotConfigured => "Withdrawal is not enabled",
            Self::NotReady { .. } => "The service is not ready",
            Self::Database(_) | Self::Panicked => "Internal error",
        }
    }

    /// Fields beyond the four of RFC 9457. A parse failure carries the line,
    /// because a client that cannot see it has to guess.
    fn extensions(&self) -> Map<String, Value> {
        let mut extra = Map::new();
        match self {
            Self::ManifestUnreadable {
                line: Some(line), ..
            } => {
                extra.insert("line".into(), json!(line));
            }
            Self::ManifestTooLarge { entries, limit } => {
                extra.insert("entries".into(), json!(entries));
                extra.insert("limit".into(), json!(limit));
            }
            Self::BodyTooLarge { limit_bytes } => {
                extra.insert("limit_bytes".into(), json!(limit_bytes));
            }
            Self::UnsupportedMediaType { received } => {
                extra.insert("received".into(), json!(received));
                extra.insert(
                    "accepted".into(),
                    json!(["application/toml", "text/plain", "application/json"]),
                );
            }
            Self::ReportWithdrawn {
                withdrawn_at,
                reason,
            } => {
                extra.insert("withdrawn_at".into(), json!(withdrawn_at));
                extra.insert("reason".into(), json!(reason));
            }
            Self::EntryNotFound { package } => {
                extra.insert("package".into(), json!(package));
            }
            Self::PackageNotFound { name } => {
                extra.insert("package".into(), json!(name));
            }
            _ => {}
        }
        extra
    }

    /// What the client is told. A database failure says nothing further, since
    /// its text describes the schema and not the request.
    fn detail(&self) -> String {
        match self {
            Self::ManifestUnreadable { detail, .. } => detail.clone(),
            Self::ManifestEmpty => {
                "The file parsed, but no dependency was found to assess. A lockfile with only the workspace members in it has nothing to report on.".into()
            }
            Self::ManifestTooLarge { entries, limit } => {
                format!("The manifest holds {entries} entries and this service accepts {limit}.")
            }
            Self::BodyTooLarge { limit_bytes } => {
                format!("The body is longer than the {limit_bytes} bytes this service accepts.")
            }
            Self::InvalidQuery { detail } => detail.clone(),
            Self::RouteNotFound => {
                "No endpoint answers that path. The reference at /docs lists every one.".into()
            }
            Self::MethodNotAllowed => {
                "The path exists but not for this method. The reference at /docs lists what each endpoint accepts.".into()
            }
            Self::ReportNotFound => {
                "The link has never addressed a report on this deployment. A report that existed and was withdrawn answers differently, so the two cases can be told apart.".into()
            }
            Self::ReportWithdrawn { reason, .. } => {
                format!("The report existed and has been withdrawn: {reason}")
            }
            Self::EntryNotFound { package } => {
                format!("This report holds no entry named {package}.")
            }
            Self::PackageNotFound { name } => {
                format!("No package named {name} is present in the registry snapshot.")
            }
            Self::NoPreviousReport => {
                "A comparison needs an earlier assessment of the same manifest, and this is the first.".into()
            }
            Self::Unauthorised => "This operation needs a bearer token.".into(),
            Self::WithdrawalNotConfigured => {
                "No administrative token is configured, so no report can be withdrawn through the API.".into()
            }
            Self::NotReady { detail } => detail.clone(),
            Self::UnsupportedMediaType { received } => {
                format!("The request carries {received}.")
            }
            Self::Database(_) | Self::Panicked => "The request could not be completed.".into(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.status();

        // Logged here rather than at the call site, so that nothing reaches the
        // client that has not also reached the operator
        if status.is_server_error() {
            tracing::error!(error = %self, problem = self.slug(), "request failed");
        } else {
            tracing::debug!(error = %self, problem = self.slug(), "request refused");
        }

        let mut body = Map::new();
        body.insert("type".into(), json!(format!("/problems/{}", self.slug())));
        body.insert("title".into(), json!(self.title()));
        body.insert("status".into(), json!(status.as_u16()));
        body.insert("detail".into(), json!(self.detail()));
        body.extend(self.extensions());

        let mut response = (status, Json(Value::Object(body))).into_response();
        response.headers_mut().insert(
            axum::http::header::CONTENT_TYPE,
            axum::http::HeaderValue::from_static("application/problem+json"),
        );
        response
    }
}

/// Report creation raises its own conditions. The two the caller can act on are
/// mapped, the rest stay internal.
pub fn from_create_report(error: sqlx::Error) -> ApiError {
    let Some(db) = error.as_database_error() else {
        return ApiError::Database(error);
    };
    match db.code().as_deref() {
        // invalid_parameter_value, raised for a manifest the function refuses
        Some("22023") => ApiError::ManifestUnreadable {
            detail: db.message().to_owned(),
            line: None,
        },
        // object_not_in_prerequisite_state, raised when no run or model exists
        Some("55000") => ApiError::NotReady {
            detail: db.message().to_owned(),
        },
        _ => ApiError::Database(error),
    }
}
