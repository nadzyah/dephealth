# Back-end

The serving tier: an HTTP service in Rust over PostgreSQL. It stores submitted
manifests as reports and reads the scores produced by the scheduled analytical
run. No score is computed while a request is in flight, which is the division
that explains most of what follows.

The HTTP contract is documented separately, in [the API documentation](api).

## Architecture

Each layer is a module, and each one is bounded by what it may not reach:

| Module | Responsibility | Excluded |
|---|---|---|
| `http` | Routing, extraction, status codes, serialisation, middleware | No SQL and no domain rule |
| `manifest` | The lockfile: parsing, the dependency walk, depth, deduplication | No input and no output of any kind |
| `db` | Every statement the service runs, and the mapping from rows to transfer objects | No HTTP type |
| `dto` | The shapes that cross the wire | No behaviour |
| `config` | Reading and validating the environment | Nothing else reads the environment |
| `error` | The one mapping from a failure to a response | No knowledge of which handler raised it |

The database is a layer of the design rather than a store behind it. Integrity
is held there, by constraints, by append-only report tables, by views that apply
the disclosure threshold, and by functions that run with definer rights so the
application role can write a report without being able to read the columns the
report is derived from. [The data model](data-model.md) describes that boundary
and [the role documentation](../db/roles/README.md) the privileges it rests on.

The components and the path a request takes through them are drawn in
[`api-architecture.mmd`](diagrams/api-architecture.mmd) and
[`api-request-flow.mmd`](diagrams/api-request-flow.mmd).

## Framework

[axum](https://crates.io/crates/axum), on the
[Tokio](https://crates.io/crates/tokio) runtime. It was chosen for the
[tower-http](https://crates.io/crates/tower-http) middleware ecosystem, which
is where the request identifier, the timeout, the tracing span, the
cross-origin policy and the panic boundary come from, and for extractors that
make the shape of a request part of the handler's signature rather than a
runtime lookup. The specification is derived from those handlers by
[utoipa](https://crates.io/crates/utoipa), so the published contract is a
product of the code that serves it.

## Data Access

The requirement for this criterion names an ORM. This service uses
[`sqlx`](https://crates.io/crates/sqlx), which is a compile-checked query layer
and not an object mapper, and the decision is deliberate.

The authority over the data is the schema. Invariants live in constraints, in
definer-rights functions and in views, because they have to hold for every
client of the database and not only for this process. An object mapper would
restate those entities in application code, leaving two descriptions of one
schema and no mechanism to keep them equal. With `sqlx` the mapping is explicit
in `db.rs`, every query is checked against the live schema when the offline
query data is regenerated, and a renamed column fails the build rather than a
request. The write path is a single function call, since the invariant it
upholds, one transaction over append-only tables with a fingerprint derived
inside the database, belongs to the database.

Two further consequences bear on performance. Nothing is lazily loaded, so
there is no N+1 pattern available to write by accident: each endpoint issues a
fixed number of statements, independent of the size of the tree it returns.
Parameters are bound rather than interpolated, so injection is excluded by
construction rather than by validation.

What the choice gives up is the convenience an ORM provides: no schema
derivation from models, no change tracking, and SQL written by hand. The
queries behind each screen are kept in `db/queries` for that reason, where they
can be read as a set.

## Design Principles

Rust expresses these through traits and generics rather than through interfaces
and containers, so the mapping is to structure rather than to class hierarchies.

| Principle | Where it is visible |
|---|---|
| Single responsibility | The module table above. Every failure is formatted in one place, in `error.rs`, and no handler writes a response body for an error |
| Open to extension | An endpoint is a module and a line in the router, and its documentation follows from its handler. The error type is closed on purpose: adding a condition makes the compiler name every place that has to answer for it, which is what keeps a new condition from defaulting to a 500 |
| Substitution | Every handler returns `Result<T, ApiError>` and composes identically because the error type implements the framework's response trait. Configuration reads through a value source that the process environment and a test map both satisfy |
| Interface segregation | A handler takes the extractors it uses rather than a request object, and a data access function takes the pool and its own parameters rather than the application state |
| Dependency inversion | `manifest` depends on nothing, so the domain rules are testable without a database or a server. `db` hides `sqlx` from the handlers, and `config` depends on an abstraction of its value source rather than on the environment |

## Error Handling

One type enumerates every way a request can fail, and one implementation turns
it into a response. The client sees a problem document conforming to RFC 9457,
with a stable identifier it can branch on. The conditions, their extension
members and the recovery for each are in
[the error taxonomy](api/guides/errors.md).

Nothing internal reaches a client. A database failure becomes a fixed sentence
and an identifier, because its own message describes the schema rather than the
request. Two database conditions are mapped by SQLSTATE to conditions the
caller can act on: a manifest the storage function refuses becomes an
unprocessable entity, and a missing ingestion run becomes a service that is not
ready. A panic in a handler is caught at the edge and answered as an internal
error rather than by closing the connection, and the process keeps serving.

Startup fails rather than the first request: the configuration is read and
validated, and the database is reached, before the listener is bound.

## Logging

The service logs through [`tracing`](https://crates.io/crates/tracing). Every
request opens a span carrying the method, the path and the request identifier,
so each line a request produces is attributable to it. The identifier is taken
from `x-request-id` when the caller supplies one and generated otherwise, and it
is echoed on the response, which is what makes a reported fault locatable
without a reproduction.

Events are structured as fields rather than formatted into messages, and the
output form is selected by `API_LOG_FORMAT`: one JSON object per event where a
collector reads the log, which is what the Compose deployment sets, and the
human form in a terminal. Verbosity is a `tracing` filter in `API_LOG`.

A refusal is logged at debug level and a server fault at error level, both from
the same place the response is built, so nothing reaches a client that has not
also reached the log. Three things are never logged: the report token, the
manifest and the connection string. The configuration type prints a redaction
in place of each secret, which is why its `Debug` implementation is written by
hand rather than derived.

## Security

| Concern | Measure |
|---|---|
| Credentials and secrets | Read from the environment, never committed. `.env` is ignored and `.env.example` carries the shape without values |
| Database privileges | The service connects as a login role that reads published views and writes through one function. The tables behind the views are not readable by it |
| Input | The body length and the entry count are bounded before parsing, the content type decides the parser, every query parameter is range-checked, and every statement binds its parameters |
| Report links | 32 bytes from the operating system generator. Only the digest is stored, so a link cannot be recovered from the database |
| The administrative credential | Minimum length enforced at startup and compared in constant time |
| Transport | No TLS is terminated by the service, which expects a proxy in front of it in any deployment reachable beyond localhost |
| Browser surface | Cross-origin requests restricted to configured origins, and `X-Content-Type-Options: nosniff` on every response |
| Container | The image runs as an unprivileged user, writes no files, and carries no build tooling |

The reasoning behind the anonymous model, and what it deliberately does not
protect, is in [the authentication guide](api/guides/authentication.md).

## Testing

| Suite | Subject |
|---|---|
| Unit tests in `manifest` | The dependency walk: depth, duplicate packages, two versions of one crate, path and git entries, the submitting project, semantic ordering |
| Unit tests in `config` | Every refusal the configuration can raise, and the redaction of each secret |
| Integration tests in `tests/api.rs` | The router against the real schema: submission, storage, retrieval, evidence, comparison, withdrawal, the disclosure threshold, and each refusal as a problem document |
| The drift test | Fails when the committed specification is not what the handlers produce |

The integration tests drive the router directly rather than a listening socket,
so they do not depend on a free port, and they read the same environment as the
service.

`make api-coverage` measures line coverage with
[`cargo-llvm-cov`](https://crates.io/crates/cargo-llvm-cov) and fails
below eighty percent, which is above the minimum this criterion sets. CI runs
it on every pull request, so a change that drops coverage through the gate fails
there. The figure it prints covers the whole crate, including the process entry
points, which no test exercises because they bind a socket.

## Dependencies

`make api-audit` checks the dependency graph against the RustSec advisory
database with [`cargo-audit`](https://crates.io/crates/cargo-audit). Two
advisories are recorded as exceptions in `api/.cargo/audit.toml`, both for
crates that appear in the lockfile as optional database drivers this build does
not enable, which `cargo tree` confirms are absent from the build graph. Each
exception states the condition for removing it. One dependency is flagged as
unmaintained and is reached through the database driver, so replacing it is not
in this service's hands.

## Quality Controls

`make api-check` is formatting and `clippy` with warnings denied. CI runs the
same targets, builds the crate without a database from the committed query data,
runs the tests against a real schema, measures coverage against the gate, audits
the dependencies and validates the specification.

## Deployment

The service is one stage of `docker compose up -d`, which starts the database,
applies the migrations, creates the roles and runs both tiers. The image is
built from the repository with no step performed by hand, and the committed
offline query data is what lets it build without a database.

The image is a multi-stage build whose runtime layer carries the two binaries, a
certificate store and nothing else. It runs as an unprivileged user and declares
a liveness check rather than a readiness check, because a container that cannot
reach the database should not be restarted for it.

The browser application is published separately, by
[`pages.yml`](../.github/workflows/pages.yml), which builds it from the
committed response fixtures and deploys it to GitHub Pages on every push to the
default branch. That deployment is the client alone and carries no service
behind it, which the application states on the screen.

The service itself has no publicly reachable deployment yet. The gap is the
environment rather than the artefacts: the image builds and runs from the
repository as it stands, it needs only the variables in `.env.example`, and a
managed PostgreSQL instance with `sslmode=verify-full` is what the certificate
store in the runtime layer is there for.
