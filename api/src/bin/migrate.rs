//! Applies the migrations, for a deployment that has no sqlx-cli to hand.
//!
//! The migration files are embedded at compile time, so this binary carries the
//! schema it knows how to create and cannot drift from the image it ships in.
//! It connects as the schema owner, which is why it takes DATABASE_URL and not
//! the application's own connection string: the service itself has no privilege
//! to create anything.

use std::process::ExitCode;

use sqlx::postgres::PgPoolOptions;

#[tokio::main]
async fn main() -> ExitCode {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        eprintln!("migrate: DATABASE_URL is not set. It has to be the schema owner.");
        return ExitCode::FAILURE;
    };

    let pool = match PgPoolOptions::new().max_connections(1).connect(&url).await {
        Ok(pool) => pool,
        Err(error) => {
            eprintln!("migrate: {error}");
            return ExitCode::FAILURE;
        }
    };

    match sqlx::migrate!("../db/migrations").run(&pool).await {
        Ok(()) => {
            println!("migrate: the schema is up to date");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("migrate: {error}");
            ExitCode::FAILURE
        }
    }
}
