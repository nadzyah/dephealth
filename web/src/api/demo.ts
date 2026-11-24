/**
 * The demo backing. Every fixture in `fixtures/` is a response captured from
 * the running service against the seeded database, so the demo shows what the
 * API actually returns rather than something written to look plausible.
 *
 * It exists so the deployed application can be opened and used without the
 * service, which is what makes a public URL useful to a reviewer. The error
 * paths answer too: an unknown link gives the same 404 problem document as the
 * real API, and a body that is not a lockfile gives the same 422.
 */

import { ApiProblem } from "./problem";
import changesFixture from "./fixtures/changes.json";
import entriesFixture from "./fixtures/entries.json";
import metaFixture from "./fixtures/meta.json";
import packagesFixture from "./fixtures/packages.json";
import reportFixture from "./fixtures/report.json";
import type {
    Assessment,
    Changes,
    DownloadPoint,
    EntryDetail,
    EntryInput,
    Meta,
    PackagePage,
    Report,
} from "./types";

export const DEMO_TOKEN = "demo";

/** Long enough that a loading state is seen rather than flashed. */
const LATENCY_MS = 400;

const report = reportFixture as unknown as Report;
const entries = entriesFixture as unknown as Record<string, EntryDetail>;
const meta = metaFixture as unknown as Meta;
const changes = changesFixture as unknown as Changes;
const packages = packagesFixture as unknown as PackagePage;

function settle<T>(value: T): Promise<T> {
    return new Promise((resolve) => setTimeout(() => resolve(structuredClone(value)), LATENCY_MS));
}

function reject(problem: ApiProblem): Promise<never> {
    return new Promise((_, fail) => setTimeout(() => fail(problem), LATENCY_MS));
}

function notFound(type: string, title: string, detail: string): ApiProblem {
    return new ApiProblem({ type: `/problems/${type}`, title, status: 404, detail });
}

function knownReport(token: string): boolean {
    return token === DEMO_TOKEN;
}

function detailOf(name: string): EntryDetail | undefined {
    return entries[name.toLowerCase()];
}

export const demo = {
    meta: () => settle(meta),

    submitLockfile: (lockfile: string): Promise<Report> => {
        if (!lockfile.includes("[[package]]")) {
            return reject(
                new ApiProblem({
                    type: "/problems/manifest-unreadable",
                    title: "The manifest could not be read",
                    status: 422,
                    detail: "This does not look like a Cargo lockfile. The demo accepts the same files as the service, which expects a [[package]] table per entry.",
                }),
            );
        }
        return settle(report);
    },

    submitEntries: (_entries: EntryInput[]): Promise<Report> => settle(report),

    report: (token: string): Promise<Report> =>
        knownReport(token)
            ? settle({ ...report, link: undefined })
            : reject(
                  notFound(
                      "report-not-found",
                      "No such report",
                      "This demo holds one stored report, at the link on the submission screen.",
                  ),
              ),

    reportEntry: (token: string, name: string): Promise<EntryDetail> => {
        if (!knownReport(token)) {
            return reject(notFound("report-not-found", "No such report", "Unknown link."));
        }

        const detail = detailOf(name);
        return detail
            ? settle(detail)
            : reject(
                  notFound(
                      "entry-not-found",
                      "No such entry in this report",
                      `The demo carries the evidence for ${Object.keys(entries).join(", ")}. The service carries it for every entry.`,
                  ),
              );
    },

    changes: (token: string): Promise<Changes> =>
        knownReport(token)
            ? settle(changes)
            : reject(notFound("report-not-found", "No such report", "Unknown link.")),

    packages: (query: string, limit: number): Promise<PackagePage> => {
        const needle = query.trim().toLowerCase();
        const items = needle
            ? packages.items.filter((item) => item.package_name.toLowerCase().includes(needle))
            : packages.items;

        return settle({ items: items.slice(0, limit), limit, offset: 0 });
    },

    package: (name: string): Promise<Assessment> => {
        const live = detailOf(name)?.live;
        return live
            ? settle(live)
            : reject(
                  notFound(
                      "package-not-found",
                      "No such package",
                      `No package named ${name} is present in the demo snapshot.`,
                  ),
              );
    },

    downloads: (name: string): Promise<DownloadPoint[]> => {
        const detail = detailOf(name);
        return detail
            ? settle(detail.downloads)
            : reject(
                  notFound(
                      "package-not-found",
                      "No such package",
                      `No series for ${name} in the demo snapshot.`,
                  ),
              );
    },
};
