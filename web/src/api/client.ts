/**
 * Every request the application makes goes through here. One place sets the base
 * address, the timeout and the headers, turns a failure into an ApiProblem, and
 * logs it. No component calls fetch.
 *
 * In demo mode the same functions answer from committed fixtures, which is what
 * lets the deployed application be opened and used without the service behind
 * it.
 */

import { logger } from "../lib/logger";
import { demo } from "./demo";
import { ApiProblem, type ProblemBody } from "./problem";
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

export const API_BASE: string = (
    import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8080"
).replace(/\/$/, "");

export const DEMO: boolean = import.meta.env.VITE_DEMO === "true";

const TIMEOUT_MS = 20_000;

interface RequestOptions {
    method?: "GET" | "POST";
    body?: BodyInit;
    contentType?: string;
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const url = `${API_BASE}${path}`;
    const started = performance.now();

    const headers: Record<string, string> = { Accept: "application/json" };
    if (options.contentType) headers["Content-Type"] = options.contentType;

    let response: Response;
    try {
        response = await fetch(url, {
            method: options.method ?? "GET",
            headers,
            body: options.body,
            signal: AbortSignal.timeout(TIMEOUT_MS),
        });
    } catch (cause) {
        const problem =
            cause instanceof DOMException && cause.name === "TimeoutError"
                ? ApiProblem.network(
                      `The service did not answer within ${TIMEOUT_MS / 1000} seconds.`,
                  )
                : ApiProblem.network(
                      `No answer from ${API_BASE}. It may not be running, or this page may not be allowed to call it.`,
                  );

        logger.error("request failed before a response", { path, problem: problem.type });
        throw problem;
    }

    if (!response.ok) {
        const problem = await asProblem(response);
        logger.warn("request refused", {
            path,
            status: response.status,
            problem: problem.type,
            ms: Math.round(performance.now() - started),
        });
        throw problem;
    }

    logger.debug("request served", {
        path,
        status: response.status,
        ms: Math.round(performance.now() - started),
    });

    if (response.status === 204) return undefined as T;
    return (await response.json()) as T;
}

/** A problem document when the service sent one, and a plausible one when not. */
async function asProblem(response: Response): Promise<ApiProblem> {
    const contentType = response.headers.get("content-type") ?? "";

    if (contentType.includes("problem+json") || contentType.includes("application/json")) {
        try {
            const body = (await response.json()) as ProblemBody;
            if (typeof body?.title === "string" && typeof body?.status === "number") {
                return new ApiProblem(body);
            }
        } catch {
            // falls through to the status based problem
        }
    }

    return ApiProblem.fromStatus(response.status, response.statusText);
}

export const api = {
    meta: (): Promise<Meta> => (DEMO ? demo.meta() : request<Meta>("/api/v1/meta")),

    submitLockfile: (lockfile: string): Promise<Report> =>
        DEMO
            ? demo.submitLockfile(lockfile)
            : request<Report>("/api/v1/assessments", {
                  method: "POST",
                  body: lockfile,
                  contentType: "application/toml",
              }),

    submitEntries: (entries: EntryInput[]): Promise<Report> =>
        DEMO
            ? demo.submitEntries(entries)
            : request<Report>("/api/v1/assessments", {
                  method: "POST",
                  body: JSON.stringify({ entries }),
                  contentType: "application/json",
              }),

    report: (token: string): Promise<Report> =>
        DEMO ? demo.report(token) : request<Report>(`/api/v1/reports/${encodeURIComponent(token)}`),

    reportEntry: (token: string, name: string): Promise<EntryDetail> =>
        DEMO
            ? demo.reportEntry(token, name)
            : request<EntryDetail>(
                  `/api/v1/reports/${encodeURIComponent(token)}/entries/${encodeURIComponent(name)}`,
              ),

    changes: (token: string): Promise<Changes> =>
        DEMO
            ? demo.changes(token)
            : request<Changes>(`/api/v1/reports/${encodeURIComponent(token)}/changes`),

    packages: (query: string, limit = 50): Promise<PackagePage> => {
        const search = new URLSearchParams({ limit: String(limit) });
        if (query) search.set("q", query);
        return DEMO
            ? demo.packages(query, limit)
            : request<PackagePage>(`/api/v1/packages?${search}`);
    },

    package: (name: string): Promise<Assessment> =>
        DEMO
            ? demo.package(name)
            : request<Assessment>(`/api/v1/packages/${encodeURIComponent(name)}`),

    downloads: (name: string): Promise<DownloadPoint[]> =>
        DEMO
            ? demo.downloads(name)
            : request<DownloadPoint[]>(`/api/v1/packages/${encodeURIComponent(name)}/downloads`),
};
