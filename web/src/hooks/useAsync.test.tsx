import { act, renderHook, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { ApiProblem } from "../api/problem";
import { useAsync, useSubmit } from "./useAsync";

/** A promise this test settles by hand, so the order of answers is the subject. */
function deferred<T>() {
    let settle!: (value: T) => void;
    let fail!: (cause: unknown) => void;
    const promise = new Promise<T>((resolve, reject) => {
        settle = resolve;
        fail = reject;
    });
    return { promise, settle, fail };
}

describe("useAsync", () => {
    it("reports loading until the answer arrives, then the data", async () => {
        const answer = deferred<string>();
        const { result } = renderHook(() => useAsync(() => answer.promise, []));

        expect(result.current.status).toBe("loading");

        await act(async () => {
            answer.settle("a tree");
        });

        expect(result.current.status).toBe("ready");
        expect(result.current.data).toBe("a tree");
        expect(result.current.problem).toBeUndefined();
    });

    it("turns a refusal into the problem the screen branches on", async () => {
        const problem = new ApiProblem({
            type: "/problems/report-not-found",
            title: "No such report",
            status: 404,
            detail: "No report exists for this link.",
        });

        const { result } = renderHook(() => useAsync(() => Promise.reject(problem), []));

        await waitFor(() => expect(result.current.status).toBe("failed"));
        expect(result.current.problem).toBe(problem);
    });

    it("describes a failure before a response as a network problem", async () => {
        const { result } = renderHook(() =>
            useAsync(() => Promise.reject(new Error("connection refused")), []),
        );

        await waitFor(() => expect(result.current.status).toBe("failed"));
        expect(result.current.problem?.status).toBe(0);
        expect(result.current.problem?.detail).toContain("connection refused");
    });

    // The reason the status is derived from a key rather than assigned in an
    // effect: a slow answer to a request the screen has moved on from must not
    // replace the one it is showing
    it("drops an answer to a superseded request", async () => {
        const first = deferred<string>();
        const second = deferred<string>();

        const { result, rerender } = renderHook(
            ({ which }: { which: number }) =>
                useAsync(() => (which === 1 ? first.promise : second.promise), [which]),
            { initialProps: { which: 1 } },
        );

        rerender({ which: 2 });

        await act(async () => {
            second.settle("the newer answer");
        });
        expect(result.current.data).toBe("the newer answer");

        await act(async () => {
            first.settle("the older answer");
        });

        expect(result.current.status).toBe("ready");
        expect(result.current.data).toBe("the newer answer");
    });

    it("runs nothing while it is held off, and stays idle", async () => {
        const task = vi.fn(() => Promise.resolve("never asked for"));
        const { result, rerender } = renderHook(
            ({ enabled }: { enabled: boolean }) => useAsync(task, [], enabled),
            { initialProps: { enabled: false } },
        );

        expect(result.current.status).toBe("idle");
        expect(task).not.toHaveBeenCalled();

        rerender({ enabled: true });
        await waitFor(() => expect(result.current.status).toBe("ready"));
        expect(task).toHaveBeenCalledTimes(1);
    });

    it("asks again when the reader retries", async () => {
        let answered = 0;
        const task = vi.fn(() => Promise.resolve(`answer ${++answered}`));
        const { result } = renderHook(() => useAsync(task, []));

        await waitFor(() => expect(result.current.data).toBe("answer 1"));

        act(() => result.current.reload());

        await waitFor(() => expect(result.current.data).toBe("answer 2"));
        expect(task).toHaveBeenCalledTimes(2);
    });
});

describe("useSubmit", () => {
    it("stays idle until the reader acts, then reports the result", async () => {
        const { result } = renderHook(() => useSubmit((name: string) => Promise.resolve(name)));

        expect(result.current.status).toBe("idle");

        await act(async () => {
            await result.current.submit("Cargo.lock");
        });

        expect(result.current.status).toBe("ready");
        expect(result.current.data).toBe("Cargo.lock");
    });

    it("keeps the refusal and answers with nothing", async () => {
        const problem = new ApiProblem({
            type: "/problems/manifest-unreadable",
            title: "The manifest could not be read",
            status: 422,
            detail: "The file is not valid TOML.",
        });

        const { result } = renderHook(() => useSubmit(() => Promise.reject(problem)));

        let returned: unknown = "unset";
        await act(async () => {
            returned = await result.current.submit();
        });

        expect(returned).toBeUndefined();
        expect(result.current.status).toBe("failed");
        expect(result.current.problem).toBe(problem);
    });

    it("clears a previous attempt when it is reset", async () => {
        const { result } = renderHook(() => useSubmit(() => Promise.resolve("a report")));

        await act(async () => {
            await result.current.submit();
        });
        act(() => result.current.reset());

        expect(result.current.status).toBe("idle");
        expect(result.current.data).toBeUndefined();
        expect(result.current.problem).toBeUndefined();
    });
});
