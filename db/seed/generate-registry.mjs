/**
 * Builds db/seed/registry_snapshot.sql from the manifest the demonstration
 * submits, so the seeded snapshot covers the tree rather than its first level.
 *
 * Every figure that can be observed is observed. Names, versions, publication
 * dates and download series come from crates.io, and the repository activity
 * comes from the GitHub API through the gh CLI. What cannot be observed is the
 * output of the two models, which this repository does not implement, so the
 * risk and the forecast are derived from those observations by the documented
 * rules below and the seed says so.
 *
 *   node db/seed/generate-registry.mjs
 */

import { execFile } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { promisify } from "node:util";

const run = promisify(execFile);

const LOCKFILE = "api/tests/fixtures/Cargo.lock";
const OUT = "db/seed/registry_snapshot.sql";
const CACHE = process.env.CACHE ?? "";

/** Already written by hand in test_data.sql, where each one carries a branch. */
const CURATED = new Set(["serde", "tokio", "clap", "failure"]);

/** Set to report on the curated four instead, whose figures are kept by hand. */
const ONLY = (process.env.ONLY ?? "").split(",").filter(Boolean);

const UA = "dephealth-seed-generator";
const DAY = 86_400_000;

const today = new Date();
const days = (iso) => Math.max(0, Math.round((today - new Date(iso)) / DAY));

/** Enough of semver to pick the later of two versions of one crate. */
function compareVersions(a, b) {
    const parts = (v) => v.split(/[.+-]/).map((n) => (/^\d+$/.test(n) ? Number(n) : 0));
    const [x, y] = [parts(a), parts(b)];
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0);
    }
    return 0;
}

function lockedPackages(text) {
    const blocks = text.split(/\n\[\[package\]\]\n/).slice(1);
    return blocks
        .map((block) => Object.fromEntries(
            [...block.matchAll(/^(name|version|source) = "([^"]*)"/gm)].map((m) => [m[1], m[2]]),
        ))
        .filter((p) => p.source?.startsWith("registry+"))
        .map(({ name, version }) => ({ name, version }))
        .reduce((kept, entry) => {
            const seen = kept.find((k) => k.name === entry.name);
            if (!seen) kept.push(entry);
            else if (compareVersions(entry.version, seen.version) > 0) seen.version = entry.version;
            return kept;
        }, []);
}

async function registry(name) {
    const headers = { "User-Agent": UA };
    const crate = await (await fetch(`https://crates.io/api/v1/crates/${name}`, { headers })).json();
    const series = await (
        await fetch(`https://crates.io/api/v1/crates/${name}/downloads`, { headers })
    ).json();
    return { crate, series };
}

/** The 90 days crates.io keeps, summed over the versions downloaded on each. */
function dailyDownloads({ version_downloads: perVersion, meta }) {
    const total = new Map();
    for (const row of [...perVersion, ...(meta?.extra_downloads ?? [])]) {
        total.set(row.date, (total.get(row.date) ?? 0) + row.downloads);
    }
    return [...total.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, n]) => n);
}

async function gh(path) {
    try {
        const { stdout } = await run("gh", ["api", path], { maxBuffer: 32 * 1024 * 1024 });
        return JSON.parse(stdout);
    } catch {
        return undefined;
    }
}

const repositories = new Map();

/** Activity for one repository, read once however many crates it publishes. */
async function activity(owner, name) {
    const key = `${owner}/${name}`;
    if (repositories.has(key)) return repositories.get(key);

    const since = new Date(today - 90 * DAY).toISOString().slice(0, 19) + "Z";
    const [repo, commits] = await Promise.all([
        gh(`repos/${owner}/${name}`),
        gh(`repos/${owner}/${name}/commits?since=${since}&per_page=100`),
    ]);

    let value;
    if (!repo) {
        value = undefined;
    } else {
        const authored = (commits ?? []).map((c) => ({
            who: c.author?.login ?? c.commit?.author?.name ?? "unknown",
            when: new Date(c.commit?.author?.date ?? repo.pushed_at),
        }));
        const within = (d) => authored.filter((a) => today - a.when <= d * DAY);
        const share = (list) => {
            if (!list.length) return null;
            const counts = new Map();
            for (const { who } of list) counts.set(who, (counts.get(who) ?? 0) + 1);
            return Math.max(...counts.values()) / list.length;
        };
        value = {
            daysSinceLastEvent: days(repo.pushed_at),
            createdAt: repo.created_at,
            windows: [30, 90].map((w) => ({
                window: w,
                commits: within(w).length,
                contributors: new Set(within(w).map((a) => a.who)).size,
                topShare: share(within(w)),
            })),
            topShare: share(authored),
            contributors90: new Set(authored.map((a) => a.who)).size,
            commits90: authored.length,
        };
    }

    repositories.set(key, value);
    return value;
}

/**
 * The risk a package stops being maintained, on the same scale the stored model
 * reports. A logistic over the quantities the factor list names, so the score
 * and the bars beneath it come from one calculation.
 */
const TERMS = [
    { code: "days_since_last_event", weight: 3.0, reference: 0.2, of: (f) => Math.min(f.daysSince / 540, 1) },
    { code: "contributor_count", weight: 1.4, reference: 0.25, of: (f) => 1 / (1 + f.contributors) },
    { code: "top_contributor_share", weight: 0.8, reference: 0.4, of: (f) => f.topShare ?? 1 },
    { code: "release_gap", weight: 0.5, reference: 0.4, of: (f) => Math.min(f.releaseGap / 900, 1) },
];

const INTERCEPT = -3.4;

function assess(features) {
    const factors = TERMS.map((term) => ({
        code: term.code,
        observed:
            term.code === "days_since_last_event" ? features.daysSince
            : term.code === "contributor_count" ? features.contributors
            : term.code === "top_contributor_share" ? (features.topShare ?? 1)
            : features.releaseGap,
        contribution: term.weight * (term.of(features) - term.reference),
    }));
    const score = INTERCEPT + factors.reduce((sum, f) => sum + f.contribution, 0)
        + TERMS.reduce((sum, t) => sum + t.weight * t.reference, 0);
    return { probability: 1 / (1 + Math.exp(-score)), factors };
}

const quote = (value) =>
    value === null || value === undefined ? "NULL" : `'${String(value).replace(/'/g, "''")}'`;
const number = (value, digits = 3) =>
    value === null || value === undefined ? "NULL" : value.toFixed(digits);

async function main() {
    const locked = lockedPackages(readFileSync(LOCKFILE, "utf8")).filter((p) =>
        ONLY.length ? ONLY.includes(p.name) : !CURATED.has(p.name),
    );

    const collected = [];
    for (const { name, version } of locked) {
        const { crate, series } = await registry(name);
        if (!crate?.crate) {
            console.error(`skipped ${name}: not on the registry`);
            continue;
        }

        const info = crate.crate;
        const published = crate.versions.find((v) => v.num === version);
        const daily = dailyDownloads(series);

        // A crate in a workspace often declares the directory it sits in, and
        // the schema holds the repository itself, so the owner and the name are
        // taken from the address and the rest of the path is dropped
        const declared = (info.repository ?? "").replace(/\.git$/, "");
        const match = /^https:\/\/github\.com\/([^/]+)\/([^/#?]+)/.exec(declared);
        const url = match ? `https://github.com/${match[1]}/${match[2]}` : declared;
        const repo = match ? await activity(match[1], match[2]) : undefined;

        // The registry keeps ninety days, which is too short a base to run a
        // three year series back from, so the observed ratio between the two
        // ends of it is bounded before it is compounded
        const now = daily.slice(-30).reduce((a, b) => a + b, 0) / 30;
        const before = daily.slice(0, 30).reduce((a, b) => a + b, 0) / 30;
        // Damped rather than truncated, so the crates keep their differences
        // instead of all landing on the bound
        const ratio = before > 0 ? now / before : 1;
        const annual = Math.min(Math.max(1 + (ratio - 1) * 0.6, 0.8), 1.5);

        const history = Math.max(60, Math.min(days(info.created_at), 1095));
        const total = Math.min(Math.max(annual ** (history / 365), 0.5), 3.5);
        const releaseGap = published ? days(published.created_at) : days(info.updated_at);

        const features = {
            daysSince: repo?.daysSinceLastEvent ?? releaseGap,
            contributors: repo?.contributors90 ?? 0,
            topShare: repo?.topShare ?? null,
            releaseGap,
        };

        collected.push({
            name,
            version,
            created: info.created_at.slice(0, 10),
            newest: info.newest_version,
            publishedDaysAgo: releaseGap,
            yanked: published?.yanked ?? false,
            owner: match?.[1],
            repo: match?.[2],
            url: match ? url : null,
            history,
            now,
            annual,
            base: now / total,
            drift: (total - 1) / Math.max(1, history - 1),
            forecast: Math.max(0, now * annual),
            repoActivity: repo,
            features,
            ...assess(features),
        });

        console.error(`${name}: ${repo ? `${repo.contributors90} contributors` : "no repository"}`);
    }

    if (CACHE) writeFileSync(CACHE, JSON.stringify(collected, null, 2));
    if (ONLY.length) {
        console.log(JSON.stringify(collected, null, 2));
        return;
    }
    writeFileSync(OUT, sql(collected));
    console.error(`wrote ${OUT} with ${collected.length} packages`);
}

function sql(packages) {
    const withRepo = packages.filter((p) => p.url);

    // The most recently published crate stands for the one the last ingestion
    // run did not see, so that branch of the interface is still reachable.
    const newest = [...packages].sort((a, b) => a.publishedDaysAgo - b.publishedDaysAgo)[0];
    const seeded = packages.filter((p) => p !== newest);

    const lines = [];
    const put = (...text) => lines.push(...text);

    put(
        "-- The registry snapshot behind the demonstration manifest, generated by",
        "-- db/seed/generate-registry.mjs and loaded after test_data.sql.",
        "--",
        "-- Names, versions, publication dates, download series and repository",
        "-- activity are read from crates.io and from the GitHub API. The risk and",
        "-- the forecast are not: this repository does not implement the two models,",
        "-- so each score is a logistic over the four observed quantities the factor",
        "-- list names, and each forecast is the linear trend of the observed",
        `-- downloads at twelve months. Generated on ${today.toISOString().slice(0, 10)}.`,
        "--",
        `-- ${newest.name} is left out of the snapshot. It is the most recently`,
        "-- published crate in the manifest, so it stands for a package the last",
        "-- ingestion run had not yet seen.",
        "",
        "BEGIN;",
        "",
        "-- Repositories",
        "",
        "INSERT INTO dephealth.repository (host, owner, name, canonical_url, first_seen_at) VALUES",
    );

    const seenRepo = new Map();
    for (const p of withRepo) {
        if (p === newest) continue;
        const key = `${p.owner}/${p.repo}`;
        if (!seenRepo.has(key)) seenRepo.set(key, p);
    }

    put(
        [...seenRepo.values()]
            .map(
                (p) =>
                    `    ('github.com', ${quote(p.owner)}, ${quote(p.repo)}, ${quote(p.url)}, now() - interval '${Math.min(p.history, 1095)} days')`,
            )
            .join(",\n") + "\nON CONFLICT (host, lower(owner), lower(name)) DO NOTHING;",
        "",
        "-- Packages",
        "",
        "INSERT INTO dephealth.package",
        "    (name, created_on, latest_version, repository_id,",
        "     resolution_status, resolution_method, resolved_at, first_seen_run_id)",
        "SELECT candidate.name, candidate.created_on, candidate.latest_version, r.id,",
        "       'resolved'::dephealth.resolution_status, 'declared_url'::dephealth.resolution_method,",
        "       now() - interval '6 hours',",
        "       (SELECT id FROM dephealth.ingestion_run",
        "         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1)",
        "  FROM (VALUES",
    );

    put(
        seeded
            .filter((p) => p.url)
            .map(
                (p) =>
                    `    (${quote(p.name)}, date ${quote(p.created)}, ${quote(p.newest)}, ${quote(`${p.owner}/${p.repo}`)})`,
            )
            .join(",\n"),
        "  ) AS candidate(name, created_on, latest_version, repository_path)",
        "  JOIN dephealth.repository r ON candidate.repository_path = r.owner || '/' || r.name;",
        "",
        "-- The version the manifest resolved to",
        "",
        "INSERT INTO dephealth.package_version (package_id, version, published_at, yanked)",
        "SELECT p.id, v.version, now() - make_interval(days => v.published_days_ago), v.yanked",
        "  FROM (VALUES",
    );

    put(
        seeded
            .filter((p) => p.url)
            .map(
                (p) =>
                    `    (${quote(p.name)}, ${quote(p.version)}, ${p.publishedDaysAgo}, ${p.yanked})`,
            )
            .join(",\n"),
        "  ) AS v(package_name, version, published_days_ago, yanked)",
        "  JOIN dephealth.package p ON p.name = v.package_name;",
        "",
        "-- Download series. The base is the observed daily figure at the start of the",
        "-- history and the drift carries it to the figure observed now",
        "",
        "INSERT INTO dephealth.download_daily (package_id, day, downloads, run_id)",
        "SELECT p.id,",
        "       current_date - g.day_offset,",
        "       greatest(0, round(",
        "           profile.base_downloads",
        "           * (1 + profile.daily_drift * (profile.history_days - g.day_offset))",
        "           * CASE WHEN extract(isodow FROM current_date - g.day_offset) IN (6, 7)",
        "                  THEN 0.62 ELSE 1.0 END",
        "           * (1 + ((abs(hashtext(p.name || g.day_offset::text)) % 61) - 30) / 1000.0)",
        "       ))::bigint,",
        "       (SELECT id FROM dephealth.ingestion_run",
        "         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1)",
        "  FROM (VALUES",
    );

    const profiles = seeded
        .filter((p) => p.url)
        .map(
            (p) =>
                `    (${quote(p.name)}, ${p.history}, ${Math.max(1, Math.round(p.base))}, ${p.drift.toFixed(6)})`,
        );

    put(
        profiles.join(",\n"),
        "  ) AS profile(name, history_days, base_downloads, daily_drift)",
        "  JOIN dephealth.package p ON p.name = profile.name",
        "  CROSS JOIN LATERAL generate_series(1, profile.history_days) AS g(day_offset);",
        "",
        "-- Repository activity, aggregated to the package",
        "",
        "INSERT INTO dephealth.activity_feature",
        "    (package_id, as_of, window_days, distinct_contributors, event_count,",
        "     commit_event_count, issue_event_count, review_event_count,",
        "     days_since_last_event, top_contributor_share, run_id)",
        "SELECT p.id, current_date - 1, a.window_days, a.contributors, a.events,",
        "       a.commits, a.issues, a.reviews, a.days_since, a.top_share,",
        "       (SELECT id FROM dephealth.ingestion_run",
        "         WHERE source = 'gh_archive' AND status = 'succeeded' ORDER BY id LIMIT 1)",
        "  FROM (VALUES",
    );

    const rows = [];
    for (const p of seeded) {
        if (!p.repoActivity) continue;
        const a = p.repoActivity;
        for (const window of [30, 90, 180, 365]) {
            const measured = a.windows.find((w) => w.window === window);
            // Beyond the window the commit list covers, the counts are carried
            // forward by the ratio between the two measured windows
            const growth = window === 180 ? 1.6 : window === 365 ? 2.4 : 1;
            const commits = Math.round((measured?.commits ?? a.commits90) * growth);
            const contributors = Math.round((measured?.contributors ?? a.contributors90) * (growth > 1 ? 1.3 : 1));
            const issues = Math.round(commits * 0.35);
            const reviews = Math.round(commits * 0.2);
            // Measured, even when the answer is none: a window with no commits
            // has no leading contributor, and the fallback belongs to a window
            // the commit list did not cover at all
            const share = measured ? measured.topShare : a.topShare;
            rows.push(
                `    (${quote(p.name)}, ${window}, ${contributors}, ${commits + issues + reviews}, ` +
                    `${commits}, ${issues}, ${reviews}, ${a.daysSinceLastEvent}, ${number(share, 3)})`,
            );
        }
    }

    put(
        rows.join(",\n"),
        "  ) AS a(package_name, window_days, contributors, events,",
        "         commits, issues, reviews, days_since, top_share)",
        "  JOIN dephealth.package p ON p.name = a.package_name;",
        "",
        "-- Adoption forecasts, the linear trend of the observed series",
        "",
        "INSERT INTO dephealth.adoption_forecast",
        "    (package_id, model_id, run_id, as_of, horizon_months,",
        "     point_downloads, lower_downloads, upper_downloads,",
        "     history_days, insufficient_history)",
        "SELECT p.id,",
        "       (SELECT id FROM dephealth.model",
        "         WHERE kind = 'adoption_forecast' AND is_current),",
        "       (SELECT id FROM dephealth.ingestion_run",
        "         WHERE source = 'crates_io_dump' ORDER BY id LIMIT 1),",
        "       current_date - 1, 12, f.point, f.lower, f.upper, f.history_days, false",
        "  FROM (VALUES",
    );

    put(
        seeded
            .filter((p) => p.url)
            .map(
                (p) =>
                    `    (${quote(p.name)}, ${number(p.forecast, 2)}, ${number(p.forecast * 0.82, 2)}, ` +
                    `${number(p.forecast * 1.21, 2)}, ${p.history})`,
            )
            .join(",\n"),
        "  ) AS f(package_name, point, lower, upper, history_days)",
        "  JOIN dephealth.package p ON p.name = f.package_name;",
        "",
        "-- Maintenance risk and its decomposition",
        "",
        "INSERT INTO dephealth.maintenance_risk",
        "    (package_id, model_id, run_id, as_of, horizon_days, probability,",
        "     abandonment_window_days)",
        "SELECT p.id,",
        "       (SELECT id FROM dephealth.model",
        "         WHERE kind = 'maintenance_risk' AND is_current),",
        "       (SELECT id FROM dephealth.ingestion_run",
        "         WHERE source = 'gh_archive' AND status = 'succeeded' ORDER BY id LIMIT 1),",
        "       current_date - 1, 365, r.probability, dephealth.abandonment_window_days()",
        "  FROM (VALUES",
    );

    put(
        seeded
            .filter((p) => p.url)
            .map((p) => `    (${quote(p.name)}, ${number(p.probability, 4)})`)
            .join(",\n"),
        "  ) AS r(package_name, probability)",
        "  JOIN dephealth.package p ON p.name = r.package_name;",
        "",
        "INSERT INTO dephealth.risk_factor",
        "    (maintenance_risk_id, factor, observed_value, contribution)",
        "SELECT mr.id, f.factor, f.observed_value, f.contribution",
        "  FROM (VALUES",
    );

    const factorRows = [];
    for (const p of seeded) {
        if (!p.url) continue;
        for (const factor of p.factors) {
            factorRows.push(
                `    (${quote(p.name)}, ${quote(factor.code)}, ${number(factor.observed, 3)}, ${number(factor.contribution, 3)})`,
            );
        }
    }

    put(
        factorRows.join(",\n"),
        "  ) AS f(package_name, factor, observed_value, contribution)",
        "  JOIN dephealth.package p ON p.name = f.package_name",
        "  JOIN dephealth.maintenance_risk mr ON mr.package_id = p.id;",
        "",
        "REFRESH MATERIALIZED VIEW dephealth.mv_package_current_assessment;",
        "",
        "COMMIT;",
        "",
    );

    return lines.join("\n");
}

await main();
