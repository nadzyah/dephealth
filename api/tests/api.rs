//! Integration tests over the real schema. They need the database of
//! `make db-up migrate roles seed` and they read the environment of the
//! repository root, so `make api-test` and `cargo test` behave the same.
//!
//! Each test drives the router directly rather than a listening socket, which
//! keeps them independent of a port being free.

use std::sync::Arc;

use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode, header},
};
use dephealth_api::{config::Config, db, http, http::AppState};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

const LOCKFILE: &str = include_str!("fixtures/Cargo.lock");

async fn service() -> Router {
    dotenvy::from_path("../.env").ok();

    let config = Config::from_env().expect("the API environment of .env");
    let pool = db::connect(&config)
        .await
        .expect("a database to connect to, from make db-up migrate roles seed");

    http::router(AppState {
        pool,
        config: Arc::new(config),
    })
}

fn admin_token() -> String {
    dotenvy::from_path("../.env").ok();
    std::env::var("API_ADMIN_TOKEN").expect("API_ADMIN_TOKEN in .env")
}

async fn send(app: &Router, request: Request<Body>) -> (StatusCode, Value, Vec<(String, String)>) {
    let response = app.clone().oneshot(request).await.expect("a response");
    let status = response.status();

    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.as_str().to_owned(),
                value.to_str().unwrap_or_default().to_owned(),
            )
        })
        .collect();

    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("a readable body")
        .to_bytes();

    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes)
            .unwrap_or(Value::String(String::from_utf8_lossy(&bytes).into_owned()))
    };

    (status, body, headers)
}

fn submit(body: &str, content_type: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/api/v1/assessments")
        .header(header::CONTENT_TYPE, content_type)
        .body(Body::from(body.to_owned()))
        .expect("a request")
}

fn get(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .body(Body::empty())
        .expect("a request")
}

fn header_of(headers: &[(String, String)], name: &str) -> Option<String> {
    headers
        .iter()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.clone())
}

/// Submits the committed lockfile and returns the token of the stored report.
async fn stored_report(app: &Router) -> String {
    let (status, body, headers) = send(app, submit(LOCKFILE, "application/toml")).await;
    assert_eq!(status, StatusCode::CREATED, "{body}");

    let location = header_of(&headers, "location").expect("a Location header");
    assert!(location.starts_with("/api/v1/reports/"));

    body["link"]
        .as_str()
        .expect("a link")
        .rsplit('/')
        .next()
        .expect("a token in the link")
        .to_owned()
}

#[tokio::test]
async fn liveness_does_not_depend_on_the_database() {
    let app = service().await;
    let (status, body, _) = send(&app, get("/health/live")).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "live");
}

#[tokio::test]
async fn the_method_is_reported_from_the_database() {
    let app = service().await;
    let (status, body, _) = send(&app, get("/api/v1/meta")).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["method"]["abandonment_window_days"], 180);
    assert_eq!(body["method"]["contributor_disclosure_threshold"], 5);
    assert_eq!(body["sources"].as_array().expect("two sources").len(), 2);
}

#[tokio::test]
async fn a_submitted_lockfile_is_assessed_and_ranked() {
    let app = service().await;
    let (_, body, _) = send(&app, submit(LOCKFILE, "application/toml")).await;

    let entries = body["entries"].as_array().expect("entries");
    assert_eq!(
        body["counts"]["entries"].as_u64().expect("a count"),
        entries.len() as u64
    );

    // Scored entries first, then by descending risk
    let scored: Vec<f64> = entries
        .iter()
        .filter(|e| e["resolved"] == true)
        .map(|e| e["risk"]["probability"].as_f64().expect("a probability"))
        .collect();
    assert!(scored.len() >= 4, "the seed data holds four of these");
    assert!(
        scored.windows(2).all(|pair| pair[0] >= pair[1]),
        "ranked by descending risk: {scored:?}"
    );
    assert!(
        entries
            .iter()
            .position(|e| e["resolved"] == false)
            .unwrap_or(entries.len())
            >= scored.len(),
        "every scored entry comes before the first unscored one"
    );

    // The indirect entries are present and marked as such
    assert!(entries.iter().any(|e| e["relation"] == "indirect"));
    assert!(entries.iter().any(|e| e["relation"] == "direct"));

    // An entry that cannot be assessed carries its reason and a remedy
    let unresolved: Vec<&Value> = entries.iter().filter(|e| e["resolved"] == false).collect();
    assert!(!unresolved.is_empty());
    for entry in &unresolved {
        assert!(entry["unresolved"]["reason"].is_string());
        assert!(!entry["unresolved"]["remedy"].as_str().unwrap().is_empty());
        assert!(entry["risk"].is_null());
    }

    // The path dependency of the fixture, which must not be matched by name
    let local = entries
        .iter()
        .find(|e| e["package_name"] == "local-helper")
        .expect("the path dependency");
    assert_eq!(local["unresolved"]["reason"], "not_a_registry_package");

    // The age of both sources travels with the report
    assert!(body["data_as_of"]["registry"].is_string());
    assert!(body["data_as_of"]["events"].is_string());

    // The models behind the figures are named
    assert!(body["method"]["risk_model"]["name"].is_string());
    assert!(body["method"]["forecast_model"]["name"].is_string());
}

#[tokio::test]
async fn a_stored_report_reads_back_with_the_same_figures() {
    let app = service().await;
    let token = stored_report(&app).await;

    let (status, body, _) = send(&app, get(&format!("/api/v1/reports/{token}"))).await;
    assert_eq!(status, StatusCode::OK);

    // The token is not recoverable from a stored report, so no link comes back
    assert!(body["link"].is_null());

    let failure = body["entries"]
        .as_array()
        .expect("entries")
        .iter()
        .find(|e| e["package_name"] == "failure")
        .expect("the seeded abandoned package");
    // The figure db/seed/test_data.sql stores for it
    assert_eq!(failure["risk"]["probability"], 0.9089);
}

#[tokio::test]
async fn an_entry_carries_the_evidence_behind_its_score() {
    let app = service().await;
    let token = stored_report(&app).await;

    let (status, body, _) = send(
        &app,
        get(&format!("/api/v1/reports/{token}/entries/FAILURE")),
    )
    .await;

    assert_eq!(status, StatusCode::OK, "the name is matched without case");

    // The factors that moved the score, which is what the detail view shows
    let factors = body["factors"].as_array().expect("factors");
    assert!(!factors.is_empty());
    let contributions: Vec<f64> = factors
        .iter()
        .map(|f| f["contribution"].as_f64().expect("a contribution").abs())
        .collect();
    assert!(
        contributions.windows(2).all(|pair| pair[0] >= pair[1]),
        "ordered by the size of the contribution: {contributions:?}"
    );
    assert!(factors.iter().all(|f| f["direction"].is_string()));

    // The observed series behind the forecast
    assert!(!body["downloads"].as_array().expect("a series").is_empty());

    // The current assessment alongside the stored one
    assert_eq!(body["live"]["package_name"], "failure");
}

#[tokio::test]
async fn a_contributor_count_below_the_threshold_is_withheld_rather_than_shown() {
    let app = service().await;
    let (status, body, _) = send(&app, get("/api/v1/packages/solo-crate")).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["activity"]["contributor_count_withheld"], true);
    assert!(body["activity"]["distinct_contributors"].is_null());

    // A count of zero describes nobody, so it is published
    let (_, failure, _) = send(&app, get("/api/v1/packages/failure")).await;
    assert_eq!(failure["activity"]["distinct_contributors"], 0);
    assert_eq!(failure["activity"]["contributor_count_withheld"], false);
}

#[tokio::test]
async fn a_resubmission_is_compared_with_the_assessment_before_it() {
    let app = service().await;

    // A manifest this run is the first to submit, since the comparison is
    // matched on the entry set and the database keeps every earlier report
    let unique = format!(
        "only-in-this-run-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("a clock after 1970")
            .as_nanos()
    );
    let manifest = format!(
        r#"{{"entries":[{{"name":"serde","version":"1.0.228"}},
                        {{"name":"{unique}","version":"0.1.0","from_registry":false}}]}}"#
    );

    let submit_unique = || async {
        let (status, body, _) = send(&app, submit(&manifest, "application/json")).await;
        assert_eq!(status, StatusCode::CREATED, "{body}");
        body["link"]
            .as_str()
            .expect("a link")
            .rsplit('/')
            .next()
            .expect("a token")
            .to_owned()
    };

    let first = submit_unique().await;
    let (status, _, _) = send(&app, get(&format!("/api/v1/reports/{first}/changes"))).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a report with nothing before it cannot be compared"
    );

    let second = submit_unique().await;
    let (status, body, _) = send(&app, get(&format!("/api/v1/reports/{second}/changes"))).await;

    assert_eq!(status, StatusCode::OK);
    let packages = body["packages"].as_array().expect("a comparison");
    assert_eq!(packages.len(), 2);
    assert!(packages.iter().all(|p| p["verdict"].is_string()));
    assert!(packages.iter().any(|p| p["verdict"] == "unchanged"));
}

#[tokio::test]
async fn a_withdrawn_report_answers_differently_from_one_that_never_existed() {
    let app = service().await;
    let token = stored_report(&app).await;

    let withdrawal = |authorisation: Option<String>, reason: &str| {
        let mut request = Request::builder()
            .method("POST")
            .uri(format!("/api/v1/reports/{token}/withdrawal"))
            .header(header::CONTENT_TYPE, "application/json");
        if let Some(value) = authorisation {
            request = request.header(header::AUTHORIZATION, value);
        }
        request
            .body(Body::from(format!(r#"{{"reason":"{reason}"}}"#)))
            .expect("a request")
    };

    let (status, _, _) = send(&app, withdrawal(None, "no credential")).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, _, _) = send(
        &app,
        withdrawal(Some("Bearer not-the-token".into()), "wrong credential"),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let token_header = format!("Bearer {}", admin_token());

    let (status, body, _) = send(&app, withdrawal(Some(token_header.clone()), "   ")).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");

    let (status, _, _) = send(
        &app,
        withdrawal(
            Some(token_header.clone()),
            "Withdrawn by the integration test",
        ),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);

    let (status, body, headers) = send(&app, get(&format!("/api/v1/reports/{token}"))).await;
    assert_eq!(status, StatusCode::GONE);
    assert_eq!(body["type"], "/problems/report-withdrawn");
    assert_eq!(body["reason"], "Withdrawn by the integration test");
    assert_eq!(
        header_of(&headers, "content-type").as_deref(),
        Some("application/problem+json")
    );

    // Withdrawal cannot be reversed
    let (status, _, _) = send(&app, withdrawal(Some(token_header), "a second withdrawal")).await;
    assert_eq!(status, StatusCode::GONE);

    let never_existed = "0".repeat(64);
    let (status, body, _) = send(&app, get(&format!("/api/v1/reports/{never_existed}"))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["type"], "/problems/report-not-found");
}

#[tokio::test]
async fn a_manifest_that_cannot_be_read_reports_the_line() {
    let app = service().await;
    let (status, body, headers) = send(
        &app,
        submit(
            "version = 4\n\n[[package\nname = \"x\"\n",
            "application/toml",
        ),
    )
    .await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["type"], "/problems/manifest-unreadable");
    assert_eq!(body["line"], 3);
    assert_eq!(
        header_of(&headers, "content-type").as_deref(),
        Some("application/problem+json")
    );
}

#[tokio::test]
async fn a_lockfile_with_nothing_to_assess_is_refused() {
    let app = service().await;
    let manifest = "[[package]]\nname = \"my-service\"\nversion = \"0.1.0\"\n";
    let (status, body, _) = send(&app, submit(manifest, "application/toml")).await;

    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(body["type"], "/problems/manifest-empty");
}

#[tokio::test]
async fn a_body_in_another_form_is_refused_with_what_is_accepted() {
    let app = service().await;
    let (status, body, _) = send(&app, submit("<a/>", "application/xml")).await;

    assert_eq!(status, StatusCode::UNSUPPORTED_MEDIA_TYPE);
    assert_eq!(body["received"], "application/xml");
    assert!(body["accepted"].is_array());
}

#[tokio::test]
async fn an_already_resolved_entry_list_may_be_submitted_as_json() {
    let app = service().await;
    let body = r#"{"entries":[{"name":"serde","version":"1.0.228"},
                              {"name":"my-local","version":"0.1.0","from_registry":false}]}"#;

    let (status, body, _) = send(&app, submit(body, "application/json")).await;

    assert_eq!(status, StatusCode::CREATED);
    assert_eq!(body["counts"]["entries"], 2);
    assert_eq!(body["counts"]["resolved"], 1);
}

#[tokio::test]
async fn an_unusable_query_parameter_is_refused() {
    let app = service().await;

    for uri in [
        "/api/v1/packages?limit=0",
        "/api/v1/packages?limit=9999",
        "/api/v1/packages?offset=-1",
        "/api/v1/packages/serde/downloads?from=2026-12-01&to=2026-01-01",
    ] {
        let (status, body, _) = send(&app, get(uri)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{uri} gave {body}");
        assert_eq!(body["type"], "/problems/invalid-query-parameter");
    }
}

#[tokio::test]
async fn an_unknown_package_and_an_unknown_endpoint_both_answer_as_problems() {
    let app = service().await;

    let (status, body, _) = send(&app, get("/api/v1/packages/left-pad")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["type"], "/problems/package-not-found");

    let (status, body, _) = send(&app, get("/api/v1/nope")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["type"], "/problems/no-such-endpoint");
}

#[tokio::test]
async fn readiness_reports_the_database_and_every_source() {
    let app = service().await;
    let (status, body, _) = send(&app, get("/health/ready")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "ready");
    assert_eq!(body["database"], "reachable");
    assert!(
        body["sources_never_ingested"]
            .as_array()
            .expect("the list of sources never ingested")
            .is_empty(),
        "a seeded database has ingested every source: {body}"
    );

    for source in body["sources"].as_array().expect("the sources") {
        assert!(
            source["data_as_of"].is_string(),
            "a source with no date makes the service unready: {source}"
        );
    }
}

#[tokio::test]
async fn the_listing_is_ranked_and_pages_without_losing_its_place() {
    let app = service().await;

    let (status, first, _) = send(&app, get("/api/v1/packages?limit=2")).await;
    assert_eq!(status, StatusCode::OK, "{first}");
    assert_eq!(first["limit"], 2);
    assert_eq!(first["offset"], 0);

    let items = first["items"].as_array().expect("a page of packages");
    assert_eq!(items.len(), 2);

    let risk = |item: &Value| item["risk_probability"].as_f64().expect("a probability");
    assert!(
        risk(&items[0]) >= risk(&items[1]),
        "the listing is ranked by descending risk: {first}"
    );

    // The second page has to begin where the first ended, which is the property
    // an offset walk depends on within one ingestion run
    let (_, second, _) = send(&app, get("/api/v1/packages?limit=2&offset=1")).await;
    assert_eq!(
        second["items"][0]["package_name"], items[1]["package_name"],
        "{second}"
    );
}

#[tokio::test]
async fn a_name_is_matched_without_regard_to_case() {
    let app = service().await;
    let (status, body, _) = send(&app, get("/api/v1/packages?q=SERDE")).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let names: Vec<&str> = body["items"]
        .as_array()
        .expect("the matches")
        .iter()
        .map(|item| item["package_name"].as_str().expect("a name"))
        .collect();
    assert!(names.contains(&"serde"), "{names:?}");
}

#[tokio::test]
async fn a_download_series_is_bounded_by_the_requested_range() {
    let app = service().await;

    let (status, body, _) = send(
        &app,
        get("/api/v1/packages/serde/downloads?from=2026-01-01&to=2026-01-31"),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");

    let days: Vec<&str> = body
        .as_array()
        .expect("a series")
        .iter()
        .map(|point| point["day"].as_str().expect("a day"))
        .collect();

    assert!(!days.is_empty(), "the fixture covers that month");
    assert!(
        days.windows(2).all(|pair| pair[0] < pair[1]),
        "the series is ascending: {days:?}"
    );
    assert!(
        days.iter()
            .all(|day| *day >= "2026-01-01" && *day <= "2026-01-31"),
        "every point lies inside the requested range: {days:?}"
    );

    let (status, body, _) = send(&app, get("/api/v1/packages/left-pad/downloads")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["type"], "/problems/package-not-found");
}

#[tokio::test]
async fn a_method_the_endpoint_does_not_serve_is_refused_as_a_problem() {
    let app = service().await;
    let request = Request::builder()
        .method("DELETE")
        .uri("/api/v1/packages")
        .body(Body::empty())
        .expect("a request");

    let (status, body, _) = send(&app, request).await;
    assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "{body}");
    assert_eq!(body["type"], "/problems/method-not-allowed");
}

#[tokio::test]
async fn the_reference_is_served_from_the_generated_specification() {
    let app = service().await;

    let (status, _, headers) = send(&app, get("/docs/openapi.yaml")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header_of(&headers, "content-type").as_deref(),
        Some("application/yaml; charset=utf-8")
    );

    let (status, _, headers) = send(&app, get("/docs/")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header_of(&headers, "content-type").as_deref(),
        Some("text/html; charset=utf-8")
    );
}

/// The committed specification is generated, so a handler changed without
/// `make openapi` would leave the repository describing an API that no longer
/// exists.
#[test]
fn the_committed_specification_is_current() {
    let committed = include_str!("../../docs/api/openapi.yaml");
    let generated = http::api_document()
        .to_yaml()
        .expect("the specification to serialise");

    assert_eq!(
        committed.trim(),
        generated.trim(),
        "docs/api/openapi.yaml is stale, run make openapi"
    );
}
