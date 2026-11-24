#!/usr/bin/env bash
#
# Assess a lockfile, gate on the result, file the link, and report what changed
# since the last assessment of the same dependency set.
#
#   examples/assess.sh Cargo.lock 0.5
#
# Exits 1 when an entry carries a risk at or above the threshold, so this works
# as a build step as it stands. Needs curl and jq, and DEPHEALTH pointing at a
# service.
set -euo pipefail

MANIFEST=${1:?usage: assess.sh <Cargo.lock> [threshold]}
THRESHOLD=${2:-0.5}
DEPHEALTH=${DEPHEALTH:-http://localhost:8080}

body=$(mktemp)
trap 'rm -f "$body"' EXIT

# Is there anything to assess with
if ! curl -sf "$DEPHEALTH/health/ready" > /dev/null; then
    echo "assess: $DEPHEALTH is not ready" >&2
    exit 2
fi

age=$(curl -s "$DEPHEALTH/api/v1/meta" | jq '[.sources[].age_days] | max')
if [ "$age" -gt 7 ]; then
    echo "assess: the data is $age days old, the result is advisory" >&2
fi

# Submit
status=$(curl -s -o "$body" -w '%{http_code}' -X POST "$DEPHEALTH/api/v1/assessments" \
    -H 'Content-Type: application/toml' \
    --data-binary "@$MANIFEST")

if [ "$status" != "201" ]; then
    jq -r '"assess: \(.title). \(.detail)" + (if .line then " Line \(.line)." else "" end)' \
        < "$body" >&2
    exit 2
fi

report=$(cat "$body")
link=$(jq -r .link <<< "$report")
token=${link##*/}

# The token is in this response and nowhere else
echo "$link" >> assessments.log

echo "assessed $(jq -r '.counts.entries' <<< "$report") entries, \
$(jq -r '.counts.resolved' <<< "$report") scored, \
on data of $(jq -r '.data_as_of.registry' <<< "$report")"

# What carries no score, and why
jq -r '.entries[] | select(.resolved == false) | .unresolved.label' <<< "$report" \
    | sort | uniq -c | sed 's/^/  unassessed: /'

# What is over the threshold
over=$(jq --argjson t "$THRESHOLD" \
    '[.entries[] | select(.resolved and .risk.probability >= $t)]' <<< "$report")

# What changed since the last assessment of the same set
if curl -sf "$DEPHEALTH/api/v1/reports/$token/changes" -o "$body"; then
    jq -r '.packages[] | select(.verdict == "risk has risen")
           | "  risen: \(.package_name) \(.risk_then) -> \(.risk_now)"' < "$body"
else
    echo "  first assessment of this dependency set"
fi

if [ "$(jq 'length' <<< "$over")" -eq 0 ]; then
    echo "nothing at or above $THRESHOLD"
    exit 0
fi

# The evidence for what is about to be argued about
for name in $(jq -r '.[].package_name' <<< "$over"); do
    curl -s "$DEPHEALTH/api/v1/reports/$token/entries/$name" | jq -r '
        "",
        "\(.entry.package_name) \(.entry.package_version), risk \(.entry.risk.probability) over \(.entry.risk.horizon_days) days",
        "  contributors: \(.entry.activity.distinct_contributors // "withheld"), last event \(.entry.activity.days_since_last_event // "never") days ago",
        (.factors[] | "  \(.label): \(.observed_value), \(.direction)")'
done

echo
echo "evidence: $link"
exit 1
