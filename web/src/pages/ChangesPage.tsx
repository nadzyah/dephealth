/**
 * What has changed since the previous assessment of the same manifest. Matched
 * on a fingerprint of the entry set, so the comparison works although the
 * manifest itself was never stored.
 */

import { Link, useParams } from "react-router-dom";

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { Badge } from "../components/ui/Badge";
import { Card } from "../components/ui/Card";
import { Failure, TableSkeleton } from "../components/ui/States";
import type { Change } from "../api/types";

import "./ChangesPage.css";

const delta = new Intl.NumberFormat("en", {
    maximumFractionDigits: 1,
    signDisplay: "always",
});

function tone(verdict: string) {
    if (verdict === "risk has risen") return "high" as const;
    if (verdict === "risk has fallen") return "low" as const;
    if (verdict === "new in the tree") return "accent" as const;
    return "neutral" as const;
}

function percent(value: number | null): string {
    return value === null ? "—" : `${(value * 100).toFixed(1)}%`;
}

function movement(change: Change): string {
    return change.change === null ? "—" : `${delta.format(change.change * 100)} points`;
}

export default function ChangesPage() {
    const { token = "" } = useParams();
    const changes = useAsync(() => api.changes(token), [token], token.length > 0);

    if (changes.status === "loading" || changes.status === "idle") {
        return (
            <Card title="Loading the comparison">
                <TableSkeleton label="Loading the comparison" rows={4} />
            </Card>
        );
    }

    if (changes.status === "failed" && changes.problem) {
        return (
            <Failure problem={changes.problem} onRetry={changes.reload}>
                <Link to={`/r/${token}`}>Back to the tree</Link>
            </Failure>
        );
    }

    const data = changes.data;
    if (!data) return null;

    return (
        <div className="stack">
            <section>
                <p className="small">
                    <Link to={`/r/${token}`}>The tree</Link> / changes
                </p>
                <h1>What changed</h1>
                <p className="muted">
                    This assessment of {data.assessed_on} against the one of{" "}
                    {data.previous_assessed_on}, for the same set of dependencies.
                </p>
            </section>

            <Card title={`${data.packages.length} packages compared`}>
                <ul className="changes">
                    {data.packages.map((change) => (
                        <li key={change.package_name}>
                            <span className="change-name">{change.package_name}</span>
                            <Badge tone={tone(change.verdict)}>{change.verdict}</Badge>
                            <span className="change-figures small muted numeric">
                                {percent(change.risk_then)} → {percent(change.risk_now)}
                                <span className="change-delta"> {movement(change)}</span>
                            </span>
                        </li>
                    ))}
                </ul>
            </Card>
        </div>
    );
}
