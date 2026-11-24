/**
 * What a screen shows when it has nothing to show yet: loading, empty, or
 * failed. Kept together so every screen reports the three the same way.
 */

import type { ReactNode } from "react";

import type { ApiProblem } from "../../api/problem";
import { Button } from "./Button";
import { WarningIcon } from "./icons";

import "./States.css";

interface SkeletonProps {
    /** A share of the container width, so the shapes suggest the real layout. */
    width?: string;
    height?: string;
    className?: string;
}

export function Skeleton({ width = "100%", height = "1rem", className }: SkeletonProps) {
    return (
        <span
            className={["skeleton", className].filter(Boolean).join(" ")}
            style={{ width, height }}
            aria-hidden="true"
        />
    );
}

/**
 * The shape of a table while it loads. Announced politely, so a screen reader
 * hears that something is coming rather than silence.
 */
export function TableSkeleton({ rows = 6, label }: { rows?: number; label: string }) {
    return (
        <div className="skeleton-table" role="status" aria-live="polite">
            <span className="visually-hidden">{label}</span>
            {Array.from({ length: rows }, (_, row) => (
                <div className="skeleton-row" key={row}>
                    <Skeleton width="40%" />
                    <Skeleton width="18%" />
                    <Skeleton width="22%" />
                </div>
            ))}
        </div>
    );
}

export function Loading({ label }: { label: string }) {
    return (
        <div className="state" role="status" aria-live="polite">
            <span className="state-spinner" aria-hidden="true" />
            <p className="muted">{label}</p>
        </div>
    );
}

interface EmptyProps {
    title: string;
    children?: ReactNode;
}

export function Empty({ title, children }: EmptyProps) {
    return (
        <div className="state">
            <h3>{title}</h3>
            {children}
        </div>
    );
}

interface FailureProps {
    problem: ApiProblem;
    onRetry?: () => void;
    children?: ReactNode;
}

/**
 * A failure as the reader should see it: what happened, what it means, and the
 * one thing they can do next. The problem identifier is shown because it is what
 * the API reference indexes, which makes a report of a fault actionable.
 */
export function Failure({ problem, onRetry, children }: FailureProps) {
    return (
        <div className="state failure" role="alert">
            <WarningIcon size="1.75em" />
            <h3>{problem.title}</h3>
            <p>{problem.detail}</p>
            {children}
            <div className="row">
                {onRetry && (
                    <Button variant="secondary" onClick={onRetry}>
                        Try again
                    </Button>
                )}
                <code className="small muted">{problem.slug}</code>
            </div>
        </div>
    );
}
