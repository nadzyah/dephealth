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

/// Where a configured value comes from. The process environment is one source
/// and a test fixture is another, which is what makes every refusal below
/// reachable without mutating the environment of the test runner.
pub type Source<'a> = &'a dyn Fn(&str) -> Option<String>;

impl Config {
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::read(&|key| env::var(key).ok())
    }

    pub fn read(source: Source<'_>) -> Result<Self, ConfigError> {
        let database_url = required(source, "API_DATABASE_URL")?;
        let manifest_salt = required(source, "MANIFEST_SALT")?;

        if manifest_salt.len() < 16 {
            return Err(ConfigError::Invalid {
                key: "MANIFEST_SALT",
                detail: "at least 16 characters, since it protects the fingerprint against a dictionary of plausible manifests".into(),
            });
        }

        let bind = optional(source, "API_BIND")
            .unwrap_or_else(|| "127.0.0.1:8080".into())
            .parse()
            .map_err(|e: std::net::AddrParseError| ConfigError::Invalid {
                key: "API_BIND",
                detail: e.to_string(),
            })?;

        let admin_token = optional(source, "API_ADMIN_TOKEN").filter(|t| !t.is_empty());
        if admin_token.as_ref().is_some_and(|token| token.len() < 32) {
            return Err(ConfigError::Invalid {
                key: "API_ADMIN_TOKEN",
                detail: "at least 32 characters, or unset to disable withdrawal".into(),
            });
        }

        let public_base_url = optional(source, "API_PUBLIC_BASE_URL")
            .unwrap_or_else(|| "http://localhost:8080".into())
            .trim_end_matches('/')
            .to_owned();

        let cors_origins = optional(source, "API_CORS_ORIGINS")
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
            max_manifest_bytes: number(source, "API_MAX_MANIFEST_BYTES", 2 * 1024 * 1024)?,
            max_entries: number(source, "API_MAX_ENTRIES", 2000)?,
            pool_size: number(source, "API_POOL_SIZE", 8)?,
            request_timeout: Duration::from_secs(number(
                source,
                "API_REQUEST_TIMEOUT_SECONDS",
                15,
            )?),
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

fn required(source: Source<'_>, key: &'static str) -> Result<String, ConfigError> {
    optional(source, key).ok_or(ConfigError::Missing(key))
}

/// A value present but blank counts as absent, so an unset variable and one
/// emptied in a deployment behave alike.
fn optional(source: Source<'_>, key: &str) -> Option<String> {
    source(key)
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
}

fn number<T>(source: Source<'_>, key: &'static str, default: T) -> Result<T, ConfigError>
where
    T: std::str::FromStr,
    T::Err: fmt::Display,
{
    match optional(source, key) {
        None => Ok(default),
        Some(raw) => raw.parse().map_err(|e: T::Err| ConfigError::Invalid {
            key,
            detail: e.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// The two values with no default, so that a case under test sets only what
    /// it is about.
    fn minimal() -> HashMap<&'static str, String> {
        HashMap::from([
            (
                "API_DATABASE_URL",
                "postgres://localhost/dephealth".to_owned(),
            ),
            ("MANIFEST_SALT", "0123456789abcdef".to_owned()),
        ])
    }

    fn read(values: &HashMap<&'static str, String>) -> Result<Config, ConfigError> {
        Config::read(&|key| values.get(key).cloned())
    }

    #[test]
    fn a_missing_value_names_itself() {
        let mut values = minimal();
        values.remove("MANIFEST_SALT");

        let error = read(&values).expect_err("a refusal");
        assert!(matches!(error, ConfigError::Missing("MANIFEST_SALT")));
        assert_eq!(error.to_string(), "MANIFEST_SALT is not set");
    }

    #[test]
    fn a_blank_value_counts_as_absent() {
        let mut values = minimal();
        values.insert("API_DATABASE_URL", "   ".to_owned());

        assert!(matches!(
            read(&values),
            Err(ConfigError::Missing("API_DATABASE_URL"))
        ));
    }

    #[test]
    fn a_salt_short_enough_to_be_guessed_is_refused() {
        let mut values = minimal();
        values.insert("MANIFEST_SALT", "short".to_owned());

        let error = read(&values).expect_err("a refusal");
        assert!(matches!(
            error,
            ConfigError::Invalid {
                key: "MANIFEST_SALT",
                ..
            }
        ));
    }

    #[test]
    fn an_administrative_token_is_either_long_or_unset() {
        let mut values = minimal();
        values.insert("API_ADMIN_TOKEN", "too-short-to-be-a-credential".to_owned());
        assert!(matches!(
            read(&values),
            Err(ConfigError::Invalid {
                key: "API_ADMIN_TOKEN",
                ..
            })
        ));

        // Unset disables withdrawal rather than weakening it, which is why an
        // empty value is not a usable credential either
        values.insert("API_ADMIN_TOKEN", "".to_owned());
        assert!(
            read(&values)
                .expect("a configuration")
                .admin_token
                .is_none()
        );

        values.insert("API_ADMIN_TOKEN", "t".repeat(32));
        assert!(
            read(&values)
                .expect("a configuration")
                .admin_token
                .is_some()
        );
    }

    #[test]
    fn an_unparsable_value_names_the_key_it_came_from() {
        let mut values = minimal();
        values.insert("API_BIND", "not-an-address".to_owned());
        assert!(matches!(
            read(&values),
            Err(ConfigError::Invalid {
                key: "API_BIND",
                ..
            })
        ));

        let mut values = minimal();
        values.insert("API_MAX_ENTRIES", "many".to_owned());
        assert!(matches!(
            read(&values),
            Err(ConfigError::Invalid {
                key: "API_MAX_ENTRIES",
                ..
            })
        ));
    }

    #[test]
    fn a_trailing_slash_on_the_public_address_does_not_reach_a_link() {
        let mut values = minimal();
        values.insert(
            "API_PUBLIC_BASE_URL",
            "https://dephealth.example/".to_owned(),
        );

        let config = read(&values).expect("a configuration");
        assert_eq!(
            config.report_link("abc"),
            "https://dephealth.example/r/abc",
            "a doubled slash would break the link the report is addressed by"
        );
    }

    #[test]
    fn several_origins_are_read_as_a_list() {
        let mut values = minimal();
        values.insert(
            "API_CORS_ORIGINS",
            "https://one.example, https://two.example ,".to_owned(),
        );

        let config = read(&values).expect("a configuration");
        assert_eq!(
            config.cors_origins,
            ["https://one.example", "https://two.example"]
        );
    }

    #[test]
    fn the_debug_form_prints_no_secret() {
        let mut values = minimal();
        values.insert("API_ADMIN_TOKEN", "t".repeat(32));

        let printed = format!("{:?}", read(&values).expect("a configuration"));
        assert!(!printed.contains("0123456789abcdef"), "{printed}");
        assert!(!printed.contains("postgres://"), "{printed}");
        assert!(!printed.contains(&"t".repeat(32)), "{printed}");
        assert_eq!(printed.matches("[redacted]").count(), 3);
    }
}
