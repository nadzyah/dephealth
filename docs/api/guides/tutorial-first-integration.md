# Integration Workflow

A worked integration in the order one occurs: assess a repository's lockfile,
fail a build when the tree carries more risk than is accepted, file the
permanent link as evidence, and report what changed since the previous run.

Every step is a single request. The result is given in full at the end and is
committed as [`examples/assess.sh`](../examples/assess.sh).

## Prerequisites

A service that answers. There is no key to obtain and no account to create.

```bash
export DEPHEALTH=http://localhost:8080
curl -sf "$DEPHEALTH/health/ready" > /dev/null || echo "not ready"
```

## Data Freshness

An assessment is only as current as the last ingestion run. A pipeline that
gates a release establishes the age of the data first rather than discovering it
afterwards:

```bash
AGE=$(curl -s "$DEPHEALTH/api/v1/meta" | jq '[.sources[].age_days] | max')

if [ "$AGE" -gt 7 ]; then
    echo "the data is $AGE days old, treating the result as advisory"
fi
```

## Submitting the Lockfile

```bash
REPORT=$(curl -s -X POST "$DEPHEALTH/api/v1/assessments" \
    -H 'Content-Type: application/toml' \
    --data-binary @Cargo.lock)
```

Two outcomes require handling. A lockfile that does not parse answers `422` and
names the line. No partial assessment is produced, since a partial tree would
understate the exposure:

```bash
STATUS=$(curl -s -o /tmp/body -w '%{http_code}' -X POST "$DEPHEALTH/api/v1/assessments" \
    -H 'Content-Type: application/toml' --data-binary @Cargo.lock)

if [ "$STATUS" = "422" ]; then
    jq -r '"\(.title): \(.detail) (line \(.line // "unknown"))"' < /tmp/body
    exit 1
fi
```

A manifest larger than the service accepts answers `413`, and one submitted
before any ingestion run has completed answers `503`. Both are distinguishable
from a fault in the calling pipeline.

## Retaining the Link

The token exists only in the response just received. Only its digest is stored,
so it is not recoverable:

```bash
LINK=$(jq -r .link <<< "$REPORT")
TOKEN=${LINK##*/}

echo "$LINK" >> assessments.log
```

The link is a capability. Whoever holds it can read the assessment, which is
what makes it usable as filed evidence and the reason it does not belong in a
public build log. [Authentication](authentication.md) states what follows from
that for storage and revocation.

## Applying a Threshold

The report arrives ranked, so the decision requires no sorting:

```bash
THRESHOLD=0.5

OVER=$(jq --argjson t "$THRESHOLD" \
    '[.entries[] | select(.resolved and .risk.probability >= $t)]' <<< "$REPORT")

COUNT=$(jq 'length' <<< "$OVER")

if [ "$COUNT" -gt 0 ]; then
    jq -r '.[] | "\(.package_name) \(.package_version): \(.risk.probability)"' <<< "$OVER"
fi
```

An entry carrying no score is unassessed rather than acceptable, and each one
states a reason:

```bash
jq -r '.entries[] | select(.resolved == false)
       | "\(.package_name): \(.unresolved.label)"' <<< "$REPORT" | sort | uniq -c
```

`absent_from_snapshot` generally indicates a package published after the last
run, which resolves itself. `not_a_registry_package` is a path or git
dependency, which has no registry history and will not acquire one.
`host_unsupported` means the repository is not on GitHub, so no activity can be
derived. The `remedy` field on each entry states what action, if any, is
available.

## Retrieving Evidence

A score alone does not support an argument. For each entry over the threshold,
the factors behind it are retrieved individually:

```bash
for NAME in $(jq -r '.[].package_name' <<< "$OVER"); do
    curl -s "$DEPHEALTH/api/v1/reports/$TOKEN/entries/$NAME" | jq -r '
        "## \(.entry.package_name) \(.entry.package_version)",
        "risk \(.entry.risk.probability) over \(.entry.risk.horizon_days) days",
        "contributors \(.entry.activity.distinct_contributors // "withheld"), last event \(.entry.activity.days_since_last_event) days ago",
        (.factors[] | "  \(.label): \(.observed_value) \(.direction)")'
done
```

This is also where a complete package is distinguished from an abandoned one.
An entry with a high score, no events for several years and a stable download
series is finished rather than in difficulty.

## Comparison With the Previous Run

On the second and subsequent runs the service reports what changed. The
comparison is matched on a salted fingerprint of the entry set, so it functions
without the service having retained the manifest:

```bash
CHANGES=$(curl -s -o /tmp/changes -w '%{http_code}' \
    "$DEPHEALTH/api/v1/reports/$TOKEN/changes")

if [ "$CHANGES" = "404" ]; then
    echo "first assessment of this dependency set"
else
    jq -r '.packages[] | select(.verdict == "risk has risen")
           | "\(.package_name) \(.risk_then) -> \(.risk_now)"' < /tmp/changes
fi
```

A `404` is not a fault here. It indicates the first report for this exact set of
dependencies, which is also the case the first time a dependency is added or
removed.

## Recording the Result

For an audit the link and the date are what matter rather than the figures. A
report is immutable, so the link is sufficient:

```bash
jq -n --arg link "$LINK" --arg on "$(jq -r .assessed_on <<< "$REPORT")" \
      --argjson counts "$(jq .counts <<< "$REPORT")" \
      '{component: "my-service", assessed_on: $on, evidence: $link, counts: $counts}' \
  >> compliance.jsonl
```

Opening that link later yields the assessment as it stood, with the date and the
age of the data behind it. A withdrawn report answers `410` with the reason,
which is deliberately distinct from the `404` of a link that never existed,
because for an audit the two differ in meaning.

## The Complete Script

[`examples/assess.sh`](../examples/assess.sh) implements the above with the
error handling in place. It exits non-zero when an entry exceeds the threshold,
so it serves as a build step unmodified.

```bash
examples/assess.sh Cargo.lock 0.5
```

## Constraints

A report cannot change, so polling one is pointless. Submitting the manifest
again produces a new report under a new link, while the earlier link remains
valid as the record of that date.

The absence of a score is not a pass. Unresolved entries are counted and
decided on explicitly, as above.
