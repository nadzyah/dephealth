-- 0008 down
--
-- Privileges disappear with the objects, so the down migration only has to
-- give up ownership of the roles and remove them. DROP OWNED removes the
-- default privileges the roles were granted, which DROP ROLE would otherwise
-- refuse to leave behind.
DO $$
DECLARE
    role_name text;
BEGIN
    FOREACH role_name IN ARRAY ARRAY[
        'dephealth_public_read', 'dephealth_app', 'dephealth_ingest', 'dephealth_admin'
    ] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP OWNED BY %I', role_name);
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END;
$$;
