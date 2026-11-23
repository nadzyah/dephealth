#!/usr/bin/env bash
# Write the .env a CI run needs. The values are generated per run and throwaway,
# so nothing here is a secret and none of it belongs in the repository.
#
# It refuses to overwrite an existing .env, so running it by hand cannot destroy
# a development one.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -e .env ]]; then
    echo "write-env: .env already exists, refusing to overwrite it" >&2
    exit 1
fi

generate() { openssl rand -hex 24; }

owner_password=$(generate)
port=55432

cat > .env <<ENV
POSTGRES_DB=dephealth
POSTGRES_USER=dephealth_owner
POSTGRES_PASSWORD=$owner_password
POSTGRES_PORT=$port

DATABASE_URL=postgres://dephealth_owner:$owner_password@127.0.0.1:$port/dephealth?sslmode=disable

INGEST_PASSWORD=$(generate)
APP_PASSWORD=$(generate)
PUBLIC_READ_PASSWORD=$(generate)

MANIFEST_SALT=$(generate)
ENV

# The API connects as the application role, which the file above has just
# given a password to
app_password=$(grep '^APP_PASSWORD=' .env | cut -d= -f2)

cat >> .env <<ENV

API_DATABASE_URL=postgres://dephealth_app_login:$app_password@127.0.0.1:$port/dephealth?sslmode=disable
API_BIND=127.0.0.1:8080
API_CORS_ORIGINS=http://localhost:5173
API_PUBLIC_BASE_URL=http://localhost:5173
API_ADMIN_TOKEN=$(generate)
ENV

chmod 600 .env
echo "write-env: wrote .env with generated values"
