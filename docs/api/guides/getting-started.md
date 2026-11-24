# Getting Started

A first request, and then the one that matters. Nothing here needs an account or
a key.

## What You Need

- A running service. Either the deployed one, or a local one from the repository
  root:

  ```bash
  make db-up migrate roles seed
  make api
  ```

  The service answers on `http://localhost:8080`. The examples below use that;
  substitute your own host for a deployed instance.

- `curl` and, for reading JSON comfortably, `jq`.
- A `Cargo.lock` from a Rust project. The repository has one you can use at
  `api/tests/fixtures/Cargo.lock`.

## Is It Up

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

`503` with `"status": "not ready"` means either the database is unreachable or a
source has never been ingested. Nothing can be assessed in that state, and
`/api/v1/assessments` will say so rather than return an empty report.

## What a Score Means

Before using the figures, read what they rest on. One request answers it, and
the constants come from the database rather than from a document that could
drift:

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

Two consequences follow from that definition and are worth knowing before you
act on a score. A package that is *finished* rather than abandoned scores as
being at risk, which in the Rust ecosystem is a real category of small, stable
crates. And a package maintained somewhere other than its declared repository
looks inactive. Both are why every entry carries the activity the score was
computed from.

## Assess a Manifest

Post the lockfile as it is. No multipart, no base64, no wrapper object:

```bash
curl -s -X POST http://localhost:8080/api/v1/assessments \
  -H 'Content-Type: application/toml' \
  --data-binary @Cargo.lock | jq
```

The answer is `201` with the whole report, and a `link` field that is the only
copy of your token you will ever be given:

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

**Keep the link.** Only its digest is stored, so the service cannot give it back
to you and nobody can enumerate it.

The entries are ranked: the ones with a score first, by descending risk, then the
ones without. `ordinal` is that rank and is stored with the report, so it is the
same on every later read.

## Read It Again Later

```bash
TOKEN=9f2c1ab4e6d8705318a0cb4df2e9173c5b6a8de0417fc2938b5e60a7d41c8f23
curl -s "http://localhost:8080/api/v1/reports/$TOKEN" | jq '.counts'
```

The figures are the ones that stood when the report was generated. A later
ingestion run does not change them, which is the point of storing a report
rather than recomputing it.

## The Evidence Behind One Entry

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

Ordered by the size of the contribution. A positive contribution raised the risk
and a negative one lowered it.

## When Something Is Wrong

Every failure is a problem document. Branch on `type`, not on the prose:

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

[Errors](errors.md) lists every one of them.

## Next

[Assess a project and file the evidence](tutorial-first-integration.md) does the
whole workflow in one script: submit, rank, pull the evidence for the worst
entries, store the link, and compare a later run with it.
