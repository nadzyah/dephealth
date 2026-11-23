use axum::{
    Json,
    body::Body,
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use utoipa::ToSchema;

use super::{AppState, reports};
use crate::{
    db,
    dto::{Problem, Report},
    error::{self, ApiError},
    manifest::{self, Entry, ManifestError},
};

const LOCKFILE_EXAMPLE: &str = r#"version = 4

[[package]]
name = "my-service"
version = "0.1.0"
dependencies = ["serde", "tiny-config"]

[[package]]
name = "serde"
version = "1.0.228"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "tiny-config"
version = "0.3.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#;

/// Assess a dependency manifest
///
/// The only endpoint that writes anything.
///
/// A `Cargo.lock` arrives as `application/toml` or `text/plain`. A client that
/// has resolved its own tree may send the entries as JSON instead. The lockfile
/// holds the resolved transitive set, so nothing is resolved again here. What it
/// does not hold is the kind of each dependency, so a development dependency
/// cannot be told from a normal one and every entry is assessed.
///
/// The manifest is read and discarded. What is kept is the report and a salted
/// fingerprint of the entry set, which is what lets a later submission of the
/// same manifest be recognised without the manifest having been stored.
#[utoipa::path(
    post,
    path = "/assessments",
    tag = "Assessments",
    operation_id = "createAssessment",
    request_body(
        description = "A Cargo lockfile, or an already resolved entry list",
        content(
            (String = "application/toml", example = json!(LOCKFILE_EXAMPLE)),
            (EntryList = "application/json")
        )
    ),
    responses(
        (status = CREATED, description = "The assessment was stored", body = Report,
         headers(("Location" = String, description = "The report, relative to this server"))),
        (status = PAYLOAD_TOO_LARGE, description = "Larger than this deployment accepts",
         body = Problem, content_type = "application/problem+json"),
        (status = UNSUPPORTED_MEDIA_TYPE, description = "Not a form this endpoint accepts",
         body = Problem, content_type = "application/problem+json"),
        (status = UNPROCESSABLE_ENTITY,
         description = "The manifest could not be read, or held nothing to assess. A parse \
                        failure carries the line it stopped at. No partial assessment is \
                        produced, since a partial tree would understate the exposure",
         body = Problem, content_type = "application/problem+json"),
        (status = SERVICE_UNAVAILABLE,
         description = "No completed ingestion run or no current model, so there is nothing \
                        to report",
         body = Problem, content_type = "application/problem+json")
    )
)]
pub async fn create(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> Result<Response, ApiError> {
    let limit_bytes = state.config.max_manifest_bytes;
    let bytes = axum::body::to_bytes(body, limit_bytes)
        .await
        .map_err(|_| ApiError::BodyTooLarge { limit_bytes })?;

    let text = String::from_utf8(bytes.to_vec()).map_err(|e| ApiError::ManifestUnreadable {
        detail: format!(
            "the body is not valid UTF-8, at byte {}",
            e.utf8_error().valid_up_to()
        ),
        line: None,
    })?;

    let entries = match submission(&headers) {
        Submission::Lockfile => manifest::parse_lockfile(&text).map_err(to_api_error)?,
        Submission::Json => from_json(&text)?,
        Submission::Unsupported(received) => {
            return Err(ApiError::UnsupportedMediaType { received });
        }
    };

    if entries.len() > state.config.max_entries {
        return Err(ApiError::ManifestTooLarge {
            entries: entries.len(),
            limit: state.config.max_entries,
        });
    }

    // Thirty-two bytes from a generator seeded by the operating system. Only
    // the digest is stored, so a link cannot be recovered from a dump
    let token = hex::encode(rand::random::<[u8; 32]>());

    db::create_report(&state.pool, &token, &state.config.manifest_salt, &entries)
        .await
        .map_err(error::from_create_report)?;

    let report = reports::load(&state, &token)
        .await?
        .ok_or(ApiError::ReportNotFound)?;

    let report = Report {
        link: Some(state.config.report_link(&token)),
        ..report
    };

    tracing::info!(
        entries = entries.len(),
        resolved = report.counts.resolved,
        "assessment stored"
    );

    Ok((
        StatusCode::CREATED,
        [(header::LOCATION, format!("/api/v1/reports/{token}"))],
        Json(report),
    )
        .into_response())
}

/// An already resolved entry set, for a client that has done its own resolution.
#[derive(Debug, Deserialize, ToSchema)]
pub struct EntryList {
    #[schema(min_items = 1)]
    pub entries: Vec<EntryInput>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct EntryInput {
    #[schema(example = "serde")]
    pub name: String,
    #[schema(example = "1.0.228")]
    pub version: String,
    /// Zero for a direct dependency of the submitting project.
    #[serde(default)]
    #[schema(minimum = 0, default = 0)]
    pub depth: i32,
    /// False for a path or git dependency. Such an entry is never matched by
    /// name against a published package, since a local crate may share the name
    /// of one.
    #[serde(default = "from_registry_default")]
    #[schema(default = true)]
    pub from_registry: bool,
}

fn from_registry_default() -> bool {
    true
}

enum Submission {
    Lockfile,
    Json,
    Unsupported(String),
}

/// A missing content type is read as a lockfile, since that is what `curl
/// --data-binary @Cargo.lock` sends.
fn submission(headers: &HeaderMap) -> Submission {
    let Some(value) = headers.get(header::CONTENT_TYPE) else {
        return Submission::Lockfile;
    };

    let essence = value
        .to_str()
        .unwrap_or_default()
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_lowercase();

    match essence.as_str() {
        "" | "application/toml" | "text/toml" | "text/plain" | "application/octet-stream" => {
            Submission::Lockfile
        }
        "application/json" => Submission::Json,
        other => Submission::Unsupported(other.to_owned()),
    }
}

fn from_json(text: &str) -> Result<Vec<Entry>, ApiError> {
    let body: EntryList = serde_json::from_str(text).map_err(|e| ApiError::ManifestUnreadable {
        detail: e.to_string(),
        line: Some(e.line()),
    })?;

    if body.entries.is_empty() {
        return Err(ApiError::ManifestEmpty);
    }

    body.entries
        .into_iter()
        .map(|entry| {
            if entry.name.trim().is_empty() || entry.version.trim().is_empty() {
                return Err(ApiError::ManifestUnreadable {
                    detail: "every entry needs a name and a version".into(),
                    line: None,
                });
            }
            if entry.depth < 0 {
                return Err(ApiError::ManifestUnreadable {
                    detail: "a depth cannot be negative".into(),
                    line: None,
                });
            }
            Ok(Entry {
                name: entry.name.trim().to_owned(),
                version: entry.version.trim().to_owned(),
                depth: entry.depth,
                from_registry: entry.from_registry,
            })
        })
        .collect()
}

fn to_api_error(error: ManifestError) -> ApiError {
    match error {
        ManifestError::Unreadable { detail, line } => ApiError::ManifestUnreadable { detail, line },
        ManifestError::Empty => ApiError::ManifestEmpty,
    }
}
