#!/usr/bin/env bash
# Regenerate db/ddl/schema.sql from the live schema. The migrations are the
# source of truth. Never edited by hand.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL, or run through make}"

out=db/ddl/schema.sql

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
    pg_dump "$DATABASE_URL" \
        --schema-only \
        --schema=dephealth \
        --no-owner \
        --exclude-table='dephealth._sqlx*' \
    | sed '/^-- Dumped from/d; /^-- Dumped by/d'
} > "$out"

echo "wrote $out ($(wc -l < "$out") lines)"
