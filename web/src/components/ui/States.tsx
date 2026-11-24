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

/**
 * The level the state's own heading takes. A state that is the whole screen
 * carries its `h1`, and one inside a card sits under the card's heading.
 * Skipping a level, or leaving a screen without an `h1`, is what a reader
 * navigating by heading notices first.
 */
type HeadingLevel = 1 | 2 | 3;

function StateHeading({ level, children }: { level: HeadingLevel; children: ReactNode }) {
    const Tag = `h${level}` as "h1" | "h2" | "h3";
    return <Tag>{children}</Tag>;
}

interface EmptyProps {
    title: string;
    level?: HeadingLevel;
    children?: ReactNode;
}

export function Empty({ title, level = 3, children }: EmptyProps) {
    return (
        <div className="state">
            <StateHeading level={level}>{title}</StateHeading>
            {children}
        </div>
    );
}

interface FailureProps {
    problem: ApiProblem;
    onRetry?: () => void;
    level?: HeadingLevel;
    children?: ReactNode;
}

/**
 * A failure as the reader should see it: what happened, what it means, and the
 * one thing they can do next. Exactly one action, since a refusal of what was
 * sent cannot be retried and a condition that may pass has nowhere else to go.
 * The problem identifier belongs in the response and the log, not on a screen.
 */
export function Failure({ problem, onRetry, level = 3, children }: FailureProps) {
    return (
        <div className="state failure" role="alert">
            <WarningIcon size="1.75em" />
            <StateHeading level={level}>{problem.title}</StateHeading>
            <p>{problem.detail}</p>
            <div className="row">
                {onRetry && (
                    <Button variant="secondary" onClick={onRetry}>
                        Try again
                    </Button>
                )}
                {children}
            </div>
        </div>
    );
}
