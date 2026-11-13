-- The three login roles. Not a migration, since each carries a password.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--        -v ingest_password="$INGEST_PASSWORD" \
--        -v app_password="$APP_PASSWORD" \
--        -v public_read_password="$PUBLIC_READ_PASSWORD" \
--        -f db/roles/create_login_roles.sql

\set ON_ERROR_STOP on

-- Fail rather than store an md5 digest.
DO $$
BEGIN
    IF current_setting('password_encryption') <> 'scram-sha-256' THEN
        RAISE EXCEPTION
            'password_encryption is %, refusing to create login roles',
            current_setting('password_encryption')
            USING HINT = 'start the server with -c password_encryption=scram-sha-256';
    END IF;
END;
$$;

-- Idempotent, because a role is a cluster object and survives a schema revert.
-- The statement is built by format and run by \gexec, since psql does not
-- interpolate a variable inside a dollar quoted block. Connection limits stop
-- one component exhausting a free tier pool.
SELECT format(
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name)
         THEN 'ALTER ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s'
         ELSE 'CREATE ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s'
    END, role_name, role_password, connection_limit)
  FROM (VALUES
    ('dephealth_ingest_login',      :'ingest_password',      4),
    ('dephealth_app_login',         :'app_password',        20),
    ('dephealth_public_read_login', :'public_read_password', 10)
  ) AS r(role_name, role_password, connection_limit)
\gexec

SELECT format('GRANT %I TO %I', group_role, login_role)
  FROM (VALUES
    ('dephealth_ingest',      'dephealth_ingest_login'),
    ('dephealth_app',         'dephealth_app_login'),
    ('dephealth_public_read', 'dephealth_public_read_login')
  ) AS r(group_role, login_role)
\gexec

COMMENT ON ROLE dephealth_ingest_login IS 'The scheduled ingestion job.';
COMMENT ON ROLE dephealth_app_login IS 'The web application.';
COMMENT ON ROLE dephealth_public_read_login IS 'The public read-only API.';

SELECT rolname,
       rolcanlogin,
       rolsuper,
       rolconnlimit
  FROM pg_roles
 WHERE rolname LIKE 'dephealth%'
 ORDER BY rolcanlogin DESC, rolname;
