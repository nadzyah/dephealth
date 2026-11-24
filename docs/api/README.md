# API Documentation

[`openapi.yaml`](openapi.yaml) specifies every endpoint, request and response.
It is generated from the request handlers by `make openapi`, and a test fails
when the committed file differs from what the handlers produce, so the
specification cannot drift from the implementation. [`index.html`](index.html)
renders it, and the running service serves both at `/docs/`.

## Guides

| Guide | Subject |
|---|---|
| [Getting started](guides/getting-started.md) | Submitting a manifest and reading the ranked result |
| [Integration workflow](guides/tutorial-first-integration.md) | The complete workflow, as a script |
| [Request lifecycle](guides/request-lifecycle.md) | Middleware, pagination, idempotency, limits and freshness |
| [Error taxonomy](guides/errors.md) | The problem document, every condition, and its recovery |
| [Authentication](guides/authentication.md) | The anonymous capability model and the one credentialed operation |
| [Versioning](guides/versioning.md) | What may change within a version, and what may not |
| [Documentation strategy](guides/strategy.md) | How this set is produced, validated and bounded |

[`examples/assess.sh`](examples/assess.sh) performs that workflow against a
local or a deployed service. [`CHANGELOG.md`](CHANGELOG.md) records every change
to the surface. The components behind the endpoints are drawn in
[`api-architecture.mmd`](../diagrams/api-architecture.mmd), and the path of a
request through them in
[`api-request-flow.mmd`](../diagrams/api-request-flow.mmd).

## Conventions

- Paths are plural nouns and operations are HTTP methods. No path contains a
  verb.
- Field names are `snake_case` and match the columns behind them, so a value
  can be traced from a screen to a column without a translation table.
- Dates follow ISO 8601. A calendar day is `YYYY-MM-DD` and an instant carries
  a time and an offset.
- A probability is a number between 0 and 1, never a percentage.
- Errors are `application/problem+json`, as specified in RFC 9457.

## Regenerating the Specification

```
make openapi       # from the handlers
make openapi-lint  # validate with Redocly
```
