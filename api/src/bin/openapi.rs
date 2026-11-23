//! Writes the API specification that `docs/api/openapi.yaml` holds. Run through
//! `make openapi`, and checked by a test, so the committed copy cannot drift
//! away from the handlers it is generated from.

use std::process::ExitCode;

fn main() -> ExitCode {
    match dephealth_api::http::api_document().to_yaml() {
        Ok(yaml) => {
            print!("{yaml}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("openapi: {error}");
            ExitCode::FAILURE
        }
    }
}
