# Testing

The project is tested in five layers, each one placed where the thing it checks
actually lives. The database is tested through the database, the service
through its own router against a real PostgreSQL, and the screens through a
browser. Nothing is asserted in a document that a test could assert instead,
which is why the figures below come from commands rather than from prose.

## The Layers

| Layer | Tool | Tests | What it holds to account |
| --- | --- | --- | --- |
| Database integrity | `psql`, PL/pgSQL | 17 | Immutability of a stored report, the disclosure threshold on every published view, constraint behaviour, role privileges |
| API unit | `cargo test` | 24 | Configuration reading, lockfile parsing, the mapping from a failure to a problem document |
| API integration | `cargo test --test api` | 21 | The whole axum router against a seeded database, including the test that fails when the generated specification is stale |
| Client unit | Vitest | 104 | The logic modules, the request layer, the demonstration backing, and the components whose behaviour is not visual |
| End to end | Playwright | 28 | Routing, the loading, empty and failure states, the adaptive layout, at two viewports |

The end to end suite runs against the demonstration build, which answers from
the captured fixtures, so it needs neither the service nor a database. That is
what lets it run on every pull request in about five seconds.

## Coverage

The service is measured with `cargo llvm-cov` and gated in continuous
integration, where a drop below 80% of lines fails the build.

| Measure | Figure |
| --- | --- |
| Lines | 84.96% |
| Regions | 84.73% |
| Functions | 87.82% |
| Gate | 80% of lines, enforced by `make api-coverage` |

The client is measured with Vitest and the V8 provider. The figure is reported
per directory, because a single number for the whole application would be
misleading:

| Directory | Statements | Lines |
| --- | --- | --- |
| `src/lib` | 94.11% | 96.49% |
| `src/store` | 92.00% | 100.00% |
| `src/api` | 82.79% | 83.72% |
| `src/hooks` | 82.00% | 79.54% |
| Whole application | 45.20% | 47.08% |

The gap between the logic and the whole is deliberate rather than neglected.
The pages and the presentational components are exercised by Playwright, which
drives a real browser and therefore produces no V8 coverage that Vitest can
see. A page asserted in jsdom would duplicate what the end to end suite already
checks in the environment that matters, and would do it against a simulated
layout, which is precisely where a layout defect hides. The split is therefore:
logic is covered by unit tests and is held high, screens are covered end to end
at two viewports, and the one number that gates a build is the service's.

## What Each Layer Catches

The database tests exist because the strongest guarantees in this project are
schema-level. A stored report must not follow the live score, a contributor
count below the threshold must not reach a published view, and a report must
hold as many lines as it declares. Those are enforced by triggers, constraints
and views, so they are tested by trying to break them through SQL rather than
by trusting the application not to try.

The API integration tests run the real router against a database seeded with
the same fixture the demonstration uses. They cover the refusals as carefully
as the successes, since the problem document is part of the contract: an
unreadable manifest answers 422 with the line the parse stopped at, a withdrawn
report answers 410 with the reason, and a link that never existed answers 404.

The client unit tests cover the modules a screen cannot be trusted to exercise
once: the lockfile check that runs before anything is sent, the WCAG contrast
arithmetic, the request state machine and its handling of a slow answer to a
superseded request, the store and what it persists, and the demonstration
backing that the deployed application answers from.

The end to end tests assert the claims that are only true in a browser. The
navigation is reachable at every width, nothing scrolls sideways, a touch
target is at least 44 pixels on a phone, the layout survives doubling the root
font size, and the theme survives a reload.

## What Is Not Covered

Stated plainly, since a gap named is worth more than a figure inflated.

The analytical pipeline has one end to end run over a committed fixture (`make
analytics-test`) and no assertions on individual transformations. The two
models are not implemented in this repository, so nothing here tests them. The
screenshots are captured but not compared, so a visual regression would be seen
by a reader rather than by a test. Accessibility is checked by computation and
by measurement rather than by an automated audit: contrast ratios are computed
from the tokens in `contrast.test.ts`, and target sizes are measured in the
browser, but no axe-style sweep runs over the pages.

## Running Them

```
make test                 # the database integrity tests
make api-test             # the service, unit and integration
make api-coverage         # the service with the coverage gate
make web-test             # the client unit tests
make web-e2e              # the end to end suite, needs local browsers
make web-e2e-container    # the same suite in the Playwright image
```

`make web-e2e-container` exists because the suite needs a browser engine, which
the image already carries. It is the quickest way to run the end to end tests
on a machine that has never downloaded one.

## Continuous Integration

Four jobs run on every pull request and on every push to the default branch.

**Database tier.** Applies every migration, reverts them all and applies them
again, loads the roles and the fixture, runs the integrity tests and the data
quality checks, and finally regenerates the consolidated schema and the data
dictionary to fail if either has drifted from the migrations.

**API tier.** Builds with `SQLX_OFFLINE` first, which proves the committed
query data is current, then formats, lints with warnings as errors, runs the
tests against a live database, measures coverage against the gate and audits
the dependencies against the RustSec advisory database.

**Browser application.** Lints, checks formatting, type-checks, runs the unit
tests, then installs Chromium and runs the end to end suite. A failed run
uploads its Playwright report as an artefact.

**API specification.** Lints the generated OpenAPI document with Redocly.
