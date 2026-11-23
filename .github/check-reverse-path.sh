#!/usr/bin/env bash
# Revert every migration, confirm the schema is empty, and apply them again.
#
# docs/data-model.md claims the reverse path leaves no object behind, with one
# stated exception: an enumerated type cannot give up a value, so 0009 leaves
# resolution_status wider than it found it. Relations and routines have to go.
set -euo pipefail
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

for _ in db/migrations/*.up.sql; do
    make revert
done

count() {
    psql "$DATABASE_URL" -At -c "$1"
}

relations=$(count "
    SELECT count(*) FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'dephealth'")

routines=$(count "
    SELECT count(*) FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'dephealth'")

schemas=$(count "SELECT count(*) FROM pg_namespace WHERE nspname = 'dephealth'")

failed=0
for pair in "relations:$relations" "routines:$routines" "schemas:$schemas"; do
    kind=${pair%%:*}
    left=${pair##*:}
    if [[ "$left" != 0 ]]; then
        echo "check-reverse-path: $left $kind survived the revert" >&2
        failed=1
    fi
done

test "$failed" = 0

echo "check-reverse-path: the schema reverted to nothing, reapplying"
make migrate
