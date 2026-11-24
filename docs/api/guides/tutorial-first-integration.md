# Assess a Project and File the Evidence

A worked integration, in the order a real one happens. By the end you will have
a script that assesses a repository's lockfile, fails a build when the tree
carries more risk than you accept, files the permanent link as evidence, and
reports what changed since the last time it ran.

Every step is a single request. The whole thing is sixty lines of shell, given
in full at the end and runnable from
[`examples/assess.sh`](../examples/assess.sh).

## Before You Start

You need a service that answers, and nothing else. There is no key to obtain and
no account to create, which [authentication](authentication.md) explains.

```bash
export DEPHEALTH=http://localhost:8080
curl -sf "$DEPHEALTH/health/ready" > /dev/null || echo "not ready"
```

## Step 1, Decide Whether the Data Is Fresh Enough

An assessment is only as good as the last ingestion run. In a pipeline that
gates a release, check the age first and decide deliberately rather than
discovering it later:

```bash
AGE=$(curl -s "$DEPHEALTH/api/v1/meta" | jq '[.sources[].age_days] | max')

if [ "$AGE" -gt 7 ]; then
    echo "the data is $AGE days old, treating the result as advisory"
fi
```

## Step 2, Submit the Lockfile

```bash
REPORT=$(curl -s -X POST "$DEPHEALTH/api/v1/assessments" \
    -H 'Content-Type: application/toml' \
    --data-binary @Cargo.lock)
```

Two things to handle rather than assume.

A lockfile that does not parse answers `422` and names the line. No partial
assessment is produced, because a partial tree would understate the exposure:

```bash
STATUS=$(curl -s -o /tmp/body -w '%{http_code}' -X POST "$DEPHEALTH/api/v1/assessments" \
    -H 'Content-Type: application/toml' --data-binary @Cargo.lock)

if [ "$STATUS" = "422" ]; then
    jq -r '"\(.title): \(.detail) (line \(.line // "unknown"))"' < /tmp/body
    exit 1
fi
```

A manifest larger than the service accepts answers `413`, and one submitted while
no ingestion run has completed answers `503`. Both are worth distinguishing from
a fault in your own pipeline.

## Step 3, Keep the Link

The token exists in exactly one place: the response you just received. Only its
digest is stored, so this is not recoverable.

```bash
LINK=$(jq -r .link <<< "$REPORT")
TOKEN=${LINK##*/}

echo "$LINK" >> assessments.log
```

Treat it as a capability. Whoever holds the link can read the assessment, which
is the point for filing it as evidence and the reason not to put it in a public
build log.

## Step 4, Gate on the Result

The report arrives ranked, so the decision needs no sorting:

```bash
THRESHOLD=0.5

OVER=$(jq --argjson t "$THRESHOLD" \
    '[.entries[] | select(.resolved and .risk.probability >= $t)]' <<< "$REPORT")

COUNT=$(jq 'length' <<< "$OVER")

if [ "$COUNT" -gt 0 ]; then
    jq -r '.[] | "\(.package_name) \(.package_version): \(.risk.probability)"' <<< "$OVER"
fi
```

Decide what to do about the entries that carry no score rather than ignoring
them. They are not "fine": they are unassessed, each with a reason:

```bash
jq -r '.entries[] | select(.resolved == false)
       | "\(.package_name): \(.unresolved.label)"' <<< "$REPORT" | sort | uniq -c
```

`absent_from_snapshot` is usually a package published after the last run and
will resolve itself. `not_a_registry_package` is a path or git dependency, which
has no registry history and never will. `host_unsupported` means the repository
is not on GitHub, so no activity can be derived. The `remedy` field on each
entry says what, if anything, you can do.

## Step 5, Pull the Evidence for What You Are Going to Argue About

A number is not an argument. For each entry over the threshold, fetch what moved
it:

```bash
for NAME in $(jq -r '.[].package_name' <<< "$OVER"); do
    curl -s "$DEPHEALTH/api/v1/reports/$TOKEN/entries/$NAME" | jq -r '
        "## \(.entry.package_name) \(.entry.package_version)",
        "risk \(.entry.risk.probability) over \(.entry.risk.horizon_days) days",
        "contributors \(.entry.activity.distinct_contributors // "withheld"), last event \(.entry.activity.days_since_last_event) days ago",
        (.factors[] | "  \(.label): \(.observed_value) \(.direction)")'
done
```

This is also where you catch the finished-rather-than-abandoned case. An entry
with a high score, zero events for years and a stable download series is a crate
that is done, not one in trouble.

## Step 6, Compare With the Last Run

On the second and later runs, ask what changed. The comparison is matched on a
salted fingerprint of the entry set, so it works without the service having kept
your manifest:

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

A `404` here is not a fault. It means this is the first report for this exact set
of dependencies, which is also true the first time a dependency is added or
removed.

## Step 7, File It

For an audit, what matters is the link and the date, not the figures. A report
is immutable, so the link is enough:

```bash
jq -n --arg link "$LINK" --arg on "$(jq -r .assessed_on <<< "$REPORT")" \
      --argjson counts "$(jq .counts <<< "$REPORT")" \
      '{component: "my-service", assessed_on: $on, evidence: $link, counts: $counts}' \
  >> compliance.jsonl
```

When someone opens that link later they get the assessment as it stood, with the
date and the age of the data behind it. If it has since been withdrawn they get
`410` with the reason, which is deliberately different from the `404` of a link
that never existed: for an audit those two mean different things.

## The Whole Thing

[`examples/assess.sh`](../examples/assess.sh) is the above as one script, with
the error handling in place. It exits non-zero when the tree carries an entry
over the threshold, so it can be a build step as it stands.

```bash
examples/assess.sh Cargo.lock 0.5
```

## What Not to Build On

Two habits will break.

Do not poll a report expecting it to change. It cannot. Submit again to get
current figures, which produces a new report under a new link while the old link
stays valid as the record of the earlier date.

Do not treat the absence of a score as a pass. Count the unresolved entries and
decide about them explicitly, as step 4 does.
