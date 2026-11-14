-- Layer 1, raw. Views over the downloaded files, nothing cast or copied, so a
-- defect can be traced back to the file it came from.

CREATE SCHEMA IF NOT EXISTS raw;

-- crates.io publishes a daily dump as CSV. Four of its tables are used.
CREATE OR REPLACE VIEW raw.crates AS
SELECT * FROM read_csv('data/raw/crates_io/crates.csv',
                       header = true, all_varchar = true);

CREATE OR REPLACE VIEW raw.versions AS
SELECT * FROM read_csv('data/raw/crates_io/versions.csv',
                       header = true, all_varchar = true);

CREATE OR REPLACE VIEW raw.version_downloads AS
SELECT * FROM read_csv('data/raw/crates_io/version_downloads.csv',
                       header = true, all_varchar = true);

CREATE OR REPLACE VIEW raw.dependencies AS
SELECT * FROM read_csv('data/raw/crates_io/dependencies.csv',
                       header = true, all_varchar = true);

-- GH Archive publishes one gzipped newline delimited JSON file per hour. Only
-- the four event types that indicate development work are read; the rest are
-- left on disk unread and deleted with everything else at the end of the run.
CREATE OR REPLACE VIEW raw.events AS
SELECT id,
       type,
       created_at,
       actor.login      AS actor_login,
       repo.name        AS repo_full_name
  FROM read_json('data/raw/gh_archive/*.json.gz',
                 format = 'newline_delimited',
                 columns = {
                     id: 'VARCHAR',
                     type: 'VARCHAR',
                     created_at: 'VARCHAR',
                     actor: 'STRUCT(login VARCHAR)',
                     repo: 'STRUCT(name VARCHAR)'
                 })
 WHERE type IN ('PushEvent', 'PullRequestEvent',
                'PullRequestReviewEvent', 'IssuesEvent');
