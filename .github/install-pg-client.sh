#!/usr/bin/env bash
# Install the PostgreSQL client tools matching the server in docker-compose.yml.
#
# The runner image carries a newer major version, and /usr/bin/pg_dump is a
# wrapper that picks the newest installed one, so checking its version says
# nothing about what is available. db/ddl/generate.sh looks for the versioned
# path instead, which is what this script provides.
set -euo pipefail

major=17
binary=/usr/lib/postgresql/$major/bin/pg_dump

if [[ -x $binary ]]; then
    echo "install-pg-client: $binary is already present"
    exit 0
fi

codename=$(lsb_release -cs)

sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null

sudo apt-get update
sudo apt-get install --yes --no-install-recommends "postgresql-client-$major"

"$binary" --version
