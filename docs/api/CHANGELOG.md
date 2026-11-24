# Changelog

Notable changes to the API surface, in the form described by
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioned according to
[semantic versioning](https://semver.org/spec/v2.0.0.html). The compatibility
rules that decide which heading a change belongs under are in
[the versioning guide](guides/versioning.md).

Entries describe the contract, not the implementation. A change that leaves
every request and response identical is not recorded here.

## Unreleased

### Added

- Assessment of a submitted dependency manifest, as a `Cargo.lock` or as an
  already resolved entry list, returning the stored report and the link that
  addresses it.
- Retrieval of a stored report, of one entry with the factors behind its score,
  and of the comparison with the previous assessment of the same manifest.
- Withdrawal of a report, authorised by the administrative bearer token.
- The current assessment of a single package and its observed download series.
- The method constants and the age of each source, served from the database that
  holds the scores they describe.
- Liveness and readiness endpoints, the latter reporting database reachability
  and any source never ingested.
- Problem documents conforming to RFC 9457 for every refusal, with stable
  identifiers.
