# Versioning

## Addressing

Resource endpoints are served under `/api/v1`. The liveness and readiness
endpoints are deliberately outside it, because an orchestrator probe should not
have to change path when the resource surface gains a version.

The specification's `info.version` is the version of the serving crate, so a
deployment reports which build produced the document it serves. The path prefix
and that version answer different questions: the prefix identifies the contract,
the version identifies the implementation of it.

## Compatibility Within a Version

A change is compatible, and may appear in `v1` without a new prefix, when a
client that ignores what it does not recognise keeps working:

- A new field in a response, or a new optional query parameter.
- A new problem identifier for a condition that previously fell under a broader
  one, provided its status class is unchanged.
- A new member of an enumerated set, such as a further risk factor code.
- A new endpoint or a new media type on an existing endpoint.

Two obligations follow for a client. Unknown response fields are ignored rather
than rejected, and an unrecognised problem identifier is handled by its status,
which is why the status is repeated in the body.

A change requires a new prefix when it can break a conforming client: removing
or renaming a field, narrowing a type or a range, moving a condition to a
different status, or withdrawing an endpoint. Both prefixes would then be served
for a stated period rather than one replacing the other.

## Change Record

[`CHANGELOG.md`](../CHANGELOG.md) records every change to the surface, in the
Keep a Changelog form, with versions ordered by semantic versioning. The
specification is a version-controlled file generated from the handlers, so each
change is also reviewable as a diff of the contract rather than only as a diff
of the code.

## Deprecation

Nothing is deprecated at present. The intended sequence, when something is,
is a changelog entry naming the replacement, the `Deprecation` and `Sunset`
response headers on the affected operations, a description in the specification
marking the operation deprecated, and removal no earlier than the announced
sunset.

## Current Status

The contract is not yet frozen. Until the first tagged release, `v1` may change
in ways this document reserves for a new prefix, and the changelog is the record
of whether that has happened. A client that needs stability before then should
pin the commit of the specification it generated from.
