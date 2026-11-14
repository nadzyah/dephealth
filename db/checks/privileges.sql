-- Privilege audit. New objects are granted in the migration that creates them,
-- so this is how a forgotten grant is found.

-- mv_package_current_assessment is expected in this result. It is internal,
-- and the views over it are what the other roles are granted
\echo '-- relations no role but the administrator can reach'
SELECT c.relkind AS kind,
       c.relname AS relation
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'dephealth'
   AND c.relkind IN ('r', 'p', 'v', 'm')
   AND c.relispartition = false
   AND NOT EXISTS (
        SELECT 1
          FROM aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname IN ('dephealth_ingest', 'dephealth_app', 'dephealth_public_read')
   )
 ORDER BY c.relkind, c.relname;

\echo '-- what each role can actually do, table by table'
SELECT c.relname AS relation,
       g.rolname AS role,
       string_agg(DISTINCT a.privilege_type, ', ' ORDER BY a.privilege_type) AS privileges
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
  JOIN pg_roles g ON g.oid = a.grantee
 WHERE n.nspname = 'dephealth'
   AND c.relkind IN ('r', 'p', 'v', 'm')
   AND c.relispartition = false
   AND g.rolname LIKE 'dephealth\_%'
 GROUP BY c.relname, g.rolname
 ORDER BY c.relname, g.rolname;

\echo '-- any login role that is a superuser, or that can create roles or databases'
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb
  FROM pg_roles
 WHERE rolcanlogin
   AND (rolsuper OR rolcreaterole OR rolcreatedb)
 ORDER BY rolname;

\echo '-- any password still stored with a digest that is no longer acceptable'
SELECT rolname,
       CASE
           WHEN rolpassword IS NULL              THEN 'no password set'
           WHEN rolpassword LIKE 'SCRAM-SHA-256$%' THEN 'scram-sha-256'
           WHEN rolpassword LIKE 'md5%'          THEN 'md5, must be reset'
           ELSE 'unrecognised'
       END AS password_digest
  FROM pg_authid
 WHERE rolcanlogin
 ORDER BY rolname;
