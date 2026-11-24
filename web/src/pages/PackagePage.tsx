/**
 * One entry of a report with the evidence behind its score: the observed
 * download series, the contributor activity, and the factors that moved it.
 *
 * The activity is here for a reason. A package that is finished rather than
 * abandoned scores as being at risk under the definition this uses, and the
 * only way a reader can tell the two apart is by seeing what the score was
 * computed from.
 */

import { Link, useParams } from "react-router-dom";

import { api } from "../api/client";
import { useAsync } from "../hooks/useAsync";
import { DownloadChart } from "../components/charts/DownloadChart";
import { FactorBars } from "../components/charts/FactorBars";
import { formatProbability } from "../lib/risk";
import { Badge, RiskBadge } from "../components/ui/Badge";
import { Card, Stat, StatRow } from "../components/ui/Card";
import { Failure, Skeleton } from "../components/ui/States";

const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });

export default function PackagePage() {
    const { token = "", name = "" } = useParams();
    const detail = useAsync(
        () => api.reportEntry(token, name),
        [token, name],
        token.length > 0 && name.length > 0,
    );

    if (detail.status === "loading" || detail.status === "idle") {
        return (
            <div className="stack">
                <Skeleton width="40%" height="2rem" />
                <Skeleton height="12rem" />
                <Skeleton height="8rem" />
            </div>
        );
    }

    if (detail.status === "failed" && detail.problem) {
        return (
            <Failure problem={detail.problem} onRetry={detail.reload}>
                <Link to={`/r/${token}`}>Back to the tree</Link>
            </Failure>
        );
    }

    const data = detail.data;
    if (!data) return null;

    const { entry, factors, downloads, live } = data;
    const activity = entry.activity;

    return (
        <div className="stack">
            <section>
                <p className="small">
                    <Link to={`/r/${token}`}>The tree</Link> / {entry.package_name}
                </p>
                <h1>
                    {entry.package_name} <span className="muted">{entry.package_version}</span>
                </h1>
                <div className="row">
                    <RiskBadge
                        probability={entry.risk?.probability ?? null}
                        horizonDays={entry.risk?.horizon_days}
                    />
                    <Badge tone="neutral">{entry.relation}</Badge>
                    {live?.repository_url && (
                        <a href={live.repository_url} className="small">
                            Repository
                        </a>
                    )}
                </div>
            </section>

            {entry.risk && (
                <Card title="The score">
                    <StatRow>
                        <Stat
                            label="Risk that maintenance ceases"
                            value={formatProbability(entry.risk.probability)}
                            hint={`within ${entry.risk.horizon_days} days`}
                        />
                        <Stat
                            label="Adoption forecast"
                            value={
                                entry.forecast?.point_downloads
                                    ? compact.format(entry.forecast.point_downloads)
                                    : "none"
                            }
                            hint={
                                entry.forecast?.insufficient_history
                                    ? "under twelve months of history"
                                    : `downloads at ${entry.forecast?.horizon_months} months`
                            }
                        />
                        {live?.is_abandoned !== null && live?.is_abandoned !== undefined && (
                            <Stat
                                label="Abandoned by the definition"
                                value={live.is_abandoned ? "yes" : "no"}
                                hint="see the method"
                            />
                        )}
                    </StatRow>
                </Card>
            )}

            <Card
                title="Downloads"
                action={<span className="muted small">as recorded by the registry</span>}
            >
                <DownloadChart
                    points={downloads}
                    label={`Daily downloads of ${entry.package_name}`}
                />
            </Card>

            <div className="grid two">
                <Card title="Contributor activity">
                    {activity ? (
                        <StatRow>
                            <Stat
                                label="Distinct contributors"
                                value={
                                    activity.contributor_count_withheld
                                        ? "withheld"
                                        : (activity.distinct_contributors ?? "unknown")
                                }
                                hint={
                                    activity.contributor_count_withheld
                                        ? "below the disclosure threshold"
                                        : "in the window"
                                }
                            />
                            <Stat
                                label="Days since the last event"
                                value={activity.days_since_last_event ?? "none observed"}
                            />
                        </StatRow>
                    ) : (
                        <p className="muted small">
                            No activity was stored for this entry, which is the case for one that
                            carries no score.
                        </p>
                    )}
                </Card>

                <Card title="What moved the score">
                    <FactorBars factors={factors} />
                </Card>
            </div>

            {entry.unresolved && (
                <Card title="Why this entry has no score">
                    <p>
                        <strong>{entry.unresolved.label}</strong>
                    </p>
                    <p className="muted">{entry.unresolved.remedy}</p>
                </Card>
            )}
        </div>
    );
}
