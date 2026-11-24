/**
 * One state machine for every request the screens make, so each of them reports
 * loading, failure and emptiness the same way.
 *
 * A request that resolves after the component has gone is dropped rather than
 * written into a dead component, and a second request started before the first
 * answers discards the first, which is what stops a slow earlier response from
 * overwriting a newer one.
 */

import { useCallback, useEffect, useRef, useState } from "react";

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
    const [status, setStatus] = useState<AsyncStatus>(enabled ? "loading" : "idle");
    const [data, setData] = useState<T | undefined>(undefined);
    const [problem, setProblem] = useState<ApiProblem | undefined>(undefined);
    const [attempt, setAttempt] = useState(0);

    const live = useRef(0);

    useEffect(() => {
        if (!enabled) {
            setStatus("idle");
            return;
        }

        const generation = ++live.current;
        setStatus("loading");
        setProblem(undefined);

        task()
            .then((value) => {
                if (generation !== live.current) return;
                setData(value);
                setStatus("ready");
            })
            .catch((cause: unknown) => {
                if (generation !== live.current) return;
                setProblem(asProblem(cause));
                setStatus("failed");
            });

        return () => {
            // Any answer to this request is now stale
            if (generation === live.current) live.current += 1;
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [...dependencies, enabled, attempt]);

    const reload = useCallback(() => setAttempt((n) => n + 1), []);

    return { status, data, problem, reload };
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
