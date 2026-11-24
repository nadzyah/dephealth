# Getting Started

The service requires no account and no key. Withdrawal is the only operation
that is authenticated.

## Prerequisites

A running service, either a deployed one or a local one started from the
repository root:

```bash
docker compose up -d
```

It answers on `http://localhost:8080`, which the examples below assume.
Requests are shown with `curl` and `jq`. A `Cargo.lock` is needed as input, and
one is committed at `api/tests/fixtures/Cargo.lock`.

## Service Readiness

```bash
curl -s http://localhost:8080/health/ready | jq
```

```json
{
  "status": "ready",
  "database": "reachable",
  "sources": [
    { "source": "crates_io_dump", "data_as_of": "2026-11-21", "age_days": 1 },
    { "source": "gh_archive", "data_as_of": "2026-11-21", "age_days": 1 }
  ],
  "sources_never_ingested": []
}
```

A `503` with `"status": "not ready"` indicates that the database is unreachable
or that a source has never been ingested. Nothing can be assessed in that
state, and `/api/v1/assessments` reports the condition rather than returning an
empty report.

## Scoring Method

The constants a score rests on are served from the database rather than
restated in prose, so they cannot drift from the values in use:

```bash
curl -s http://localhost:8080/api/v1/meta | jq '.method'
```

```json
{
  "abandonment_window_days": 180,
  "contributor_disclosure_threshold": 5,
  "abandonment_definition": "A package is treated as abandoned at the end of the first interval of consecutive days containing no development event from any contributor on its repository. Packages still active at the end of the observation window are right censored rather than labelled healthy."
}
```

Two consequences of that definition bear on interpretation. A package that is
complete rather than abandoned scores as being at risk, which in the Rust
ecosystem is a substantial category of small, stable crates. A package
maintained somewhere other than its declared repository appears inactive. Both
are why every entry carries the activity its score was computed from.

## Submitting a Manifest

The lockfile is posted as it is, with no multipart encoding, base64 or wrapper
object:

```bash
curl -s -X POST http://localhost:8080/api/v1/assessments \
  -H 'Content-Type: application/toml' \
  --data-binary @Cargo.lock | jq
```

The response is `201` with the complete report:

```json
{
  "link": "http://localhost:5173/r/9f2c1ab4e6d8705318a0cb4df2e9173c5b6a8de0417fc2938b5e60a7d41c8f23",
  "assessed_on": "2026-11-23",
  "data_as_of": { "registry": "2026-11-21", "events": "2026-11-21" },
  "counts": { "entries": 39, "resolved": 4, "unresolved": 35 },
  "entries": [
    {
      "ordinal": 1,
      "package_name": "failure",
      "package_version": "0.1.8",
      "relation": "indirect",
      "resolved": true,
      "risk": { "probability": 0.971, "horizon_days": 365 },
      "activity": { "distinct_contributors": 0, "days_since_last_event": 1920 }
    }
  ]
}
```

The `link` field is the only copy of the token that is issued. Only its digest
is stored, so the service cannot reissue it and the token space cannot be
enumerated.

Entries are ranked with the scored ones first in descending order of risk,
followed by the unscored. The `ordinal` field records that rank and is stored
with the report, so it is identical on every subsequent read.

## Retrieving a Stored Report

```bash
TOKEN=9f2c1ab4e6d8705318a0cb4df2e9173c5b6a8de0417fc2938b5e60a7d41c8f23
curl -s "http://localhost:8080/api/v1/reports/$TOKEN" | jq '.counts'
```

The figures are those that held when the report was generated. A later
ingestion run does not alter them, which is the purpose of storing a report
rather than recomputing it on demand.

## Evidence for an Entry

```bash
curl -s "http://localhost:8080/api/v1/reports/$TOKEN/entries/failure" | jq '.factors'
```

```json
[
  {
    "code": "days_since_last_event",
    "label": "Days since the last development event",
    "observed_value": 1920,
    "contribution": 2.41,
    "direction": "raised the risk"
  }
]
```

Factors are ordered by the magnitude of their contribution. A positive
contribution raised the risk and a negative one lowered it.

## Error Responses

Every failure is a problem document as specified in RFC 9457. Clients branch on
`type` rather than on the prose of `title` or `detail`:

```bash
curl -s -X POST http://localhost:8080/api/v1/assessments \
  -H 'Content-Type: application/toml' \
  --data-binary 'version = 4
[[package' | jq
```

```json
{
  "type": "/problems/manifest-unreadable",
  "title": "The manifest could not be read",
  "status": 422,
  "detail": "unclosed array table, expected `]]`",
  "line": 2
}
```

The complete set is enumerated in [`openapi.yaml`](../openapi.yaml).
