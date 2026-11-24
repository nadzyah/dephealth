/**
 * One state machine for every request the screens make, so each of them reports
 * loading, failure and emptiness the same way.
 *
 * An answer carries the key of the request that asked for it. The status is
 * then derived by comparing that key with the one in force, so a slow answer
 * to a superseded request cannot overwrite a newer one and a component that
 * has gone is never written into.
 */

import { useCallback, useEffect, useState } from "react";

import { ApiProblem } from "../api/problem";

export type AsyncStatus = "idle" | "loading" | "ready" | "failed";

export interface AsyncState<T> {
    status: AsyncStatus;
    data: T | undefined;
    problem: ApiProblem | undefined;
    reload: () => void;
}

function asProblem(cause: unknown): ApiProblem {
    if (cause instanceof ApiProblem) return cause;
    return ApiProblem.network(
        cause instanceof Error ? cause.message : "Something failed before a response arrived.",
    );
}

/**
 * Runs `task` when the dependencies change. Pass `enabled: false` to hold off,
 * which is what a screen does while it is still missing a parameter.
 */
export function useAsync<T>(
    task: () => Promise<T>,
    dependencies: readonly unknown[],
    enabled = true,
): AsyncState<T> {
    const [attempt, setAttempt] = useState(0);

    // What the request was for. Comparing it with the answer in hand is what
    // makes the status a derived value rather than one assigned from an effect,
    // and a stale answer is then simply an answer for another key
    const key = JSON.stringify([dependencies, enabled, attempt]);

    const [answer, setAnswer] = useState<{
        key: string;
        data?: T;
        problem?: ApiProblem;
    } | null>(null);

    useEffect(() => {
        if (!enabled) return;

        let live = true;
        task()
            .then((data) => {
                if (live) setAnswer({ key, data });
            })
            .catch((cause: unknown) => {
                if (live) setAnswer({ key, problem: asProblem(cause) });
            });

        // An answer to a request this component no longer waits for is dropped
        // rather than written into a component that has moved on
        return () => {
            live = false;
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [key]);

    const reload = useCallback(() => setAttempt((n) => n + 1), []);

    const status: AsyncStatus = !enabled
        ? "idle"
        : answer?.key !== key
          ? "loading"
          : answer.problem
            ? "failed"
            : "ready";

    return { status, data: answer?.data, problem: answer?.problem, reload };
}

/**
 * The same machine for something the reader starts, such as submitting a
 * manifest, where nothing should happen until they act.
 */
export function useSubmit<A extends unknown[], T>(
    task: (...args: A) => Promise<T>,
): {
    status: AsyncStatus;
    data: T | undefined;
    problem: ApiProblem | undefined;
    submit: (...args: A) => Promise<T | undefined>;
    reset: () => void;
} {
    const [status, setStatus] = useState<AsyncStatus>("idle");
    const [data, setData] = useState<T | undefined>(undefined);
    const [problem, setProblem] = useState<ApiProblem | undefined>(undefined);

    const submit = useCallback(
        async (...args: A) => {
            setStatus("loading");
            setProblem(undefined);
            try {
                const value = await task(...args);
                setData(value);
                setStatus("ready");
                return value;
            } catch (cause) {
                setProblem(asProblem(cause));
                setStatus("failed");
                return undefined;
            }
        },
        [task],
    );

    const reset = useCallback(() => {
        setStatus("idle");
        setData(undefined);
        setProblem(undefined);
    }, []);

    return { status, data, problem, submit, reset };
}
