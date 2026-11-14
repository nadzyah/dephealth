#!/usr/bin/env bash
# One ingestion pass. Download, derive, load, then delete the raw files.
#
#   DATABASE_URL=... analytics/run.sh
#
# Any failure marks both runs failed and leaves the serving database untouched.

set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"

cd "$(dirname "$0")"

RAW_DIR=data/raw
OUT_DIR=data/out
DUCKDB_FILE=data/dephealth.duckdb

command -v duckdb >/dev/null || {
    echo "duckdb is not installed. See analytics/README.md" >&2
    exit 1
}

psql() { command psql "$DATABASE_URL" -v ON_ERROR_STOP=1 "$@"; }

crates_run=$(psql -tAc "SELECT dephealth.start_ingestion_run('crates_io_dump')")
events_run=$(psql -tAc "SELECT dephealth.start_ingestion_run('gh_archive')")
echo "runs: registry $crates_run, events $events_run"

mark_failed() {
    local detail="$1"
    for run in "$crates_run" "$events_run"; do
        psql -q -c "CALL dephealth.finish_ingestion_run($run, 'failed', NULL, 0, 0, NULL, \$\$$detail\$\$);" || true
    done
}
trap 'mark_failed "run aborted at line $LINENO of analytics/run.sh"' ERR

mkdir -p "$RAW_DIR/crates_io" "$RAW_DIR/gh_archive" "$OUT_DIR"

# Download. The event window is bounded by constraint C1, since the whole
# history does not fit a free tier.

WINDOW_DAYS="${WINDOW_DAYS:-30}"

echo "downloading the registry dump"
curl -fsS --retry 3 -o "$RAW_DIR/crates_io/db-dump.tar.gz" \
    https://static.crates.io/db-dump.tar.gz
tar -xzf "$RAW_DIR/crates_io/db-dump.tar.gz" -C "$RAW_DIR/crates_io" \
    --strip-components=2 --wildcards '*/data/*.csv'
rm -f "$RAW_DIR/crates_io/db-dump.tar.gz"

echo "downloading $WINDOW_DAYS days of event archives"
for day_offset in $(seq 1 "$WINDOW_DAYS"); do
    day=$(date -u -d "today - $day_offset day" +%Y-%m-%d)
    for hour in $(seq 0 23); do
        file="$RAW_DIR/gh_archive/${day}-${hour}.json.gz"
        [ -f "$file" ] && continue
        curl -fsS --retry 2 -o "$file" \
            "https://data.gharchive.org/${day}-${hour}.json.gz" \
            || echo "missing: ${day}-${hour}" >&2
    done
done

# Derive

echo "deriving features"
duckdb "$DUCKDB_FILE" <<'EOSQL'
.bail on
.read sql/01_raw.sql
.read sql/02_staging.sql
.read sql/03_mart.sql
.read sql/04_features.sql
.read sql/05_quality.sql
EOSQL

findings=$(duckdb "$DUCKDB_FILE" -noheader -list \
    -c "SELECT count(*) FROM main.quality_finding WHERE severity = 'error'")
if [ "$findings" != "0" ]; then
    duckdb "$DUCKDB_FILE" -c "SELECT * FROM main.quality_finding" >&2
    echo "$findings quality errors, nothing loaded" >&2
    mark_failed "$findings data quality errors in the derived features"
    trap - ERR
    exit 1
fi

duckdb "$DUCKDB_FILE" -c ".read sql/06_export.sql"

# Load

echo "loading into the serving database"
( cd .. && psql -q \
    -v crates_run_id="$crates_run" \
    -v events_run_id="$events_run" \
    -f db/load/load_features.sql )

registry_as_of=$(duckdb "$DUCKDB_FILE" -noheader -list \
    -c "SELECT max(day) FROM mart.fct_download_daily")
events_as_of=$(duckdb "$DUCKDB_FILE" -noheader -list \
    -c "SELECT max(day) FROM mart.fct_activity_daily")
download_days=$(duckdb "$DUCKDB_FILE" -noheader -list \
    -c "SELECT count(*) FROM mart.fct_download_daily")
activity_rows=$(duckdb "$DUCKDB_FILE" -noheader -list \
    -c "SELECT count(*) FROM feature.activity_window")

# Discard the raw data. The bytes are recorded against the run as evidence.

raw_bytes=$(du -sb "$RAW_DIR" | cut -f1)
rm -rf "$RAW_DIR"
echo "discarded $raw_bytes bytes of raw source data"

trap - ERR
psql -q -c "CALL dephealth.finish_ingestion_run($crates_run, 'succeeded', '$registry_as_of', $download_days, 0, NULL);"
psql -q -c "CALL dephealth.finish_ingestion_run($events_run, 'succeeded', '$events_as_of', $activity_rows, 0, $raw_bytes);"

echo "done. registry data as of $registry_as_of, event data as of $events_as_of"
