use std::{process::ExitCode, sync::Arc};

use dephealth_api::{config::Config, db, http, http::AppState};
use tokio::{net::TcpListener, signal};
use tracing_subscriber::{EnvFilter, fmt};

#[tokio::main]
async fn main() -> ExitCode {
    if let Err(error) = run().await {
        eprintln!("dephealth-api: {error}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let filter = EnvFilter::try_from_env("API_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    // One line of JSON per event where a collector reads the output, and the
    // human form in a terminal. The fields are the same either way, since they
    // are attached to the event and not formatted into its message
    if std::env::var("API_LOG_FORMAT").as_deref() == Ok("json") {
        fmt()
            .json()
            .flatten_event(true)
            .with_env_filter(filter)
            .init();
    } else {
        fmt().with_env_filter(filter).init();
    }

    let config = Config::from_env()?;
    let pool = db::connect(&config).await?;

    // Refused at startup rather than on the first request
    db::ping(&pool).await?;

    let listener = TcpListener::bind(config.bind).await?;
    tracing::info!(address = %listener.local_addr()?, "listening");

    let state = AppState {
        pool: pool.clone(),
        config: Arc::new(config),
    };

    axum::serve(listener, http::router(state))
        .with_graceful_shutdown(shutdown())
        .await?;

    pool.close().await;
    Ok(())
}

/// A report is written in one transaction, so letting the current requests
/// finish cannot leave a half stored assessment behind.
async fn shutdown() {
    let interrupt = async {
        signal::ctrl_c().await.ok();
    };

    #[cfg(unix)]
    let terminate = async {
        if let Ok(mut stream) = signal::unix::signal(signal::unix::SignalKind::terminate()) {
            stream.recv().await;
        }
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = interrupt => {},
        _ = terminate => {},
    }

    tracing::info!("shutting down");
}
