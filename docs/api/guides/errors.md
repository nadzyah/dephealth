# Error Taxonomy

Every refusal is a problem document as specified in RFC 9457, served as
`application/problem+json`. A client branches on `type`, which is stable, and
not on `title` or `detail`, which are prose and may be reworded.

## Problem Document

| Member | Content |
|---|---|
| `type` | `/problems/{identifier}`, the stable name of the condition |
| `title` | A short description of the condition, independent of the occurrence |
| `status` | The HTTP status code, repeated in the body so a logged document stands alone |
| `detail` | What happened in this occurrence |

Members beyond those four are extensions, listed below. A document carries only
the extensions its condition defines.

## Conditions

| `type` | Status | Condition | Recovery |
|---|---|---|---|
| `manifest-unreadable` | 422 | The body is not a parsable lockfile, not valid UTF-8, or not a usable entry list | Deterministic. The same body never succeeds. `line` locates the failure where the parser could report it |
| `manifest-empty` | 422 | The file parsed and holds no entry to assess, which a lockfile containing only workspace members does | Submit a manifest with resolved dependencies |
| `manifest-too-large` | 413 | The entry count or the body length exceeds what the deployment accepts | Bounded by configuration, so the limit is raised by the operator rather than worked around by the client |
| `unsupported-media-type` | 415 | The content type is one the endpoint does not accept | Resend with a media type from the `accepted` extension |
| `invalid-query-parameter` | 400 | A query parameter is outside its range, or a withdrawal carries no reason | `detail` names the parameter and its constraint |
| `no-such-endpoint` | 404 | No endpoint answers that path | Consult the reference |
| `method-not-allowed` | 405 | The path exists for another method | Consult the reference |
| `report-not-found` | 404 | The link has never addressed a report on this deployment | None. A token cannot be recovered or reissued, since only its digest is stored |
| `report-withdrawn` | 410 | The report existed and has been withdrawn | None. The condition is reported separately from a link that never existed, because the two differ for an audit |
| `entry-not-found` | 404 | The report holds no entry of that name | The report lists the names it holds |
| `package-not-found` | 404 | No package of that name is in the registry snapshot | A package absent from the snapshot is also unresolved in a report, so the report states which names were not matched |
| `no-previous-report` | 404 | A comparison was requested for the first assessment of its manifest | Expected on a first submission, and distinguishable from an absent report by the identifier |
| `unauthorised` | 401 | A credentialed operation carries no usable bearer token | Present the administrative token |
| `withdrawal-not-configured` | 501 | The deployment has no administrative token configured, so no report can be withdrawn through the API | Operator configuration |
| `not-ready` | 503 | No completed ingestion run or no current model, so an assessment would rest on nothing | Retryable once `/health/ready` reports ready |
| `internal-error` | 500 | An unhandled condition in the service | Retryable. `detail` is deliberately uninformative, and the occurrence is identified by `x-request-id` |

## Extension Members

| `type` | Extensions |
|---|---|
| `manifest-unreadable` | `line`, where the parser could locate the failure |
| `manifest-too-large` | `entries` and `limit`, or `limit_bytes` when the body rather than the entry count was refused |
| `unsupported-media-type` | `received` and `accepted` |
| `report-withdrawn` | `withdrawn_at` and `reason` |
| `entry-not-found`, `package-not-found` | `package` |

## Retry Semantics

A refusal in the 4xx range is deterministic in the request and gains nothing
from a retry, with the exception of `unauthorised`, which depends on the
credential presented. Both 5xx conditions are retryable: `not-ready` resolves
when an ingestion run completes, and `internal-error` may be transient.

A request that exceeds `API_REQUEST_TIMEOUT_SECONDS` is answered with a bare
503 and no problem document, because the layer that produces it sits above the
handlers and has no condition to describe. A client that parses every error
body therefore has to tolerate an empty one.

## Correlation

Each response carries `x-request-id`, taken from the request when it supplies
one and generated otherwise. The service logs that identifier with the problem
identifier, at error level for a server fault and at debug level for a refusal,
so a reported fault can be found without a reproduction. Nothing reaches a
client that has not also reached the log.
