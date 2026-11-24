# Documentation Strategy

How this documentation set is produced, what it conforms to, and where it is
known to fall short.

## Generation Rather Than Authorship

The reference is generated from the request handlers. Each operation's summary,
description, parameters, schemas and status codes are declared as attributes on
the handler that implements it, `make openapi` writes the document, and an
integration test fails when the committed file differs from what the handlers
produce.

The consequence is that `openapi.yaml` is never edited. A correction to the
wording of an endpoint is a change to the handler that serves it, and the two
cannot disagree, which is the failure mode of a specification maintained beside
the code rather than from it. The authored documents, which are the guides and
the diagrams, carry what cannot be derived from the handlers: the reasoning, the
workflows and the boundaries.

## Standards

| Standard | Applied to |
|---|---|
| OpenAPI 3.1 | The reference document |
| RFC 9457 | The structure of every error response |
| ISO 8601 | Every date and instant in a payload |
| Semantic versioning, Keep a Changelog | The change record |
| CommonMark | The authored documents |
| [Mermaid](https://www.npmjs.com/package/mermaid) | The diagram sources |

## Tooling

| Tool | Role |
|---|---|
| [utoipa](https://crates.io/crates/utoipa) | Derives the specification from the handlers |
| [Redocly CLI](https://www.npmjs.com/package/@redocly/cli), at a pinned version | Validates the specification, invoked by `make openapi-lint` and by CI |
| The drift test | Fails when the committed specification is not what the handlers produce |
| [Redoc](https://www.npmjs.com/package/redoc) | Renders the specification, from the repository or served by the service at `/docs/` |
| The demonstration build of the browser application | Answers from committed response captures, which gives a reader a working client with no service behind it |

## Structure

| Path | Contents |
|---|---|
| `docs/api/openapi.yaml` | The generated reference |
| `docs/api/index.html` | The rendering of it |
| `docs/api/guides` | The authored guides, one subject per file |
| `docs/api/examples` | Scripts that run against a live service |
| `docs/api/CHANGELOG.md` | The record of surface changes |
| `docs/diagrams` | Diagram sources, named after the tier and the subject |

Resource and field naming conventions, which belong to the API rather than to
its documentation, are stated once in [the overview](../README.md).

## Formatting

- Prose is wrapped at eighty columns, so that a diff shows the sentence that
  changed rather than the paragraph containing it.
- Headings are noun phrases naming their subject.
- The third person throughout. The documentation describes the system rather
  than addressing a reader.
- Code fences are labelled with their language, and a shell example is runnable
  as shown rather than paraphrased.
- Tables carry enumerations whose columns are the same for every row. Anything
  else is prose.
- A quantity that the implementation can change is not stated in prose, because
  nothing fails when it becomes wrong. Such a figure is either served by the API
  or read from the source that defines it.
- Links are relative, so they resolve both in the repository and in a rendered
  site.

## Gaps and Limitations

| Limitation | Consequence |
|---|---|
| The client's response types are hand-written to mirror the schemas rather than generated from them | A divergence between the client and the specification is caught by review and by the end to end tests, not by a build failure |
| No consumer contract tests | The drift test binds the specification to the handlers, and nothing binds a consumer's expectations to the specification |
| No mock server | The demonstration fixtures serve that purpose for the browser application, and they are captures maintained by hand, so they can age relative to the specification |
| Examples are authored, not generated from the schemas | They are verified by running them, which is a weaker guarantee than generation |
| The documentation is served by the service and rendered from the repository, with no separately published site | A reader without the running service reads the specification as a file or as the rendering committed beside it |
| The statistical models are specified and not yet fitted | Figures appearing in examples are fixture data, which the examples state where it matters |
| English only | No consideration has been given to localisation |
