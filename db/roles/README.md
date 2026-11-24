# Roles and Privileges

The group roles are created in
`db/migrations/0008_roles_and_grants.up.sql`. None of them may log in, and all
privileges within the schema are held by them.

`dephealth_admin` is used by the migrations and for maintenance. It holds all
privileges within the schema and is not a superuser.

`dephealth_ingest` is used by the scheduled pipeline. It reads the reference
tables and inserts and updates the derived data. It holds no `DELETE` on any
relation, since a bad run is corrected by loading over it or by dropping a
partition.

`dephealth_app` is used by the web application. It resolves a manifest against
`package` and its dependency edges, reads the derived data through views,
inserts reports, and updates the two withdrawal columns of `report`.

`dephealth_public_read` is used by the public read-only API. It holds `SELECT`
on the public views, no privilege on any base table, and no write privilege
anywhere.

In the conventional naming, `dephealth_admin` is the administrator and
`dephealth_public_read` is the read-only application role. The write side is
split in two rather than held by a single role, because the pipeline and the
web application write different tables and only one of them has any reason to
read the contributor counts.

A login role corresponds to each of the last three, created by `make roles` from
`create_login_roles.sql`. A login role holds no privilege of its own, so a
change of privilege takes the form of a migration rather than an alteration to
an individual user. Each carries a connection limit, so that one component
cannot exhaust the connection pool of a free tier instance.

## Separation of the Contributor Data

`dephealth.activity_feature` holds the counts derived from public development
events. Neither the application nor the public API holds any privilege on that
relation, nor on the materialised view beneath the published views. Both reach
the data only through `v_package_assessment` and `v_report_entry`, which pass
each count through `dephealth.disclosed_contributors()` and return null for a
group smaller than the threshold.

A view is executed with the privileges of its owner rather than those of the
caller. The restriction therefore holds for any client connecting as either
role, independently of the application. `db/tests/integrity.sql` asserts it.

The boundary corresponds to the one drawn in section 2.8 of the requirements
document, in which the ingestion pipeline is the only component within scope
for data protection review.

## Authentication

`password_encryption` is set to `scram-sha-256` by the compose file and by the
deployment configuration, and `create_login_roles.sql` terminates with an error
if the server reports any other value. No password occurs in this repository,
in a migration, or as a default.

`db/checks/privileges.sql` reports any login role holding an md5 digest, any
role able to log in with superuser, and any relation reachable by no role.

The system stores no user password, since it maintains no accounts. The single
secret-bearing value held in the database is the digest of a report link token,
described in `docs/data-model.md`.

## Transport

The deployment connects with `sslmode=verify-full`. The `sslmode=prefer` in
`.env.example` applies to loopback connections in development only.
