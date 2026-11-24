# Authentication and Authorisation

The API has no accounts. Reading and submitting are anonymous, a generated
report is addressed by an unguessable link, and withdrawal is the only operation
that requires a credential. The specification states this rather than leaving it
to be inferred: the document carries an empty security requirement at the root,
and the one credentialed operation overrides it.

## Anonymous Submission

A dependency manifest discloses the internal composition of a system, which is
why the design avoids holding one. The manifest is parsed and discarded. What
persists is the report and a salted fingerprint of the entry set, and the
fingerprint is what allows a later submission of the same manifest to be
recognised without the manifest having been kept.

An account would add an identity to store beside that data without protecting
anything the discarding does not already protect, and it would deter the
incidental use the service is built for. The absence of accounts is therefore a
design decision rather than an omission, and the consequence is that an
assessment cannot be attributed to a submitter, by the operator or by anyone
reaching the database.

## The Report Link as a Capability

A submission mints 32 bytes from a generator seeded by the operating system,
rendered as 64 hexadecimal characters. The token is returned once, in the `link`
field of the 201 response. Only its digest is stored.

| Property | Consequence |
|---|---|
| The token is returned once and not stored | The service cannot reissue a lost link, and a lost report is unreachable |
| Only the digest is stored | A database dump yields no usable link |
| The token is drawn from a cryptographic generator | Enumeration is not a practical attack at this width |
| Possession is the whole authorisation | Anyone holding the link reads the report, so it belongs wherever a password belongs |

A link placed in an issue tracker, a chat message or a build log is readable by
everyone who can read that record. The link also appears in the path of a
request, so it reaches intermediate proxy logs and browser history. Withdrawal
is the only way to revoke one, and it is irreversible.

## Administrative Withdrawal

Withdrawal is authorised by a bearer token held by the operator and configured
as `API_ADMIN_TOKEN`. The token is rejected at startup if it is shorter than 32
characters, and it is compared in constant time, so a wrong credential cannot be
recovered a character at a time by timing the response.

A credential is required here because a link alone must not be enough to
destroy the evidence it addresses: whoever holds a report link is not
necessarily the party accountable for the record. A deployment that leaves the
token unset has withdrawal disabled, which the API reports as
`withdrawal-not-configured` rather than as a missing endpoint.

Withdrawal preserves the row and the stated reason, so a withdrawn report stays
distinguishable from a link that never existed. The two conditions answer with
different statuses for that reason.

## Transport and Origins

The service terminates no TLS of its own and expects to sit behind a proxy that
does. Over plain HTTP both the report link and the administrative token are
exposed in transit, so a deployment reachable beyond localhost needs that proxy.

Cross-origin requests are restricted to the origins named in
`API_CORS_ORIGINS`, for the methods the API uses and the two request headers it
reads. The browser application is served from a separate origin in development
and may be in a deployment, which is why the allowlist is configured rather than
open.

## Boundaries of the Model

| Absent | Reason |
|---|---|
| Per-client keys and scopes | There is no client identity to attach them to, and introducing one would reintroduce the record the design avoids |
| Rate limiting keyed by caller | Same reason. The cost of a single request is bounded instead, by the body and entry caps and the request timeout |
| An audit trail of reads | A read of a report is not recorded, so the operator cannot tell who opened a link. Recording it would make the identity of readers the thing worth stealing |
| Expiry of a report link | A report is retained until it is withdrawn. Age alone does not withdraw it |
