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
| [First integration](guides/tutorial-first-integration.md) | The complete workflow, as a script |

[`examples/assess.sh`](examples/assess.sh) performs that workflow against a
local or a deployed service. The components behind the endpoints are drawn in
[`api-architecture.mmd`](../diagrams/api-architecture.mmd).

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
