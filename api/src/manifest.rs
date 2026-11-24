//! Reading a Cargo lockfile into the entry set an assessment is made of.
//!
//! The lockfile already holds the resolved transitive set, so nothing is
//! resolved again here. What it does not hold is the shape of the tree, so the
//! depth of each entry is recovered from the dependency lists, nor the kind of
//! a dependency, so a development dependency cannot be told from a normal one
//! and every entry is assessed.

use std::collections::{HashMap, HashSet, VecDeque};

use serde::{Deserialize, Serialize};

/// One package to be assessed, as the database expects it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    pub version: String,
    /// Zero for a direct dependency of the submitted project.
    pub depth: i32,
    /// False for a path or git dependency, which has no registry history and
    /// must not be matched against a published package of the same name.
    pub from_registry: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("{detail}")]
    Unreadable { detail: String, line: Option<usize> },
    #[error("no dependency to assess")]
    Empty,
}

#[derive(Deserialize)]
struct Lockfile {
    #[serde(default)]
    package: Vec<LockPackage>,
}

#[derive(Deserialize)]
struct LockPackage {
    name: String,
    version: String,
    /// Absent for a workspace member, which is the submitter's own code.
    source: Option<String>,
    #[serde(default)]
    dependencies: Vec<String>,
}

/// Parse a `Cargo.lock`. The error carries the line, since a client that cannot
/// see where the file stopped parsing has to guess.
pub fn parse_lockfile(text: &str) -> Result<Vec<Entry>, ManifestError> {
    let lockfile: Lockfile = toml::from_str(text).map_err(|e| ManifestError::Unreadable {
        detail: e.message().to_owned(),
        line: e.span().map(|span| line_of(text, span.start)),
    })?;

    let packages = &lockfile.package;
    if packages.is_empty() {
        return Err(ManifestError::Empty);
    }

    for package in packages {
        if package.name.trim().is_empty() || package.version.trim().is_empty() {
            return Err(ManifestError::Unreadable {
                detail: "a package entry carries an empty name or version".into(),
                line: None,
            });
        }
    }

    let index = Index::of(packages);

    // A root is a package nothing else depends on, which is how a workspace
    // member shows up. A lockfile whose graph has no root is still usable,
    // since a package without a source is local by definition
    let referenced: HashSet<usize> = packages
        .iter()
        .flat_map(|p| p.dependencies.iter())
        .filter_map(|dependency| index.resolve(dependency))
        .collect();

    let mut roots: Vec<usize> = (0..packages.len())
        .filter(|position| !referenced.contains(position))
        .collect();

    if roots.is_empty() {
        roots = (0..packages.len())
            .filter(|position| packages[*position].source.is_none())
            .collect();
    }

    if roots.is_empty() {
        return Err(ManifestError::Unreadable {
            detail: "no root package, so the file does not describe a project's own tree".into(),
            line: None,
        });
    }

    // Breadth first, so the first depth a package is reached at is the
    // shallowest, which is the one the submitter can act on
    let mut depth_of: HashMap<usize, i32> = HashMap::new();
    let mut queue: VecDeque<(usize, i32)> = VecDeque::new();

    for root in &roots {
        for dependency in &packages[*root].dependencies {
            if let Some(position) = index.resolve(dependency) {
                queue.push_back((position, 0));
            }
        }
    }

    while let Some((position, depth)) = queue.pop_front() {
        if depth_of.contains_key(&position) {
            continue;
        }
        depth_of.insert(position, depth);
        for dependency in &packages[position].dependencies {
            if let Some(next) = index.resolve(dependency) {
                queue.push_back((next, depth + 1));
            }
        }
    }

    let root_positions: HashSet<usize> = roots.into_iter().collect();

    // One line per package rather than per version. A score describes a package
    // and the repository behind it, not a release of it, so a tree holding two
    // versions of the same crate is reported once, at the shallowest depth it
    // is reached by and with the newer of the two versions
    let mut shallowest: HashMap<String, Entry> = HashMap::new();

    for (position, depth) in depth_of {
        if root_positions.contains(&position) {
            continue;
        }

        let package = &packages[position];
        let candidate = Entry {
            name: package.name.clone(),
            version: package.version.clone(),
            depth,
            from_registry: package
                .source
                .as_deref()
                .is_some_and(|source| source.starts_with("registry+")),
        };

        shallowest
            .entry(package.name.to_lowercase())
            .and_modify(|held| {
                let preferred = candidate.depth < held.depth
                    || (candidate.depth == held.depth && newer(&candidate.version, &held.version));
                if preferred {
                    *held = candidate.clone();
                }
            })
            .or_insert(candidate);
    }

    if shallowest.is_empty() {
        return Err(ManifestError::Empty);
    }

    let mut entries: Vec<Entry> = shallowest.into_values().collect();
    entries.sort_by(|a, b| a.depth.cmp(&b.depth).then_with(|| a.name.cmp(&b.name)));
    Ok(entries)
}

/// The packages of a lockfile, by name and by name with version. A reference
/// carries the version only when the name alone would be ambiguous, which is
/// what makes two versions of one crate resolvable.
struct Index<'a> {
    by_name_and_version: HashMap<(&'a str, &'a str), usize>,
    by_name: HashMap<&'a str, Vec<usize>>,
}

impl<'a> Index<'a> {
    fn of(packages: &'a [LockPackage]) -> Self {
        let mut by_name_and_version = HashMap::new();
        let mut by_name: HashMap<&str, Vec<usize>> = HashMap::new();

        for (position, package) in packages.iter().enumerate() {
            by_name_and_version.insert((package.name.as_str(), package.version.as_str()), position);
            by_name
                .entry(package.name.as_str())
                .or_default()
                .push(position);
        }

        Self {
            by_name_and_version,
            by_name,
        }
    }

    /// A dependency is written as a name, or a name and a version, or a name, a
    /// version and a source. An unresolvable reference is skipped rather than
    /// invented, since a valid lockfile holds none.
    fn resolve(&self, dependency: &str) -> Option<usize> {
        let mut parts = dependency.split_whitespace();
        let name = parts.next()?;

        match parts.next() {
            Some(version) => self.by_name_and_version.get(&(name, version)).copied(),
            None => match self.by_name.get(name)?.as_slice() {
                [only] => Some(*only),
                _ => None,
            },
        }
    }
}

/// Semantic order where both versions parse, and textual order otherwise, which
/// only decides between two versions reached at the same depth.
fn newer(candidate: &str, held: &str) -> bool {
    match (
        semver::Version::parse(candidate),
        semver::Version::parse(held),
    ) {
        (Ok(candidate), Ok(held)) => candidate > held,
        _ => candidate > held,
    }
}

fn line_of(text: &str, offset: usize) -> usize {
    text.get(..offset)
        .map_or(1, |head| head.lines().count().max(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOCKFILE: &str = r#"
version = 4

[[package]]
name = "my-service"
version = "0.1.0"
dependencies = ["clap", "serde"]

[[package]]
name = "clap"
version = "4.5.49"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aaaa"
dependencies = ["serde"]

[[package]]
name = "serde"
version = "1.0.228"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "bbbb"

[[package]]
name = "local-helper"
version = "0.2.0"
"#;

    #[test]
    fn the_submitting_project_is_not_assessed() {
        let entries = parse_lockfile(LOCKFILE).unwrap();
        assert!(entries.iter().all(|e| e.name != "my-service"));
    }

    #[test]
    fn a_dependency_of_the_project_is_direct() {
        let entries = parse_lockfile(LOCKFILE).unwrap();
        let clap = entries.iter().find(|e| e.name == "clap").unwrap();
        assert_eq!(clap.depth, 0);
        assert!(clap.from_registry);
    }

    #[test]
    fn a_package_reached_twice_keeps_its_shallowest_depth() {
        // serde is both a direct dependency and a dependency of clap
        let entries = parse_lockfile(LOCKFILE).unwrap();
        let serde: Vec<&Entry> = entries.iter().filter(|e| e.name == "serde").collect();
        assert_eq!(serde.len(), 1);
        assert_eq!(serde[0].depth, 0);
    }

    #[test]
    fn a_package_nothing_depends_on_is_a_root_and_not_an_entry() {
        let entries = parse_lockfile(LOCKFILE).unwrap();
        assert!(entries.iter().all(|e| e.name != "local-helper"));
    }

    #[test]
    fn a_git_dependency_is_marked_as_outside_the_registry() {
        let lockfile = r#"
[[package]]
name = "my-service"
version = "0.1.0"
dependencies = ["patched"]

[[package]]
name = "patched"
version = "0.1.0"
source = "git+https://github.com/example/patched?branch=main#abc123"
"#;
        let entries = parse_lockfile(lockfile).unwrap();
        assert_eq!(entries.len(), 1);
        assert!(!entries[0].from_registry);
    }

    #[test]
    fn a_path_dependency_is_marked_as_outside_the_registry() {
        let lockfile = r#"
[[package]]
name = "my-service"
version = "0.1.0"
dependencies = ["local-helper"]

[[package]]
name = "local-helper"
version = "0.1.0"
"#;
        let entries = parse_lockfile(lockfile).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "local-helper");
        assert!(!entries[0].from_registry);
    }

    /// How cargo writes a reference when the name alone would be ambiguous.
    const TWO_VERSIONS: &str = r#"
[[package]]
name = "my-service"
version = "0.1.0"
dependencies = [DIRECT]

[[package]]
name = "old-user"
version = "0.1.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
dependencies = ["syn 1.0.109"]

[[package]]
name = "syn"
version = "1.0.109"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "syn"
version = "2.0.119"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#;

    #[test]
    fn two_versions_of_one_crate_are_reported_once_at_the_shallower_depth() {
        let lockfile = TWO_VERSIONS.replace("DIRECT", r#""old-user", "syn 2.0.119""#);
        let entries = parse_lockfile(&lockfile).unwrap();
        let syn: Vec<&Entry> = entries.iter().filter(|e| e.name == "syn").collect();

        assert_eq!(syn.len(), 1);
        assert_eq!(syn[0].depth, 0);
        assert_eq!(syn[0].version, "2.0.119");
    }

    #[test]
    fn at_equal_depth_the_newer_version_is_the_one_reported() {
        let lockfile = TWO_VERSIONS.replace("DIRECT", r#""syn 1.0.109", "syn 2.0.119""#);
        let entries = parse_lockfile(&lockfile).unwrap();
        let syn: Vec<&Entry> = entries.iter().filter(|e| e.name == "syn").collect();

        assert_eq!(syn.len(), 1);
        assert_eq!(syn[0].version, "2.0.119");
    }

    #[test]
    fn a_version_is_ordered_semantically_and_not_textually() {
        assert!(newer("0.10.0", "0.9.0"));
        assert!(!newer("0.9.0", "0.10.0"));
    }

    #[test]
    fn a_file_that_is_not_toml_reports_where_it_stopped() {
        let error = parse_lockfile("version = 4\n\n[[package\nname = \"x\"\n").unwrap_err();
        match error {
            ManifestError::Unreadable { line, .. } => assert_eq!(line, Some(3)),
            other => panic!("expected an unreadable manifest, got {other:?}"),
        }
    }

    #[test]
    fn a_lockfile_with_only_workspace_members_has_nothing_to_assess() {
        let lockfile = r#"
[[package]]
name = "my-service"
version = "0.1.0"
"#;
        assert!(matches!(
            parse_lockfile(lockfile).unwrap_err(),
            ManifestError::Empty
        ));
    }

    #[test]
    fn an_empty_file_is_refused_rather_than_assessed() {
        assert!(matches!(
            parse_lockfile("").unwrap_err(),
            ManifestError::Empty
        ));
    }

    #[test]
    fn the_committed_lockfile_fixture_parses() {
        let text = include_str!("../tests/fixtures/Cargo.lock");
        let entries = parse_lockfile(text).unwrap();

        // Written by cargo over the packages the seed data holds
        assert!(entries.iter().any(|e| e.name == "serde" && e.depth == 0));
        assert!(
            entries
                .iter()
                .any(|e| e.name == "local-helper" && !e.from_registry)
        );
        assert_eq!(entries.iter().filter(|e| e.name == "syn").count(), 1);
    }
}
