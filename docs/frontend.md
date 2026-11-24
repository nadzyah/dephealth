# Front-End

The client is a single-page application in `web`. It accepts a dependency
manifest, submits it to the API, and presents the resulting tree ranked by risk
together with the evidence behind each score.
[React](https://www.npmjs.com/package/react) with
[TypeScript](https://www.npmjs.com/package/typescript) in strict mode, built by
[Vite](https://www.npmjs.com/package/vite).

## Architecture

[`frontend-architecture.mmd`](diagrams/frontend-architecture.mmd) shows the
modules, the routes, the global state and the single path to the API.

The application is divided by responsibility rather than by file type:

| Layer | Location | Responsibility |
|---|---|---|
| Entry | `src/main.tsx`, `src/App.tsx` | Router, application shell, error boundary, suspense boundary |
| Routes | `src/pages` | One component per route. Each owns the requests its screen needs |
| Presentation | `src/components` | Reusable elements, grouped by the area that owns them: `ui`, `layout`, `report`, `charts` |
| Logic | `src/hooks`, `src/lib` | Request lifecycle, appearance, manifest parsing, risk ranking, contrast, logging |
| Global state | `src/store` | Appearance, notices and recently opened links |
| Request layer | `src/api` | Base address, timeouts, headers, problem mapping, service types, demo fixtures |

Routing is declarative in `App.tsx`: the submission screen, a report and its
two sub-screens, a package index, the method description, the design system and
a catch-all. Every route except the landing screen is loaded on demand with
`React.lazy`, so opening the submission page does not download the chart code
or the design system with it.

## Architecture Approach

The approach is component-based with a container and presentation split. A page
under `src/pages` is the container: it reads route parameters, calls the
request layer and decides what state the screen is in. Components under
`src/components` receive data as properties and hold no knowledge of the API,
which is what makes them testable without a network and reusable across
screens.

Cross-cutting behaviour lives in hooks rather than in base classes or a higher
order component. `useAsync` is the single request state machine used by every
screen, so loading, failure and emptiness are reported identically everywhere.
It discards a response that arrives after its component has unmounted, and a
response superseded by a newer request, which is what prevents a slow earlier
answer from overwriting a later one.

Micro frontends and a backend-for-frontend were both rejected. The application
is one deployable artefact served as static files, consumed by one audience,
and a federation boundary would add a build and runtime cost with nothing on
the other side of it. The API already returns exactly the shape each screen
needs, so an aggregating layer would only forward requests.

## State Management

Local state is the default. The global store,
[zustand](https://www.npmjs.com/package/zustand) in
`src/store/useAppStore.ts`, holds three things and nothing else: what the
reader has chosen about appearance, the notices any screen may raise, and the
links this browser has opened before.

Report data is deliberately absent from it. State belongs in a store when it
outlives the component that set it or is read somewhere unrelated, and a report
is neither: it is fetched by the screen that displays it and is immutable once
stored by the service, so caching it in a store would add an invalidation
problem in exchange for nothing.

Appearance and recent links are persisted through the `persist` middleware, so
a reader who selects the dark theme and a larger text size finds both on the
next visit. Notices are not persisted, since a notice about a request that has
already finished is noise on a later visit. Components subscribe through
selectors rather than to the whole store, so a notice does not re-render a
screen that never reads one.

## API Interaction

Every request passes through `src/api/client.ts`. No component calls `fetch`.
That single path sets the base address from `VITE_API_BASE_URL`, applies a
twenty second timeout, sets the headers, converts any failure into a typed
`ApiProblem`, and logs the outcome. The schemas of every request and response
are declared in `src/api/types.ts`, mirroring the generated specification.

| Screen | Operation | Endpoint |
|---|---|---|
| Submit | `submitLockfile`, `submitEntries` | `POST /api/v1/assessments` |
| Report | `report` | `GET /api/v1/reports/{token}` |
| Package detail | `reportEntry` | `GET /api/v1/reports/{token}/entries/{name}` |
| Changes | `changes` | `GET /api/v1/reports/{token}/changes` |
| Package index | `packages` | `GET /api/v1/packages` |
| Package | `package`, `downloads` | `GET /api/v1/packages/{name}`, `/downloads` |
| Method, shell | `meta` | `GET /api/v1/meta` |

The documentation of the service the client consumes, including the schemas,
status codes and worked request and response examples, is in
[`docs/api`](api/README.md). The specification there is generated from the
handlers, so the types in this application are checked against the same
contract a reviewer reads.

Setting `VITE_DEMO=true` routes the same functions to the fixtures committed in
`src/api/fixtures`, which were captured from real service responses. The
deployed demonstration and the end to end tests run against those, so the
application is operable with no service and no database behind it.

## Error Handling and Loading States

Failures are handled at three levels.

A render-time exception is caught by `ErrorBoundary`, which replaces the screen
rather than the application and offers a reload.

A failed request becomes an `ApiProblem` carrying the RFC 9457 document the
service returned. Screens branch on its `slug`, never on prose, which keeps the
status code out of the components. The cases are distinguished where the
distinction matters to the reader: `404` states that a token cannot be
recovered, `410` reports a withdrawal and its reason, `422` names the line a
manifest failed on, `503` explains that no ingestion run has completed, and a
network failure or timeout says which address did not answer.

Anything a reader should see but not be blocked by is raised as a notice in the
shell, dismissible and announced to assistive technology. Every asynchronous
screen renders a skeleton while it waits, and an empty result is a stated
outcome rather than a blank area.

A manifest is also checked in the browser before anything is sent, so an
unreadable file is refused locally with the offending line named.

## Logging

`src/lib/logger.ts` is the only writer to the console, with levels controlled
by `VITE_LOG_LEVEL`, so output can be silenced or directed at a collector
without editing components. It never records a report token or the contents of
a manifest. A token is a capability, and a log is somewhere things leak from.

## Responsive Design

The responsive behaviour, the design tokens, the component library and the
accessibility verification are documented separately in
[`adaptive-ui.md`](adaptive-ui.md).

## Technology Choices

**React 19** for the view layer. The screens are dominated by lists and tables
whose content changes in response to one request at a time, which suits a
declarative component model with no need for a framework-level dependency
injection or module system. React also has the deepest testing support of the
three candidates through
[Testing Library](https://www.npmjs.com/package/@testing-library/react), which
matters because the
accessibility claims in this project are asserted in tests rather than
inspected by eye.

**TypeScript** in strict mode, with no implicit `any`. The service returns
discriminated shapes, such as an entry that either carries a score or carries a
reason for not having one, and the compiler enforces that every screen handles
both. The alternative is a runtime check in each component.

**Vite** as the bundler, for native ES module serving in development and
Rollup with per-route chunks in the build. Its environment variable handling
also makes the demonstration build a configuration change rather than a second
code path.

**[React Router](https://www.npmjs.com/package/react-router-dom)** for routing,
configured with `basename` from the build so the same bundle works both at a
domain root and under a subdirectory, which is what the static demonstration
deployment needs.

**zustand** for global state. The store holds preferences and notices, so the
reducer, action and effect apparatus of Redux Toolkit would be overhead; its
advantages appear with complex derived state and asynchronous chains, which
`useAsync` handles locally instead. zustand provides selector subscriptions and
a persistence middleware, which are the two features this application actually
needs.

**No UI kit.** Material, Ant Design and Bootstrap each impose a visual
language and a sizeable bundle, and each would have to be overridden to meet
the contrast and touch target requirements this project verifies. The
components here are written against a token layer instead, which is also what
makes the design system a documented artefact rather than a dependency.

**[Vitest](https://www.npmjs.com/package/vitest) with Testing Library** for
unit and component tests, and
**[Playwright](https://www.npmjs.com/package/@playwright/test)** for end to end
tests across a desktop and a mobile viewport. Vitest shares the Vite
configuration, so tests resolve modules exactly as the application does.

## Testing

| Suite | Command | Covers |
|---|---|---|
| Unit and component | `npm test` | Request layer, manifest parsing, risk ranking, contrast ratios, and the interactive components |
| End to end | `npm run e2e` | The submission workflow and the responsive behaviour, on desktop and on a phone viewport |

The contrast suite computes the ratio of every foreground and background pair in
the token file and asserts the WCAG thresholds, so a palette change that breaks
accessibility fails the build rather than a review.

## Quality Controls

[ESLint](https://www.npmjs.com/package/eslint) with the React Hooks rules,
[Prettier](https://www.npmjs.com/package/prettier), and `tsc -b` run over the
whole project. `npm run lint`, `npm run format:check` and `npm run typecheck`
are the commands.
