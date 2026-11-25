/**
 * Recaptures the demonstration fixtures from a running service.
 *
 * Every file in src/api/fixtures is a response this script read from the API,
 * so the deployed demonstration answers with what the service actually returns.
 * It submits the manifest the end to end tests use, then follows the same path
 * through the application a reader would.
 *
 *   make db-reset && cargo run         # in api/, with .env loaded
 *   node scripts/fixtures.mjs          # in web/
 *
 * API=http://127.0.0.1:8080 chooses another address.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const OUT = join(root, "src/api/fixtures");
const MANIFEST = join(root, "../api/tests/fixtures/Cargo.lock");

const API = process.env.API ?? "http://127.0.0.1:8080";

async function get(path) {
    const response = await fetch(`${API}${path}`);
    if (!response.ok) throw new Error(`${path} answered ${response.status}`);
    return response.json();
}

function write(name, value) {
    writeFileSync(join(OUT, name), `${JSON.stringify(value, null, 4)}\n`);
    console.error(`${name}: ${JSON.stringify(value).length} bytes`);
}

/**
 * The token is replaced by the one the demo uses, so a link in a capture works,
 * and the address of whatever service was captured is dropped with it. The
 * demonstration is served from somewhere else entirely.
 */
function asDemo(value) {
    return JSON.parse(
        JSON.stringify(value).replaceAll(/(https?:\/\/[^"]*?)?\/r\/[0-9a-f]{64}/g, "/r/demo"),
    );
}

const submitted = await fetch(`${API}/api/v1/assessments`, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: readFileSync(MANIFEST, "utf8"),
});

if (!submitted.ok) throw new Error(`the manifest was refused with ${submitted.status}`);

const created = await submitted.json();
const token = created.link.split("/r/")[1];

mkdirSync(OUT, { recursive: true });

// The submission answers with the link, which a later read of the same report
// does not, since a token cannot be recovered from storage. The demo needs the
// one with the link in it, because that is the response it stands in for
const report = created;
write("report.json", asDemo(report));
write("meta.json", await get("/api/v1/meta"));
write("packages.json", await get("/api/v1/packages?limit=200"));

/**
 * Three years of daily downloads for every entry is four megabytes of page, and
 * the chart is some hundreds of pixels wide, so the captured series is reduced
 * to one point a week with the most recent day kept. The service still answers
 * with every day of it.
 */
function weekly(points) {
    if (points.length <= 200) return points;
    const kept = points.filter((_, index) => index % 7 === 0);
    const last = points[points.length - 1];
    if (kept[kept.length - 1] !== last) kept.push(last);
    return kept;
}

// One request per entry, since the endpoint already answers with the entry,
// its factors, its download series and the current assessment beside it
const entries = {};
for (const entry of report.entries) {
    const name = entry.package_name;
    const detail = await get(`/api/v1/reports/${token}/entries/${encodeURIComponent(name)}`);
    detail.downloads = weekly(detail.downloads ?? []);
    entries[name.toLowerCase()] = asDemo(detail);
}
write("entries.json", entries);

// The comparison against the earlier assessment of the same manifest, which
// exists only once the same manifest has been submitted twice
const again = await fetch(`${API}/api/v1/assessments`, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: readFileSync(MANIFEST, "utf8"),
});
const second = await again.json();
const secondToken = second.link.split("/r/")[1];
write("changes.json", asDemo(await get(`/api/v1/reports/${secondToken}/changes`)));
