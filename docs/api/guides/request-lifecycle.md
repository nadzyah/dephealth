# Request Lifecycle

What every request passes through, and the four protocol behaviours a client has
to account for: pagination, repetition, limits and freshness. The sequence of a
submission and of a subsequent read is drawn in
[`api-request-flow.mmd`](../../diagrams/api-request-flow.mmd), and the
components it passes through in
[`api-architecture.mmd`](../../diagrams/api-architecture.mmd).

## Middleware

Each request traverses the same layers before a handler sees it:

| Layer | Effect |
|---|---|
| Request identifier | `x-request-id` is taken from the request or generated, and echoed on the response |
| Tracing | A span per request, carrying the identifier into every log line the request produces |
| Timeout | A request exceeding the configured duration is abandoned and answered 503 |
| Cross-origin policy | Requests from origins outside the allowlist are refused by the browser that made them |
| `X-Content-Type-Options` | Set to `nosniff` on every response |

The framework's global body limit is disabled on purpose. The assessment handler
reads and bounds the body itself, so an oversized manifest is refused as a
problem document like every other refusal rather than as a bare status.

## Submission and Storage

A submission is read, parsed, bounded and stored in one call to a database
function that runs with definer rights, so the report, its entries and the
fingerprint of the entry set are committed together or not at all. No score is
computed while the request is in flight: the stored results of the scheduled
analytical run are read, which is why a report states the date of the data
behind it and why an absent run is reported as `not-ready` rather than as an
empty report.

## Pagination

The package listing is paginated by `limit` and `offset`, and the response
repeats both, so a page is interpretable without the request that produced it.
Ordering is by descending risk, which puts the entries worth reading on the
first page.

Two limitations follow from offset pagination and are not worked around. No
total count is returned, because counting the matching set is a second scan of
it. The ordering is stable within an ingestion run but not across one, so a
client paging slowly enough to span a run can see an entry twice or not at all.
A cursor keyed on the score and the name would fix both and is not implemented.

Nothing else is paginated. A report is returned whole, because its entries are
the unit of evidence and a partial tree understates exposure, and a download
series is bounded by the `from` and `to` parameters instead.

## Repetition and Idempotency

Every read is idempotent. Withdrawal is idempotent in effect: a second
withdrawal of the same report changes nothing and is reported as already
withdrawn.

Submission is not idempotent, and deliberately so. Each submission mints a new
report with its own link and its own date, because a report is dated evidence
and two assessments of the same manifest a month apart are two findings rather
than one. The service recognises the repetition through the salted fingerprint
and exposes it as the comparison with the previous assessment, instead of
collapsing the second submission into the first.

There is consequently no `Idempotency-Key` handling. A client that retries a
submission after a timeout and cannot tell whether the first attempt was stored
will hold two reports, and the comparison endpoint will report no difference
between them.

## Limits and Capacity

Four bounds are configured per deployment: the body length and the entry count
accepted by the assessment endpoint, the request timeout, and the size of the
database connection pool, which bounds how many requests are served
concurrently. The defaults are declared in `api/src/config.rs`.

The first two are stated in the refusal rather than in this document, since the
limit in force belongs to the deployment: a refused submission carries the
limit it exceeded as an extension member of the problem document.

No rate limiting is applied at the application tier. The caps above bound the
cost of a single request and the pool bounds concurrency, but nothing bounds the
rate from one caller. The API has no client identity to key a quota on, by the
design described in [authentication](authentication.md), so the limit belongs at
the reverse proxy, keyed by address.

## Freshness

No response carries an `ETag` or a `Cache-Control` directive, and none may be
cached by an intermediary on that basis. A stored report is immutable until it
is withdrawn and is the obvious candidate for a strong validator, which is not
yet implemented.

Every response that rests on ingested data states the date of that data, as
`data_as_of` on a report and through the method endpoint for the service as a
whole. A client that needs to know whether a score is current compares those
dates rather than the age of its own copy.
