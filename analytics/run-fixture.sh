#!/usr/bin/env bash
# Run the pipeline over the committed fixture instead of the real sources, and
# load the result into the serving database. Downloads nothing.
#
#   DATABASE_URL=... analytics/run-fixture.sh
#
# The fixture is small enough to read and covers every branch the pipeline has:
# all four resolution outcomes, a bot account, a duplicated event id, a silent
# package and a package with several contributors.

set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"

cd "$(dirname "$0")"

command -v duckdb >/dev/null || {
    echo "duckdb is not installed, see docs/analytics.md" >&2
    exit 1
}

rm -rf data
mkdir -p data/raw data/out
cp -r testdata/crates_io testdata/gh_archive data/raw/

crates_run=$(psql "$DATABASE_URL" -tAc "SELECT dephealth.start_ingestion_run('crates_io_dump')")
events_run=$(psql "$DATABASE_URL" -tAc "SELECT dephealth.start_ingestion_run('gh_archive')")

duckdb data/dephealth.duckdb <<'EOSQL'
.bail on
.read sql/01_raw.sql
.read sql/02_staging.sql
.read sql/03_mart.sql
.read sql/04_features.sql
.read sql/05_quality.sql
.read sql/06_export.sql
EOSQL

errors=$(duckdb data/dephealth.duckdb -noheader -list \
    -c "SELECT count(*) FROM main.quality_finding WHERE severity = 'error'")
duckdb data/dephealth.duckdb -c "SELECT * FROM main.quality_finding"

if [ "$errors" != "0" ]; then
    echo "$errors quality errors in the fixture run" >&2
    exit 1
fi

( cd .. && OUT_DIR=analytics/data/out psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
    -v crates_run_id="$crates_run" \
    -v events_run_id="$events_run" \
    -f db/load/load_features.sql )

as_of=$(duckdb data/dephealth.duckdb -noheader -list \
    -c "SELECT max(day) FROM mart.fct_download_daily")
events_as_of=$(duckdb data/dephealth.duckdb -noheader -list \
    -c "SELECT max(day) FROM mart.fct_activity_daily")
raw_bytes=$(du -sb data/raw | cut -f1)
rm -rf data/raw

psql "$DATABASE_URL" -q -c "CALL dephealth.finish_ingestion_run($crates_run, 'succeeded', '$as_of', 146, 0, NULL);"
psql "$DATABASE_URL" -q -c "CALL dephealth.finish_ingestion_run($events_run, 'succeeded', '$events_as_of', 8, 0, $raw_bytes);"

echo "fixture loaded, registry as of $as_of, events as of $events_as_of"
