use std::{env, fmt, net::SocketAddr, time::Duration};

/// Everything the service reads from its environment, collected once at
/// startup so that a missing value stops the process instead of a request.
#[derive(Clone)]
pub struct Config {
    pub database_url: String,
    pub bind: SocketAddr,
    pub manifest_salt: String,
    pub admin_token: Option<String>,
    pub public_base_url: String,
    pub cors_origins: Vec<String>,
    pub max_manifest_bytes: usize,
    pub max_entries: usize,
    pub pool_size: u32,
    pub request_timeout: Duration,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("{0} is not set")]
    Missing(&'static str),
    #[error("{key} is not usable: {detail}")]
    Invalid { key: &'static str, detail: String },
}

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        let database_url = required("API_DATABASE_URL")?;
        let manifest_salt = required("MANIFEST_SALT")?;

        if manifest_salt.len() < 16 {
            return Err(ConfigError::Invalid {
                key: "MANIFEST_SALT",
                detail: "at least 16 characters, since it protects the fingerprint against a dictionary of plausible manifests".into(),
            });
        }

        let bind = optional("API_BIND")
            .unwrap_or_else(|| "127.0.0.1:8080".into())
            .parse()
            .map_err(|e: std::net::AddrParseError| ConfigError::Invalid {
                key: "API_BIND",
                detail: e.to_string(),
            })?;

        let admin_token = optional("API_ADMIN_TOKEN").filter(|t| !t.is_empty());
        if admin_token.as_ref().is_some_and(|token| token.len() < 32) {
            return Err(ConfigError::Invalid {
                key: "API_ADMIN_TOKEN",
                detail: "at least 32 characters, or unset to disable withdrawal".into(),
            });
        }

        let public_base_url = optional("API_PUBLIC_BASE_URL")
            .unwrap_or_else(|| "http://localhost:8080".into())
            .trim_end_matches('/')
            .to_owned();

        let cors_origins = optional("API_CORS_ORIGINS")
            .unwrap_or_else(|| "http://localhost:5173".into())
            .split(',')
            .map(|o| o.trim().to_owned())
            .filter(|o| !o.is_empty())
            .collect();

        Ok(Self {
            database_url,
            bind,
            manifest_salt,
            admin_token,
            public_base_url,
            cors_origins,
            max_manifest_bytes: number("API_MAX_MANIFEST_BYTES", 2 * 1024 * 1024)?,
            max_entries: number("API_MAX_ENTRIES", 2000)?,
            pool_size: number("API_POOL_SIZE", 8)?,
            request_timeout: Duration::from_secs(number("API_REQUEST_TIMEOUT_SECONDS", 15)?),
        })
    }

    /// The permanent link a report is reachable by. The token appears here and
    /// in the response, and nowhere else.
    pub fn report_link(&self, token: &str) -> String {
        format!("{}/r/{token}", self.public_base_url)
    }
}

/// Written by hand, because the derived form would print the connection string
/// and the salt into any log line that reports the configuration.
impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("bind", &self.bind)
            .field("public_base_url", &self.public_base_url)
            .field("cors_origins", &self.cors_origins)
            .field("max_manifest_bytes", &self.max_manifest_bytes)
            .field("max_entries", &self.max_entries)
            .field("pool_size", &self.pool_size)
            .field("request_timeout", &self.request_timeout)
            .field("database_url", &"[redacted]")
            .field("manifest_salt", &"[redacted]")
            .field(
                "admin_token",
                &self.admin_token.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

fn required(key: &'static str) -> Result<String, ConfigError> {
    optional(key).ok_or(ConfigError::Missing(key))
}

fn optional(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
}

fn number<T>(key: &'static str, default: T) -> Result<T, ConfigError>
where
    T: std::str::FromStr,
    T::Err: fmt::Display,
{
    match optional(key) {
        None => Ok(default),
        Some(raw) => raw.parse().map_err(|e: T::Err| ConfigError::Invalid {
            key,
            detail: e.to_string(),
        }),
    }
}
