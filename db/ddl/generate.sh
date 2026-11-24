#!/usr/bin/env bash
# Regenerate db/ddl/schema.sql from the live schema. The migrations are the
# source of truth. Never edited by hand.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL, or run through make}"

out=db/ddl/schema.sql

# pg_dump formats its output differently from one major version to the next, so
# a committed file would change with whatever client happened to be installed.
# Take the one matching the server, which on Debian and Ubuntu is a versioned
# path, because /usr/bin/pg_dump is a wrapper that picks the newest instead.
server_major=$(psql "$DATABASE_URL" -At \
    -c "SELECT current_setting('server_version_num')::int / 10000")

pgdump=(${PGDUMP:-pg_dump})
if [[ -z ${PGDUMP:-} && -x /usr/lib/postgresql/$server_major/bin/pg_dump ]]; then
    pgdump=(/usr/lib/postgresql/$server_major/bin/pg_dump)
fi

client_major=$("${pgdump[@]}" --version | sed -E 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/')

# No client of the server's major installed. The image the server itself runs
# from carries one, so take it from there rather than requiring the tools to be
# installed on every machine that regenerates this file
if ((client_major < server_major)) && [[ -z ${PGDUMP:-} ]] && command -v docker > /dev/null; then
    pgdump=(docker run --rm --network host -i "postgres:$server_major-alpine" pg_dump)
    client_major=$("${pgdump[@]}" --version | sed -E 's/.* ([0-9]+)(\.[0-9]+)?.*/\1/')
fi

if ((client_major < server_major)); then
    echo "$0: pg_dump $client_major cannot dump a server of $server_major" >&2
    exit 1
fi


{
    cat <<'HDR'
--
-- Consolidated DDL for the dephealth application schema.
--
-- GENERATED FILE. Do not edit. Regenerate with `make ddl` after a migration.
-- The source of truth is db/migrations, applied in order; this file is the
-- same structure in one piece, for reading and for creating the schema in an
-- environment where the migration tool is not available.
--
-- The group roles the GRANT statements below refer to are created by
-- db/migrations/0008_roles_and_grants.up.sql, because a role is a cluster
-- object rather than part of a schema. Create them before applying this file.
--
HDR
    # 17.6 and later wrap the dump in a \restrict directive carrying a random
    # token, so the file would differ on every run. It guards psql against a
    # dump that smuggles meta-commands, which a generated file reviewed in this
    # repository does not need. Each directive is followed by a blank line, and
    # both go, so the result matches what an earlier client writes.
    "${pgdump[@]}" "$DATABASE_URL" \
        --schema-only \
        --schema=dephealth \
        --no-owner \
        --exclude-table='dephealth._sqlx*' \
    | sed '/^-- Dumped from/d; /^-- Dumped by/d
           /^\\restrict /,+1d; /^\\unrestrict /,+1d'
} > "$out"

echo "wrote $out ($(wc -l < "$out") lines), pg_dump $client_major"
