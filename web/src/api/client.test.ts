/**
 * The request layer, where a failure becomes a value the screens can read. These
 * are the cases a screen must not have to think about.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "./client";
import { ApiProblem } from "./problem";

function jsonResponse(body: unknown, status = 200, contentType = "application/json") {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": contentType },
    });
}

describe("the request layer", () => {
    beforeEach(() => {
        vi.stubGlobal("fetch", vi.fn());
    });

    afterEach(() => {
        vi.unstubAllGlobals();
    });

    it("returns the body of a successful request", async () => {
        vi.mocked(fetch).mockResolvedValue(
            jsonResponse({ service: "dephealth", version: "0.1.0" }),
        );

        await expect(api.meta()).resolves.toMatchObject({ service: "dephealth" });
    });

    it("turns a problem document into a problem with its identifier intact", async () => {
        vi.mocked(fetch).mockResolvedValue(
            jsonResponse(
                {
                    type: "/problems/report-withdrawn",
                    title: "The report has been withdrawn",
                    status: 410,
                    detail: "superseded",
                    withdrawn_at: "2026-11-20T11:02:51Z",
                },
                410,
                "application/problem+json",
            ),
        );

        const problem = await api.report("demo").catch((cause: unknown) => cause);

        expect(problem).toBeInstanceOf(ApiProblem);
        expect((problem as ApiProblem).slug).toBe("report-withdrawn");
        expect((problem as ApiProblem).isGone).toBe(true);
        expect((problem as ApiProblem).field<string>("withdrawn_at")).toBe("2026-11-20T11:02:51Z");
    });

    it("keeps the line a manifest failed on, which the screen shows", async () => {
        vi.mocked(fetch).mockResolvedValue(
            jsonResponse(
                {
                    type: "/problems/manifest-unreadable",
                    title: "The manifest could not be read",
                    status: 422,
                    detail: "unclosed array table",
                    line: 14,
                },
                422,
                "application/problem+json",
            ),
        );

        const problem = (await api
            .submitLockfile("[[package")
            .catch((cause: unknown) => cause)) as ApiProblem;

        expect(problem.field<number>("line")).toBe(14);
    });

    it("invents a usable problem when a failure carries no document", async () => {
        vi.mocked(fetch).mockResolvedValue(
            new Response("<html>502</html>", {
                status: 502,
                headers: { "content-type": "text/html" },
            }),
        );

        const problem = (await api.meta().catch((cause: unknown) => cause)) as ApiProblem;

        expect(problem.status).toBe(502);
        expect(problem.isServerFault).toBe(true);
        expect(problem.title).toBe("The service is unreachable");
    });

    it("reports a service that cannot be reached at all", async () => {
        vi.mocked(fetch).mockRejectedValue(new TypeError("Failed to fetch"));

        const problem = (await api.meta().catch((cause: unknown) => cause)) as ApiProblem;

        expect(problem.status).toBe(0);
        expect(problem.slug).toBe("network");
    });

    it("sends a lockfile as TOML and an entry list as JSON", async () => {
        // A fresh response per call, since a body can only be read once
        vi.mocked(fetch).mockImplementation(() =>
            Promise.resolve(jsonResponse({ counts: {} }, 201)),
        );

        await api.submitLockfile("version = 4");
        await api.submitEntries([{ name: "serde", version: "1.0.228" }]);

        const [lockfileCall, entriesCall] = vi.mocked(fetch).mock.calls;

        expect((lockfileCall[1]?.headers as Record<string, string>)["Content-Type"]).toBe(
            "application/toml",
        );
        expect((entriesCall[1]?.headers as Record<string, string>)["Content-Type"]).toBe(
            "application/json",
        );
        expect(entriesCall[1]?.body).toContain("serde");
    });

    it("escapes a token rather than pasting it into the path", async () => {
        vi.mocked(fetch).mockResolvedValue(jsonResponse({}));

        await api.reportEntry("demo", "my crate/../etc");

        expect(vi.mocked(fetch).mock.calls[0][0]).toBe(
            "http://localhost:8080/api/v1/reports/demo/entries/my%20crate%2F..%2Fetc",
        );
    });
});
