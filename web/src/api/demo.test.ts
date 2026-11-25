/**
 * The demonstration backing is what the deployed application answers with, so
 * it is held to the same contract as the service: the same report, the same
 * problem documents, and a refusal where the service would refuse.
 */

import { describe, expect, it } from "vitest";

import { ApiProblem } from "./problem";
import { DEMO_TOKEN, demo } from "./demo";

const LOCKFILE = ['[[package]]\nname = "serde"\nversion = "1.0.228"'].join("\n");

async function refusal(promise: Promise<unknown>): Promise<ApiProblem> {
    try {
        await promise;
    } catch (cause) {
        if (cause instanceof ApiProblem) return cause;
        throw cause;
    }
    throw new Error("the call was expected to be refused");
}

describe("the stored report", () => {
    it("answers at the link the submission returns", async () => {
        const submitted = await demo.submitLockfile(LOCKFILE);

        expect(submitted.link).toContain(DEMO_TOKEN);
        expect(submitted.counts.entries).toBeGreaterThan(submitted.counts.resolved);

        const read = await demo.report(DEMO_TOKEN);
        expect(read.entries).toHaveLength(submitted.counts.entries);
    });

    // A token cannot be recovered from a stored report, which is why reading
    // one back carries no link
    it("does not hand the link back when the report is read", async () => {
        const read = await demo.report(DEMO_TOKEN);
        expect(read.link).toBeUndefined();
    });

    it("refuses a link that addresses nothing, as the service does", async () => {
        const problem = await refusal(demo.report("0".repeat(64)));

        expect(problem.status).toBe(404);
        expect(problem.slug).toBe("report-not-found");
    });

    it("refuses a file that is not a lockfile", async () => {
        const problem = await refusal(demo.submitLockfile('[package]\nname = "my-service"'));

        expect(problem.status).toBe(422);
        expect(problem.slug).toBe("manifest-unreadable");
    });
});

describe("the evidence behind an entry", () => {
    it("carries the factors and the series for a scored entry", async () => {
        const detail = await demo.reportEntry(DEMO_TOKEN, "serde");

        expect(detail.entry.package_name).toBe("serde");
        expect(detail.downloads.length).toBeGreaterThan(0);
    });

    it("matches the name without regard to case", async () => {
        const detail = await demo.reportEntry(DEMO_TOKEN, "SERDE");
        expect(detail.entry.package_name).toBe("serde");
    });

    it("refuses an entry the report does not hold", async () => {
        const problem = await refusal(demo.reportEntry(DEMO_TOKEN, "not-in-this-tree"));

        expect(problem.status).toBe(404);
        expect(problem.slug).toBe("entry-not-found");
    });
});

describe("the package list", () => {
    it("narrows to the query and never exceeds the page size", async () => {
        const all = await demo.packages("", 100);
        const narrowed = await demo.packages("serde", 100);

        expect(narrowed.items.length).toBeGreaterThan(0);
        expect(narrowed.items.length).toBeLessThan(all.items.length);
        expect(narrowed.items.every((item) => item.package_name.includes("serde"))).toBe(true);

        const page = await demo.packages("", 3);
        expect(page.items).toHaveLength(3);
        expect(page.limit).toBe(3);
    });

    it("refuses a package that is not in the snapshot", async () => {
        const problem = await refusal(demo.package("not-a-crate"));

        expect(problem.status).toBe(404);
        expect(problem.slug).toBe("package-not-found");
    });
});
