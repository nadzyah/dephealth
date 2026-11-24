/**
 * A stored report: the counts, the age of the data it rests on, the method
 * behind it, and the ranked tree.
 *
 * A withdrawn report and a link that never existed are shown differently,
 * because the API answers them differently and the distinction is the point of
 * keeping a withdrawal rather than deleting the row.
 */

import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { useAppStore } from "../store/useAppStore";
import { DataAgeBanner } from "../components/report/DataAgeBanner";
import { TreeTable } from "../components/report/TreeTable";
import { Button } from "../components/ui/Button";
import { Card, Stat, StatRow } from "../components/ui/Card";
import { Failure, TableSkeleton } from "../components/ui/States";
import { CheckIcon, CopyIcon } from "../components/ui/icons";

function CopyLink({ token }: { token: string }) {
    const [copied, setCopied] = useState(false);
    const notify = useAppStore((state) => state.notify);

    useEffect(() => {
        if (!copied) return;
        const timer = setTimeout(() => setCopied(false), 2000);
        return () => clearTimeout(timer);
    }, [copied]);

    async function copy() {
        const url = `${window.location.origin}${import.meta.env.BASE_URL}r/${token}`.replace(
            "//r/",
            "/r/",
        );

        try {
            await navigator.clipboard.writeText(url);
            setCopied(true);
        } catch {
            notify({
                kind: "info",
                title: "Could not reach the clipboard",
                detail: "Copy it from the address bar instead.",
            });
        }
    }

    return (
        <Button
            variant="secondary"
            size="small"
            onClick={() => void copy()}
            iconBefore={copied ? <CheckIcon size="1em" /> : <CopyIcon size="1em" />}
        >
            {copied ? "Copied" : "Copy link"}
        </Button>
    );
}

export default function ReportPage() {
    const { token = "" } = useParams();
    const report = useAsync(() => api.report(token), [token], token.length > 0);

    if (report.status === "loading" || report.status === "idle") {
        return (
            <Card title="Report">
                <TableSkeleton label="Loading the assessed tree" />
            </Card>
        );
    }

    if (report.status === "failed" && report.problem) {
        const retryable = report.problem.isRetryable;

        return (
            <Failure
                problem={report.problem}
                onRetry={retryable ? report.reload : undefined}
                level={1}
            >
                {!retryable && (
                    <Link to="/" className="button secondary touchable">
                        Go to home page
                    </Link>
                )}
            </Failure>
        );
    }

    const data = report.data;
    if (!data) return null;

    return (
        <div className="stack">
            <section>
                <h1>Assessment of {data.counts.entries} Dependencies</h1>
                <p className="muted">
                    Stored on {data.assessed_on}. The figures are the ones that stood when it was
                    generated, so filing this link keeps them.
                </p>
                <div className="row">
                    <CopyLink token={token} />
                    <Link to={`/r/${token}/changes`} className="button ghost touchable">
                        Compare with the previous assessment
                    </Link>
                </div>
            </section>

            <div className="grid two">
                <Card title="Counts">
                    <StatRow>
                        <Stat label="Entries" value={data.counts.entries} />
                        <Stat label="Scored" value={data.counts.resolved} />
                        <Stat
                            label="Unresolved"
                            value={data.counts.unresolved}
                            hint="each with a reason"
                        />
                    </StatRow>
                </Card>

                <DataAgeBanner
                    registry={data.data_as_of.registry}
                    events={data.data_as_of.events}
                />
            </div>

            <Card
                title="Dependency Tree"
                action={<span className="muted small">Ranked by risk. Scored entries first</span>}
            >
                <TreeTable entries={data.entries} token={token} />
            </Card>

            <Card title="Scoring Method">
                <StatRow>
                    <Stat
                        label="Abandonment window"
                        value={`${data.method.abandonment_window_days} days`}
                        hint="with no development event"
                    />
                    <Stat
                        label="Risk model"
                        value={data.method.risk_model.name}
                        hint={`version ${data.method.risk_model.version}`}
                    />
                    <Stat
                        label="Forecast model"
                        value={data.method.forecast_model.name}
                        hint={`version ${data.method.forecast_model.version}`}
                    />
                </StatRow>
                <p className="small muted" style={{ marginTop: "var(--space-4)" }}>
                    <Link to="/method">What these mean</Link>
                </p>
            </Card>
        </div>
    );
}
