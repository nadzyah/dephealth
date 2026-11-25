#!/usr/bin/env bash
# Regenerate docs/data-dictionary.md from a live database.
#
# The dictionary is generated rather than written, so that it cannot drift from
# the schema it describes. The prose in it comes from the COMMENT statements in
# the migrations, which is where a description belongs: it ships with the
# object, and `\d+` in psql shows the same text.
#
#   DATABASE_URL=... docs/generate-data-dictionary.sh
set -euo pipefail
: "${DATABASE_URL:?set DATABASE_URL, or run through make}"
cd "$(dirname "$0")/.."

out=docs/data-dictionary.md

cat docs/data-dictionary.header.md > "$out"
printf '\n' >> "$out"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F '' -P null='' <<'EOSQL' >> "$out"
WITH relations AS (
    SELECT c.oid,
           c.relname,
           c.relkind,
           obj_description(c.oid, 'pg_class') AS purpose
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'dephealth'
       AND c.relkind IN ('r', 'p', 'v', 'm')
       AND NOT c.relispartition
       AND c.relname NOT LIKE '\_sqlx%'
)
SELECT string_agg(section, E'\n' ORDER BY sort_kind, relname)
  FROM (
    SELECT r.relname,
           CASE r.relkind WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'm' THEN 2 ELSE 3 END AS sort_kind,
           concat(
               E'\n### ', r.relname,
               CASE r.relkind
                   WHEN 'v' THEN ' (view)'
                   WHEN 'm' THEN ' (materialised view)'
                   WHEN 'p' THEN ' (partitioned table)'
                   ELSE ''
               END,
               E'\n\n',
               coalesce(r.purpose || E'\n\n', ''),
               E'| Column | Type | Null | Default | Notes |\n',
               E'|---|---|---|---|---|\n',
               (SELECT string_agg(
                          concat('| `', a.attname, '` | ',
                                 format_type(a.atttypid, a.atttypmod), ' | ',
                                 CASE WHEN a.attnotnull THEN 'no' ELSE 'yes' END, ' | ',
                                 coalesce('`' || replace(pg_get_expr(ad.adbin, ad.adrelid), '|', '\|') || '`', ''), ' | ',
                                 coalesce(replace(col_description(r.oid, a.attnum), E'\n', ' '), ''), ' |'),
                          E'\n' ORDER BY a.attnum)
                  FROM pg_attribute a
                  LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
                 WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped),
               E'\n',
               coalesce((SELECT concat(E'\n**Keys and constraints**\n\n',
                                string_agg('- `' || con.conname || '`: ' ||
                                           replace(pg_get_constraintdef(con.oid), '|', '\|'),
                                           E'\n' ORDER BY con.contype, con.conname))
                   FROM pg_constraint con
                  -- From 18 a NOT NULL is a catalog constraint of its own.
                  -- The column table above already states nullability, so
                  -- listing them again says nothing twice per column
                  WHERE con.conrelid = r.oid AND con.contype <> 'n'), ''),
               E'\n',
               coalesce((SELECT concat(E'\n**Indexes**\n\n',
                                string_agg('- ' || replace(pg_get_indexdef(i.indexrelid), '|', '\|'),
                                           E'\n' ORDER BY ic.relname))
                   FROM pg_index i
                   JOIN pg_class ic ON ic.oid = i.indexrelid
                  WHERE i.indrelid = r.oid AND NOT i.indisprimary), ''),
               E'\n'
           ) AS section
      FROM relations r
  ) sections;
EOSQL

{
    printf '\n## Routines\n\n'
    printf '| Routine | Kind | Returns | Purpose |\n|---|---|---|---|\n'
} >> "$out"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F '' <<'EOSQL' >> "$out"
SELECT string_agg(
           concat('| `', p.proname, '(',
                  pg_get_function_arguments(p.oid), ')` | ',
                  CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END, ' | ',
                  CASE p.prokind WHEN 'p' THEN '' ELSE format_type(p.prorettype, NULL) END, ' | ',
                  coalesce(replace(obj_description(p.oid, 'pg_proc'), E'\n', ' '), ''), ' |'),
           E'\n' ORDER BY p.proname)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'dephealth'
   AND p.prokind IN ('f', 'p');
EOSQL

{
    printf '\n## Privileges\n\n'
    printf 'Generated from the live grants. The four group roles are described in `db/roles/README.md`.\n\n'
    printf '| Relation | Role | Privileges |\n|---|---|---|\n'
} >> "$out"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -At -F '' <<'EOSQL' >> "$out"
SELECT string_agg(concat('| `', relname, '` | `', rolname, '` | ', privs, ' |'),
                  E'\n' ORDER BY relname, rolname)
  FROM (
    SELECT c.relname,
           g.rolname,
           string_agg(DISTINCT a.privilege_type, ', ' ORDER BY a.privilege_type) AS privs
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) a
      JOIN pg_roles g ON g.oid = a.grantee
     WHERE n.nspname = 'dephealth'
       AND c.relkind IN ('r', 'p', 'v', 'm')
       AND NOT c.relispartition
       AND g.rolname LIKE 'dephealth\_%'
       AND g.rolname <> 'dephealth_admin'
     GROUP BY c.relname, g.rolname
  ) rows;
EOSQL

printf '\n*Generated by `docs/generate-data-dictionary.sh`. Do not edit.*\n' >> "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
