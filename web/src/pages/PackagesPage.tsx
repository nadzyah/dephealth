/**
 * The packages the last ingestion run covered, searchable. This is the current
 * assessment rather than a stored report, so the figures here move when a run
 * finishes and the ones in a report do not.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { RiskBadge } from "../components/ui/Badge";
import { Card } from "../components/ui/Card";
import { Empty, Failure, TableSkeleton } from "../components/ui/States";
import { SearchField } from "../components/ui/SearchField";

import "./PackagesPage.css";

/** Waits for the typing to stop, so a search is one request rather than ten. */
function useDebounced<T>(value: T, delay = 300): T {
    const [settled, setSettled] = useState(value);

    useEffect(() => {
        const timer = setTimeout(() => setSettled(value), delay);
        return () => clearTimeout(timer);
    }, [value, delay]);

    return settled;
}

export default function PackagesPage() {
    const [query, setQuery] = useState("");
    const settled = useDebounced(query);
    const page = useAsync(() => api.packages(settled), [settled]);

    return (
        <div className="stack">
            <section>
                <h1>Packages</h1>
                <p>
                    The packages assessed by the most recent ingestion run, highest risk first.
                    These are current figures rather than the stored figures a report holds.
                </p>
            </section>

            <SearchField
                value={query}
                onChange={setQuery}
                label="Search packages by name"
                className="packages-search"
            />

            <Card title="Assessed Packages">
                {page.status === "loading" && <TableSkeleton label="Searching" rows={5} />}

                {page.status === "failed" && page.problem && (
                    <Failure problem={page.problem} onRetry={page.reload} />
                )}

                {page.status === "ready" && page.data && page.data.items.length === 0 && (
                    <Empty title="No Matches">
                        <p className="muted">No package in the snapshot has {query} in its name.</p>
                    </Empty>
                )}

                {page.status === "ready" && page.data && page.data.items.length > 0 && (
                    <ul className="packages">
                        {page.data.items.map((item) => (
                            <li key={item.package_name}>
                                <span className="package-id">
                                    <Link
                                        to={`/p/${encodeURIComponent(item.package_name)}`}
                                        className="package-name touchable"
                                    >
                                        {item.package_name}
                                    </Link>
                                    {item.latest_version && (
                                        <span className="package-version muted small">
                                            {item.latest_version}
                                        </span>
                                    )}
                                </span>
                                <RiskBadge probability={item.risk_probability} />
                                {!item.is_resolved && (
                                    <span className="muted small">
                                        not resolved to a repository
                                    </span>
                                )}
                            </li>
                        ))}
                    </ul>
                )}
            </Card>
        </div>
    );
}
